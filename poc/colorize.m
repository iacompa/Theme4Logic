// colorize.m — Theme4Logic runtime recoloring engine (PoC).
//
// Injected into Logic via DYLD_INSERT_LIBRARIES. Recolors WITHOUT touching Logic
// on disk (no re-sign, no "damaged"). Two color pipelines:
//
//   1. AppKit/asset-catalog colors  -> swizzle +[NSColor colorNamed:bundle:]
//      (and colorNamed:, colorWithCatalogName:colorName:). Themes arrange, track
//      headers, panels, ruler, inspector, etc. Keyed by theme.json "colors".
//
//   2. MIXER colors  -> swizzle the MACore central provider
//      -[MAAssetManager colorWithName:] / colorWithName:andVariant: (instance
//      methods). Themes channel strips, faders, ticks, knob frames, etc.
//      Keyed by theme.json "mixer". MACore loads late, so we defer the swizzle
//      via a dyld add-image callback.
//
// Theme: ~/Library/Application Support/Theme4Logic/theme.json
//   { "colors": { "ArrangeWorkspaceColor":"#15151f", ... },
//     "mixer":  { "ChannelstripBackground":"#20243a", "Fader":"#3c4880", ... } }
// Discovery logs: seen-live.txt (NSColor names), seen-mixer.txt (MACore names).

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <unistd.h>
#import <stdlib.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>

static void fc_diag(NSString *line);   // diagnostic logger, defined below
static BOOL fc_debugEnabled(void);
static void fc_loadAuto(NSDictionary *j);
static BOOL fc_autoAccentRGB(CGFloat r, CGFloat g, CGFloat b, CGFloat *or_, CGFloat *og, CGFloat *ob);
static BOOL fc_lightNeutralRGB(CGFloat r, CGFloat g, CGFloat b, CGFloat *or_, CGFloat *og, CGFloat *ob);
// The theme's own colors (text included) are never re-mapped by the CG grey/selection heuristics.
static BOOL fc_isThemedRGB(CGFloat r, CGFloat g, CGFloat b);
static NSDictionary<NSString*,NSColor*> *gTheme = nil;   // AppKit names
static NSDictionary<NSString*,NSColor*> *gMixer = nil;   // MACore names
static NSArray<NSColor*> *gRegionPalette = nil;           // Logic region swatches
static NSMutableSet<NSString*> *gSeen = nil, *gSeenMixer = nil;
static IMP gOrigCatalog=NULL, gOrigNamed=NULL, gOrigNamedBundle=NULL;
static IMP gOrigMAName=NULL, gOrigMANameVar=NULL;
static dispatch_once_t gMixerOnce;
static NSArray<NSString*> *gInstalledAppKitHooks = nil;
static NSArray<NSString*> *gRequiredAppKitHooks = nil;
static NSSet<NSString*> *gApprovedHookKeys = nil;
static BOOL gHooksAllowed = NO;
static NSString *gLogicBundleIdentifier = nil;
static NSString *gLogicVersion = nil;
static NSString *gLogicBuild = nil;
static NSString *gHookManifestPath = nil;
static NSString *gHookDisabledReason = nil;

static NSString *fc_dir(void) {
  NSString *d = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Theme4Logic"];
  [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
  return d;
}
// >0 while the engine itself builds a color, so the light-theme constructor hooks leave it alone.
static __thread int gFCInternal = 0;
static NSColor *fc_hexColor(NSString *hex) {
  if (![hex isKindOfClass:[NSString class]]) return nil;
  hex = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
  if (hex.length < 6) return nil;
  unsigned int r=0,g=0,b=0,a=255;
  sscanf([[hex substringToIndex:6] UTF8String], "%02x%02x%02x", &r,&g,&b);
  if (hex.length >= 8) sscanf([[hex substringWithRange:NSMakeRange(6,2)] UTF8String], "%02x", &a);
  gFCInternal++;
  NSColor *c = [NSColor colorWithSRGBRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a/255.0];
  gFCInternal--;
  return c;
}
static NSString *fc_envString(const char *name) {
  const char *value = getenv(name);
  return value ? [NSString stringWithUTF8String:value] : @"";
}
static BOOL fc_hooksAllowed(void) {
  return gHooksAllowed;
}
static NSString *fc_infoString(NSString *key, NSString *fallback) {
  NSString *v = [[NSBundle mainBundle] objectForInfoDictionaryKey:key];
  return [v isKindOfClass:[NSString class]] && v.length ? v : @"unknown";
}
static NSString *fc_hookKey(NSString *kind, NSString *className, NSString *selector) {
  return [NSString stringWithFormat:@"%@|%@|%@", kind ?: @"", className ?: @"", selector ?: @""];
}
static BOOL fc_hookAllowed(NSString *kind, NSString *className, NSString *selector) {
  if (!fc_hooksAllowed()) return NO;
  return [gApprovedHookKeys containsObject:fc_hookKey(kind, className, selector)];
}
static BOOL fc_loadHookManifest(void) {
  gLogicBundleIdentifier = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
  gLogicVersion = fc_infoString(@"CFBundleShortVersionString", @"unknown");
  gLogicBuild = fc_infoString(@"CFBundleVersion", @"unknown");
  if (![gLogicBundleIdentifier isEqualToString:@"com.apple.logic10"]) {
    gHookDisabledReason = [NSString stringWithFormat:@"Theme4Logic was injected into %@ instead of Logic Pro.", gLogicBundleIdentifier];
    return NO;
  }
  NSString *file = [NSString stringWithFormat:@"logic-%@-hooks.json", gLogicVersion];
  NSString *manifestDir = fc_envString("THEME4LOGIC_HOOK_MANIFEST_DIR");
  if (![manifestDir isKindOfClass:[NSString class]] || manifestDir.length == 0) {
    gHookDisabledReason = @"Hook manifest directory was not provided by the launcher.";
    return NO;
  }
  gHookManifestPath = [manifestDir stringByAppendingPathComponent:file];
  NSData *data = [NSData dataWithContentsOfFile:gHookManifestPath];
  if (!data) {
    gHookDisabledReason = [NSString stringWithFormat:@"Logic %@ is not in Theme4Logic's checked hook manifest list.", gLogicVersion];
    return NO;
  }
  NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![manifest isKindOfClass:[NSDictionary class]]) {
    gHookDisabledReason = [NSString stringWithFormat:@"Hook manifest for Logic %@ is invalid.", gLogicVersion];
    return NO;
  }
  NSNumber *schemaVersion = manifest[@"schemaVersion"];
  NSString *manifestVersion = manifest[@"logicVersion"];
  NSString *manifestBuild = manifest[@"logicBuild"];
  NSString *manifestBundle = manifest[@"logicBundleIdentifier"];
  NSNumber *allow = manifest[@"allowHooks"];
  NSArray *appKitHooks = manifest[@"appKitHooks"];
  NSArray *requiredAppKitHooks = manifest[@"requiredAppKitHooks"];
  NSArray *privateHooks = manifest[@"privateHooks"];
  if (![schemaVersion isKindOfClass:[NSNumber class]] || schemaVersion.integerValue != 2 || ![manifestBundle isKindOfClass:[NSString class]] || ![manifestVersion isKindOfClass:[NSString class]] || ![manifestBuild isKindOfClass:[NSString class]] || ![manifestBundle isEqualToString:gLogicBundleIdentifier] || ![manifestVersion isEqualToString:gLogicVersion] || ![manifestBuild isEqualToString:gLogicBuild] || ![allow isKindOfClass:[NSNumber class]] || !allow.boolValue || ![appKitHooks isKindOfClass:[NSArray class]] || appKitHooks.count == 0 || ![requiredAppKitHooks isKindOfClass:[NSArray class]] || requiredAppKitHooks.count == 0 || ![privateHooks isKindOfClass:[NSArray class]] || privateHooks.count == 0) {
    gHookDisabledReason = [NSString stringWithFormat:@"Hook manifest for Logic %@ did not approve runtime hooks.", gLogicVersion];
    return NO;
  }
  NSMutableSet *approved = [NSMutableSet set];
  NSMutableSet *approvedAppKit = [NSMutableSet set];
  for (NSString *selector in appKitHooks) {
    if (![selector isKindOfClass:[NSString class]] || selector.length == 0) {
      gHookDisabledReason = [NSString stringWithFormat:@"Hook manifest for Logic %@ contains invalid AppKit hook entries.", gLogicVersion];
      return NO;
    }
    [approvedAppKit addObject:selector];
    [approved addObject:fc_hookKey(@"class", @"NSColor", selector)];
  }
  if (approvedAppKit.count != appKitHooks.count) {
    gHookDisabledReason = [NSString stringWithFormat:@"Hook manifest for Logic %@ contains duplicate AppKit hook entries.", gLogicVersion];
    return NO;
  }
  NSMutableSet *requiredAppKitSet = [NSMutableSet set];
  for (NSString *selector in requiredAppKitHooks) {
    if (![selector isKindOfClass:[NSString class]] || ![approvedAppKit containsObject:selector]) {
      gHookDisabledReason = [NSString stringWithFormat:@"Hook manifest for Logic %@ requires an unapproved AppKit hook.", gLogicVersion];
      return NO;
    }
    [requiredAppKitSet addObject:selector];
  }
  if (requiredAppKitSet.count != requiredAppKitHooks.count) {
    gHookDisabledReason = [NSString stringWithFormat:@"Hook manifest for Logic %@ contains duplicate required AppKit hooks.", gLogicVersion];
    return NO;
  }
  NSUInteger validPrivateHooks = 0;
  NSMutableSet *approvedPrivate = [NSMutableSet set];
  NSSet *validKinds = [NSSet setWithObjects:@"class", @"instance", @"interpose", nil];
  for (NSDictionary *hook in privateHooks) {
    if (![hook isKindOfClass:[NSDictionary class]]) continue;
    NSString *kind = hook[@"kind"];
    NSString *className = hook[@"class"];
    NSString *selector = hook[@"selector"];
    if ([validKinds containsObject:kind] && [className isKindOfClass:[NSString class]] && className.length > 0 && [selector isKindOfClass:[NSString class]] && selector.length > 0) {
      NSString *key = fc_hookKey(kind, className, selector);
      if ([approvedPrivate containsObject:key]) {
        gHookDisabledReason = [NSString stringWithFormat:@"Hook manifest for Logic %@ contains duplicate private hook entries.", gLogicVersion];
        return NO;
      }
      [approvedPrivate addObject:key];
      [approved addObject:key];
      validPrivateHooks += 1;
    }
  }
  if (validPrivateHooks != privateHooks.count) {
    gHookDisabledReason = [NSString stringWithFormat:@"Hook manifest for Logic %@ contains invalid hook entries.", gLogicVersion];
    return NO;
  }
  gRequiredAppKitHooks = requiredAppKitHooks;
  gApprovedHookKeys = approved;
  gHooksAllowed = YES;
  return YES;
}
static NSDictionary *fc_parseColors(NSDictionary *src) {
  NSMutableDictionary *m = [NSMutableDictionary dictionary];
  if ([src isKindOfClass:[NSDictionary class]])
    for (NSString *k in src) { NSColor *c = fc_hexColor(src[k]); if (c) m[k]=c; }
  return m;
}
static void fc_loadTheme(void) {
  NSData *d = [NSData dataWithContentsOfFile:[fc_dir() stringByAppendingPathComponent:@"theme.json"]];
  NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
  if (![j isKindOfClass:[NSDictionary class]]) j = @{};
  gTheme = fc_parseColors(j[@"colors"] ?: j);
  gMixer = fc_parseColors(j[@"mixer"] ?: @{});
  NSMutableArray<NSColor*> *regions = [NSMutableArray array];
  id regionValues = j[@"region_palette"];
  if ([regionValues isKindOfClass:[NSArray class]]) {
    for (id value in (NSArray *)regionValues) {
      NSColor *color = fc_hexColor(value);
      if (color) [regions addObject:color];
    }
  }
  gRegionPalette = regions.count ? [regions copy] : @[];
  fc_loadAuto(j);
}

// log a requested name once, to the given file/set
static void fc_logSeen(NSMutableSet *set, NSString *file, NSString *name) {
  @synchronized (set) {
    if ([set containsObject:name]) return;
    [set addObject:name];
    NSString *p = [fc_dir() stringByAppendingPathComponent:file];
    FILE *f = fopen(p.fileSystemRepresentation, "a");
    if (f) { fprintf(f, "%s\n", name.UTF8String ?: "(nil)"); fclose(f); }
  }
}
// match a requested name against a theme dict: exact, strip "Colors/"|"Colors.", leaf
static NSColor *fc_match(NSDictionary *dict, NSString *name) {
  NSColor *c = dict[name];
  if (!c && [name hasPrefix:@"Colors/"]) c = dict[[name substringFromIndex:7]];
  if (!c && [name hasPrefix:@"Colors."]) c = dict[[name substringFromIndex:7]];
  if (!c) c = dict[[name lastPathComponent]];                 // ".../leaf"
  if (!c) c = dict[[[name componentsSeparatedByString:@"."] lastObject]]; // "a.b.leaf"
  return c;
}
// AppKit semantic names requested via colorNamed: (seen-live) with no catalog entry.
static NSColor *fc_semanticNamed(NSString *name) {
  if ([name isEqualToString:@"headerColor"])
    return gTheme[@"PanelHeaderColor"] ?: gTheme[@"MainWindowColor"];
  if ([name isEqualToString:@"gridColor"])
    return gTheme[@"gridColor"] ?: gTheme[@"EditorGridLinePrimary"] ?: gTheme[@"PianoRoll/BarGridLine"] ?: gTheme[@"DividerSecondaryColor"];
  if ([name isEqualToString:@"selectedInactiveColor"])
    return gTheme[@"SelectionColor"] ?: gTheme[@"TableviewSelectionPrimaryColor"];
  if ([name isEqualToString:@"unemphasizedSelectedTextBackgroundColor"])
    return gTheme[@"TableviewSelectionSecondaryColor"] ?: gTheme[@"SelectionColor"];
  if ([name isEqualToString:@"LibrarySeperatorColorTransparent"])
    return gTheme[@"LibrarySeperatorColorTransparent"] ?: gTheme[@"LibrarySeperatorColorSolid"];
  return nil;
}

// ---- AppKit pipeline ----
static NSColor *fc_lookup(NSString *name) {
  if (!name) return nil;
  @try {
    fc_logSeen(gSeen, @"seen-live.txt", name);
    NSColor *c = fc_match(gTheme, name);
    return c ?: fc_semanticNamed(name);
  }
  @catch (__unused NSException *e) { return nil; }
}
static id fc_colorWithCatalog(id s, SEL c, NSString *cat, NSString *n){ NSColor*x=fc_lookup(n); return x?x:((id(*)(id,SEL,NSString*,NSString*))gOrigCatalog)(s,c,cat,n); }
static id fc_colorNamed(id s, SEL c, NSString *n){ NSColor*x=fc_lookup(n); return x?x:((id(*)(id,SEL,NSString*))gOrigNamed)(s,c,n); }
static id fc_colorNamedBundle(id s, SEL c, NSString *n, id b){ NSColor*x=fc_lookup(n); return x?x:((id(*)(id,SEL,NSString*,id))gOrigNamedBundle)(s,c,n,b); }
// DIAGNOSTIC: dump Logic's list/browser table classes + their draw/fill/row selectors,
// so we can find the method drawing the gray empty alternating rows.
static void fc_dumpClasses(void){
  @try{
    unsigned int n=0; Class *all=objc_copyClassList(&n);
    NSMutableString *out=[NSMutableString string];
    for(unsigned int i=0;i<n;i++){
      const char *cn=class_getName(all[i]); if(!cn) continue;
      NSString *name=@(cn);
      if([name rangeOfString:@"Toolbar"].location==NSNotFound &&
         [name rangeOfString:@"ToolButton"].location==NSNotFound) continue;
      [out appendFormat:@"\n== %@ (super %s) ==\n", name, class_getName(class_getSuperclass(all[i]))];
      unsigned int m=0; Method *ms=class_copyMethodList(all[i],&m);
      for(unsigned int j=0;j<m;j++){ NSString *sel=NSStringFromSelector(method_getName(ms[j])); NSString*lo=sel.lowercaseString;
        if([lo containsString:@"draw"]||[lo containsString:@"color"]||[lo containsString:@"tint"]||[lo containsString:@"image"]||[lo containsString:@"template"]||[lo containsString:@"glyph"]||[lo containsString:@"content"]) [out appendFormat:@"  %@\n",sel]; }
      if(ms)free(ms);
    }
    if(all)free(all);
    [out writeToFile:[fc_dir() stringByAppendingPathComponent:@"toolbar-classes.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }@catch(__unused NSException*e){}
}
// DIAGNOSTIC: figure out how the event-list / file-browser gray alternating rows are drawn.
static void fc_tdiag(NSString *s){
  static dispatch_queue_t q; static dispatch_once_t o; dispatch_once(&o,^{ q=dispatch_queue_create("fc.tdiag",DISPATCH_QUEUE_SERIAL); });
  dispatch_async(q,^{ @try{
    NSString *p=[fc_dir() stringByAppendingPathComponent:@"table-diag.txt"];
    NSFileHandle *fh=[NSFileHandle fileHandleForWritingAtPath:p];
    if(!fh){ [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]; fh=[NSFileHandle fileHandleForWritingAtPath:p]; }
    [fh seekToEndOfFile]; [fh writeData:[[s stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile];
  }@catch(__unused NSException*e){} });
}
// Alternating list/table row colors → themed pair (fixes inconsistent "funky" striping
// in the Library, file browser, event lists).
static IMP gO_altColors=NULL, gO_altRows=NULL;
static id fc_altColors(id s,SEL c){ NSColor*a=gTheme[@"ListRowA"],*b=gTheme[@"ListRowB"]; return (a&&b)?@[a,b]:((id(*)(id,SEL))gO_altColors)(s,c); }
static id fc_altRows(id s,SEL c){ NSColor*a=gTheme[@"ListRowA"],*b=gTheme[@"ListRowB"]; return (a&&b)?@[a,b]:((id(*)(id,SEL))gO_altRows)(s,c); }
// Logic's MAKitTableView (base of EventListTableView, MALoopBrowserTableView, file browser)
// supplies its OWN gray alternating pair via this private instance method — bypassing the
// AppKit class API. Hooking it (and the NSTableView base) themes the empty/striped rows of
// every Logic list at once.
static IMP gO_maAltRows=NULL;
static id fc_maAltRows(id self,SEL c){ NSColor*a=gTheme[@"ListRowA"],*b=gTheme[@"ListRowB"]; return (a&&b)?@[a,b]:((id(*)(id,SEL))gO_maAltRows)(self,c); }
// Standard AppKit semantic background colors. Logic's Library + Loop browser are plain
// NSBrowser/NSMatrix/NSTableView controls (CLgLibraryBrowser, MABrowserMatrix,
// MALoopBrowserTableView) that fall through to these — our named-color hooks never see them,
// so the panels render with AppKit's default dark-gray. Remap to themed navy.
static IMP gO_ctlBg=NULL, gO_winBg=NULL, gO_pageBg=NULL, gO_ctlColor=NULL;
// controlColor = the standard control/button FACE color (gray). Gray push buttons (Get More Sounds,
// Revert/Delete/Save, dialog buttons) draw their bezel with this. Map → themed button fill.
static id fc_ctlColor(id s,SEL c){ NSColor*x=gTheme[@"ControlColor"]?:gTheme[@"ToolbarButtonFill"]; return x?:((id(*)(id,SEL))gO_ctlColor)(s,c); }
static id fc_ctlBg(id s,SEL c){ NSColor*x=gTheme[@"TableviewColor"]?:gTheme[@"PanelBackgroundColor"]; return x?:((id(*)(id,SEL))gO_ctlBg)(s,c); }
static id fc_winBg(id s,SEL c){ NSColor*x=gTheme[@"MainWindowColor"]?:gTheme[@"PanelBackgroundColor"]; return x?:((id(*)(id,SEL))gO_winBg)(s,c); }
static id fc_pageBg(id s,SEL c){ NSColor*x=gTheme[@"ArrangeWorkspaceColor"]?:gTheme[@"PanelBackgroundColor"]; return x?:((id(*)(id,SEL))gO_pageBg)(s,c); }
// systemGrayColor / textBackgroundColor / separatorColor are requested via colorNamed: and bypass
// the semantic class hooks — remap so neutral presets don't leak stock Logic grey/blue dividers.
static IMP gO_sysGray=NULL, gO_txtBg=NULL, gO_sep=NULL;
static id fc_sysGray(id s,SEL c){ NSColor*x=gTheme[@"ControlColor"]?:gTheme[@"ToolbarButtonFill"]; return x?:((id(*)(id,SEL))gO_sysGray)(s,c); }
static id fc_txtBg(id s,SEL c){ NSColor*x=gTheme[@"TableviewColor"]?:gTheme[@"PanelBackgroundColor"]; return x?:((id(*)(id,SEL))gO_txtBg)(s,c); }
static id fc_sep(id s,SEL c){ NSColor*x=gTheme[@"DividerPrimaryColor"]; return x?:((id(*)(id,SEL))gO_sep)(s,c); }

// Semantic TEXT colors → explicit per-hierarchy colors from the theme. Using
// primary text with alpha made secondary/tertiary labels land too close to a
// dark panel after compositing, especially in Studio One.
#define FCTXT(fn,gOrig,alpha) static IMP gOrig=NULL; \
  static id fn(id s,SEL c){ NSColor*t=gTheme[@"TextColor"]; return t?((alpha)>=1.0?t:[t colorWithAlphaComponent:(alpha)]):((id(*)(id,SEL))gOrig)(s,c); }
FCTXT(fc_t_label,  gO_t_label,  1.0)
FCTXT(fc_t_text,   gO_t_text,   1.0)
// Window title text: its own user-controllable key (falls back to TextColor).
static IMP gO_t_winfrm=NULL;
static id fc_t_winfrm(id s,SEL c){ NSColor*t=gTheme[@"ToolbarTextColor"]?:gTheme[@"TextColor"]; return t?:((id(*)(id,SEL))gO_t_winfrm)(s,c); }
FCTXT(fc_t_ctl,    gO_t_ctl,    1.0)
FCTXT(fc_t_hdr,    gO_t_hdr,    1.0)
FCTXT(fc_t_selctl, gO_t_selctl, 1.0)
FCTXT(fc_t_seltxt, gO_t_seltxt, 1.0)
FCTXT(fc_t_selmenu,gO_t_selmenu,1.0)
static IMP gO_t_sec=NULL, gO_t_ter=NULL, gO_t_quad=NULL, gO_t_dis=NULL, gO_t_ph=NULL;
static id fc_t_sec(id s,SEL c){ NSColor*t=gTheme[@"TextSecondaryColor"]?:gTheme[@"TextColor"]; return t?:((id(*)(id,SEL))gO_t_sec)(s,c); }
static id fc_t_ter(id s,SEL c){ NSColor*t=gTheme[@"TextTertiaryColor"]?:gTheme[@"TextSecondaryColor"]?:gTheme[@"TextColor"]; return t?:((id(*)(id,SEL))gO_t_ter)(s,c); }
static id fc_t_quad(id s,SEL c){ NSColor*t=gTheme[@"TextMutedColor"]?:gTheme[@"TextTertiaryColor"]?:gTheme[@"TextColor"]; return t?:((id(*)(id,SEL))gO_t_quad)(s,c); }
static id fc_t_dis(id s,SEL c){ NSColor*t=gTheme[@"TextMutedColor"]?:gTheme[@"TextTertiaryColor"]?:gTheme[@"TextColor"]; return t?:((id(*)(id,SEL))gO_t_dis)(s,c); }
static id fc_t_ph(id s,SEL c){ NSColor*t=gTheme[@"TextSecondaryColor"]?:gTheme[@"TextColor"]; return t?:((id(*)(id,SEL))gO_t_ph)(s,c); }
// Accent / selection / focus → theme accent (fixes "things stay blue" after a preset switch:
// these are the macOS system-blue the OS hands out for selected tabs/rows/checkboxes).
#define FCACC(fn,gOrig,key) static IMP gOrig=NULL; \
  static id fn(id s,SEL c){ NSColor*t=gTheme[key]; return t?:((id(*)(id,SEL))gOrig)(s,c); }
FCACC(fc_a_accent, gO_a_accent, @"AccentColor")
static IMP gO_a_focus=NULL;
static id fc_a_focus(id s,SEL c){ NSColor*t=gTheme[@"FocusRingColor"]?:gTheme[@"SelectionColor"]?:gTheme[@"AccentColor"]; return t?:((id(*)(id,SEL))gO_a_focus)(s,c); }
FCACC(fc_a_sysblue,gO_a_sysblue,@"AccentColor")
FCACC(fc_a_selbg,  gO_a_selbg,  @"SelectionColor")
FCACC(fc_a_selctl, gO_a_selctl, @"SelectionColor")
FCACC(fc_a_seltbg, gO_a_seltbg, @"SelectionColor")
// Private, appearance-aware accent accessor. +[NSColor controlAccentColor] (no-arg) delegates to
// this; appearance-aware controls (MAKitSegmentedControl's selected-segment fill, draw-time, no
// layer color) call it DIRECTLY, bypassing the no-arg swizzle. Mapping it = themed selected segments.
static IMP gO_a_accentApp=NULL;
static id fc_a_accentApp(id s, SEL c, id ap){ NSColor*t=gTheme[@"AccentColor"]; return t?:((id(*)(id,SEL,id))gO_a_accentApp)(s,c,ap); }

// ---- MIXER (MACore) pipeline ----
static NSColor *fc_lookupMixer(NSString *name) {
  if (![name isKindOfClass:[NSString class]]) return nil;
  @try { fc_logSeen(gSeenMixer, @"seen-mixer.txt", name); return fc_match(gMixer, name); }
  @catch (__unused NSException *e) { return nil; }
}
static id fc_maName(id s, SEL c, NSString *n){ NSColor*x=fc_lookupMixer(n); return x?x:((id(*)(id,SEL,id))gOrigMAName)(s,c,n); }
static id fc_maNameVar(id s, SEL c, NSString *n, id v){ NSColor*x=fc_lookupMixer(n); return x?x:((id(*)(id,SEL,id,id))gOrigMANameVar)(s,c,n,v); }

static IMP fc_swizzleClass(Class cls, SEL sel, IMP repl){ Method m=cls?class_getClassMethod(cls,sel):NULL; if(!m)return NULL; IMP o=method_getImplementation(m); method_setImplementation(m,repl); return o; }
static IMP fc_swizzleInst(Class cls, SEL sel, IMP repl){ Method m=cls?class_getInstanceMethod(cls,sel):NULL; if(!m)return NULL; IMP o=method_getImplementation(m); method_setImplementation(m,repl); return o; }
// Swizzle only on cls. If cls inherits the selector from its superclass (same IMP), add a
// shadowing method on cls instead of replacing the superclass IMP — otherwise every sibling
// slider cell (e.g. MAZoomSliderCell arrange-zoom) inherits the replacement too.
static IMP fc_swizzleInstSubclassOnly(Class cls, SEL sel, IMP repl){
  if(!cls) return NULL;
  Method m=class_getInstanceMethod(cls,sel); if(!m) return NULL;
  IMP orig=method_getImplementation(m);
  Class sup=class_getSuperclass(cls);
  if(sup){
    Method sm=class_getInstanceMethod(sup,sel);
    if(sm && method_getImplementation(sm)==orig){
      const char *types=method_getTypeEncoding(m);
      if(class_addMethod(cls,sel,repl,types)) return orig;
      return NULL;
    }
  }
  method_setImplementation(m,repl);
  return orig;
}

static void fc_writeMarker(NSString *appkit, NSString *mixer) {
  @try {
    NSDate *now = [NSDate date];
    if (appkit && ![appkit isEqualToString:@"installed"] && ![appkit isEqualToString:@"NONE"])
      gInstalledAppKitHooks = [appkit componentsSeparatedByString:@", "];
    NSArray *required = gRequiredAppKitHooks ?: @[];
    NSArray *installed = gInstalledAppKitHooks ?: @[];
    NSString *appkitStatus = installed.count ? [installed componentsJoinedByString:@", "] : (appkit ?: @"");
    NSString *s = [NSString stringWithFormat:@"colorize injected\npid: %d\nAppKit hooks: %@\nMixer hook (MAAssetManager): %@\ncolors: %lu  mixer: %lu\ntime: %@\n",
      getpid(), appkitStatus, mixer, (unsigned long)gTheme.count, (unsigned long)gMixer.count, now];
    [s writeToFile:[fc_dir() stringByAppendingPathComponent:@"colorize-active.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSSet *installedSet = [NSSet setWithArray:installed];
    BOOL ok = gTheme.count > 0;
    for (NSString *hook in required) {
      if (![installedSet containsObject:hook]) {
        ok = NO;
        break;
      }
    }
    NSDictionary *status = @{
      @"state": @"active",
      @"ok": @(ok),
      @"pid": @(getpid()),
      @"token": fc_envString("THEME4LOGIC_LAUNCH_TOKEN"),
      @"themeName": fc_envString("THEME4LOGIC_THEME_NAME"),
      @"logicBundleIdentifier": gLogicBundleIdentifier ?: @"unknown",
      @"logicVersion": gLogicVersion ?: @"unknown",
      @"logicBuild": gLogicBuild ?: @"unknown",
      @"hookManifest": gHookManifestPath ?: @"",
      @"hooksAllowed": @(gHooksAllowed),
      @"appkitHooks": appkitStatus ?: @"",
      @"installedAppKitHooks": installed,
      @"expectedAppKitHooks": required,
      @"mixerHook": mixer ?: @"",
      @"colors": @(gTheme.count),
      @"mixer": @(gMixer.count),
      @"time": @([now timeIntervalSince1970])
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[fc_dir() stringByAppendingPathComponent:@"colorize-status.json"] atomically:YES];
  } @catch (__unused NSException *e) {}
}
static void fc_writeDisabledMarker(void) {
  @try {
    NSDate *now = [NSDate date];
    NSString *reason = gHookDisabledReason ?: @"Runtime hooks are disabled for this Logic version.";
    NSString *s = [NSString stringWithFormat:@"colorize disabled\npid: %d\nLogic version: %@\nreason: %@\ntime: %@\n",
      getpid(), gLogicVersion ?: @"unknown", reason, now];
    [s writeToFile:[fc_dir() stringByAppendingPathComponent:@"colorize-active.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *status = @{
      @"state": @"disabled",
      @"ok": @NO,
      @"pid": @(getpid()),
      @"token": fc_envString("THEME4LOGIC_LAUNCH_TOKEN"),
      @"themeName": fc_envString("THEME4LOGIC_THEME_NAME"),
      @"logicBundleIdentifier": gLogicBundleIdentifier ?: @"unknown",
      @"logicVersion": gLogicVersion ?: @"unknown",
      @"logicBuild": gLogicBuild ?: @"unknown",
      @"hookManifest": gHookManifestPath ?: @"",
      @"hooksAllowed": @NO,
      @"disabledReason": reason,
      @"colors": @(gTheme.count),
      @"mixer": @(gMixer.count),
      @"time": @([now timeIntervalSince1970])
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[fc_dir() stringByAppendingPathComponent:@"colorize-status.json"] atomically:YES];
  } @catch (__unused NSException *e) {}
}

// Install the MACore mixer hook once MAAssetManager exists (MACore loads late).
static void fc_tryInstallMixer(void) {
  Class c = objc_getClass("MAAssetManager");
  if (!c) return;
  dispatch_once(&gMixerOnce, ^{
    if (fc_hookAllowed(@"instance", @"MAAssetManager", @"colorWithName:"))
      gOrigMAName = fc_swizzleInst(c, NSSelectorFromString(@"colorWithName:"), (IMP)fc_maName);
    if (fc_hookAllowed(@"instance", @"MAAssetManager", @"colorWithName:andVariant:"))
      gOrigMANameVar = fc_swizzleInst(c, NSSelectorFromString(@"colorWithName:andVariant:"), (IMP)fc_maNameVar);
    NSMutableArray *g=[NSMutableArray array];
    if(gOrigMAName)[g addObject:@"colorWithName:"]; if(gOrigMANameVar)[g addObject:@"colorWithName:andVariant:"];
    fc_writeMarker(@"installed", g.count?[g componentsJoinedByString:@", "]:@"FOUND-CLASS-NO-METHOD");
    os_log(OS_LOG_DEFAULT, "[Theme4Logic] mixer hook installed: %{public}@", [g componentsJoinedByString:@","]);
  });
}
// ---- Mixer NODE hooks: override the color getters the mixer node classes' own
// drawRect:inContext: reads (MAStripNode/MAFaderNode/MAKnobNode/...), then force a
// redraw to beat caching.
static dispatch_once_t gNodesOnce;
// Each hook = a static original-IMP + a 1-line getter returning our themed `key`
// (or falling through). Macro keeps ~16 hooks terse.
#define FCHOOK(fn, gOrig, key) \
  static IMP gOrig=NULL; \
  static id fn(id s,SEL c){NSColor*x=fc_lookupMixer(@key);return x?:((id(*)(id,SEL))gOrig)(s,c);}
FCHOOK(fc_stripBg,  gO_stripBg,  "ChannelstripBackground")
FCHOOK(fc_stripSel, gO_stripSel, "ChannelstripBackgroundSelected")
FCHOOK(fc_stripBd,  gO_stripBd,  "ChannelstripDivider")
FCHOOK(fc_knobTrk,  gO_knobTrk,  "Knob")
FCHOOK(fc_knobInd,  gO_knobInd,  "KnobIndicator")
FCHOOK(fc_scaleLbl, gO_scaleLbl, "ScaleLabel")
FCHOOK(fc_tickCol,  gO_tickCol,  "TickColor")
FCHOOK(fc_meterFill,gO_meterFill,"Meter")
FCHOOK(fc_meterBg,  gO_meterBg,  "MeterBg")
FCHOOK(fc_legendBg, gO_legendBg, "LegendBackground")
FCHOOK(fc_shapeFill,gO_shapeFill,"ButtonBackground")
FCHOOK(fc_shapeStrk,gO_shapeStrk,"ButtonOutline")
FCHOOK(fc_kitBg,    gO_kitBg,    "MixerArea")
FCHOOK(fc_tblBg,    gO_tblBg,    "MixerArea")
FCHOOK(fc_outBg,    gO_outBg,    "MixerArea")

// ---- Toolbar / button GLYPH recolor (the breakthrough): Logic's toolbar glyphs are NOT
// NSToolbar template images — they're MAKit scene-graph button nodes (MASymbolButtonNode /
// MAButtonNode) that cache a rendered glyph image the instant their foreground/tint color is
// set. So we hook the SETTER (not a getter): when Logic assigns a *grayish* glyph color, we
// substitute our ToolbarGlyphColor, so the cached render comes out themed. Strongly-colored
// glyphs (record red, status colors) pass through unchanged. This reaches the toolbar glyphs
// that no catalog color controls.
static NSColor* fc_glyphSub(id self, NSColor *incoming){
  (void)self;
  NSColor *t=gTheme[@"ToolbarGlyphColor"]; if(!t) return incoming;
  @try{
    if(incoming){
      NSColor *s=[incoming colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
      if(s){ CGFloat r=0,g=0,b=0,a=1; [s getRed:&r green:&g blue:&b alpha:&a];
        CGFloat mx=MAX(r,MAX(g,b)),mn=MIN(r,MIN(g,b));
        if((mx-mn) > 0.18) return incoming;   // saturated (red/blue status) → keep
      }
    }
  }@catch(__unused NSException*e){ return incoming; }
  return t;
}
#define FCSET(fn,gOrig) \
  static IMP gOrig=NULL; \
  static void fn(id s,SEL c,id col){ ((void(*)(id,SEL,id))gOrig)(s,c, fc_glyphSub(s,col)); }
FCSET(fc_symSetFg,   gO_symSetFg)
FCSET(fc_symSetTint, gO_symSetTint)
FCSET(fc_btnSetFg,   gO_btnSetFg)
FCSET(fc_btnSetTint, gO_btnSetTint)

// The toolbar glyph buttons don't set an explicit foreground color — they call -setSymbol:
// and render the SF-symbol in a default gray. So after the symbol is set (which builds the
// cached glyph image), we force our themed tint via the ORIGINAL color setters (bypassing our
// own swizzles to avoid re-entry). Together with the setter hook this recolors every toolbar glyph.
// GETTER override (the real fix): MAButtonNode reads -foregroundColor inside its
// drawImageInFrame:context: to tint the (template) glyph. The toolbar glyphs never SET a
// color — they inherit a default gray — so the setter rarely fires. Overriding the GETTER
// recolors at every draw and also catches buttons created before we installed.
static id fc_fgGet(id self, SEL _cmd, IMP orig){
  id v=((id(*)(id,SEL))orig)(self,_cmd);
  NSColor *t=gTheme[@"ToolbarGlyphColor"]; if(!t) return v;
  @try{
    if(v){ NSColor *s=[(NSColor*)v colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
      if(s){ CGFloat r=0,g=0,b=0,a=1;[s getRed:&r green:&g blue:&b alpha:&a];
        CGFloat mx=MAX(r,MAX(g,b)),mn=MIN(r,MIN(g,b));
        if((mx-mn)>0.18) return v;   // saturated (record red etc) → keep
      } }
  }@catch(__unused NSException*e){ return v; }
  return t;
}
static IMP gO_btnFgGet=NULL;
static id fc_btnFgGet(id self, SEL _cmd){ return fc_fgGet(self,_cmd,gO_btnFgGet); }
// MATextNode is the MAKit scene-graph TEXT renderer — it draws the secondary-toolbar tool LABELS
// ("Articulation", "Track Zoom", …) AND the global-tracks ruler chord names ("C", "Dm", …). Both
// read -foregroundColor and ship stock gray. Overriding the getter (grayish→themed, colored kept)
// recolors both surfaces at once. Hooking MATextNode's foreground getter does this.
static IMP gO_txtFgGet=NULL;
static id fc_txtFgGet(id self, SEL _cmd){ return fc_fgGet(self,_cmd,gO_txtFgGet); }
// MADisplayNode draws mixer slot labels ("Setting", "Stereo Out", …) — same grayish default
// as MATextNode; override the getter so labels use themed light text.
static IMP gO_dispFgGet=NULL;
static id fc_dispFgGet(id self, SEL _cmd){ return fc_fgGet(self,_cmd,gO_dispFgGet); }

// THE control-bar/toolbar glyph fix: these buttons are NSButtonCell subclasses (CLgTransportButtonCell,
// CLgViewButtonCell, MAKitButtonCell, …). The glyph is drawn by the cell's -drawImage:withFrame:inView:.
// We tint a copy of the (template) glyph image with our ToolbarGlyphColor and draw that — recoloring
// every control-bar / toolbar glyph in one base-class hook.
// Is an image monochrome (grayscale glyph) vs colored (red record dot, colored icon)? Sampled
// once per image and cached on the image via an associated object.
static BOOL fc_imgIsMono(NSImage *img){
  if(!img) return NO;
  static const void *MK=&MK;
  NSNumber *c=objc_getAssociatedObject(img,MK); if(c) return c.boolValue;
  BOOL mono=YES;
  @try{
    NSBitmapImageRep *bmp=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:18 pixelsHigh:18
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *gc=[NSGraphicsContext graphicsContextWithBitmapImageRep:bmp];
    [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:gc];
    [img drawInRect:NSMakeRect(0,0,18,18) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];
    int colored=0;
    for(int y=0;y<18&&mono;y++) for(int x=0;x<18;x++){
      NSColor *px=[[bmp colorAtX:x y:y] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]; if(!px) continue;
      CGFloat r=0,g=0,b=0,a=1;[px getRed:&r green:&g blue:&b alpha:&a]; if(a<0.30) continue;
      CGFloat mx=MAX(r,MAX(g,b)),mn=MIN(r,MIN(g,b));
      if(mx-mn>0.22){ if(++colored>=3){ mono=NO; break; } }
    }
  }@catch(__unused NSException*e){ mono=NO; }
  objc_setAssociatedObject(img,MK,@(mono),OBJC_ASSOCIATION_RETAIN);
  return mono;
}
static IMP gO_cellDrawImg=NULL;
// The Create New Track sheet ships with four stock-colored source icons. Those
// colors are semantic only in Logic's default appearance, not in a Theme4Logic
// preset. Limit this special treatment to that sheet so other Logic dialogs
// keep semantic colored artwork (warnings, plug-ins, and device controls).
static char kFCCreateTrackSheetKey;
static BOOL fc_viewTreeContainsText(NSView *view, NSString *needle, NSUInteger depth){
  @try{
    if(!view || depth>8) return NO;
    id title=[view respondsToSelector:@selector(title)]?[(id)view title]:nil;
    if([title isKindOfClass:[NSString class]] && [(NSString*)title rangeOfString:needle options:NSCaseInsensitiveSearch].location!=NSNotFound) return YES;
    id stringValue=[view respondsToSelector:@selector(stringValue)]?[(id)view stringValue]:nil;
    if([stringValue isKindOfClass:[NSString class]] && [(NSString*)stringValue rangeOfString:needle options:NSCaseInsensitiveSearch].location!=NSNotFound) return YES;
    for(NSView *subview in view.subviews) if(fc_viewTreeContainsText(subview, needle, depth+1)) return YES;
  }@catch(__unused NSException*e){}
  return NO;
}
static BOOL fc_isCreateNewTrackSheetView(id view){
  @try{
    if(![view isKindOfClass:[NSView class]]) return NO;
    NSWindow *w=[(NSView*)view window];
    if(!w || !w.sheetParent) return NO;
    if(objc_getAssociatedObject(w,&kFCCreateTrackSheetKey)) return YES;
    BOOL matches=[w.title rangeOfString:@"Create New Track" options:NSCaseInsensitiveSearch].location!=NSNotFound;
    if(!matches) matches=fc_viewTreeContainsText(w.contentView, @"Create New Track", 0);
    if(matches) objc_setAssociatedObject(w,&kFCCreateTrackSheetKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return matches;
  }@catch(__unused NSException*e){ return NO; }
}
// Debug-only sheet discovery. This deliberately observes the concrete view tree instead of
// adding speculative private hooks: a captured class/image signature is required before a new
// Logic 12.3 hook can be manifest-approved.
static char kFCSheetDiagKey;
static void fc_sheetDiagWrite(NSString *contents){
  if(!fc_debugEnabled() || !contents) return;
  static dispatch_queue_t q; static dispatch_once_t once;
  dispatch_once(&once, ^{ q=dispatch_queue_create("fc.sheetdiag", DISPATCH_QUEUE_SERIAL); });
  dispatch_async(q, ^{ @try{
    [contents writeToFile:[fc_dir() stringByAppendingPathComponent:@"sheet-hierarchy.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }@catch(__unused NSException*e){} });
}
static NSString* fc_sheetViewText(id view){
  @try{
    id title=[view respondsToSelector:@selector(title)]?[(id)view title]:nil;
    if([title isKindOfClass:[NSString class]] && [title length]) return title;
    id value=[view respondsToSelector:@selector(stringValue)]?[(id)view stringValue]:nil;
    if([value isKindOfClass:[NSString class]] && [value length]) return value;
  }@catch(__unused NSException*e){}
  return @"";
}
static void fc_dumpSheetView(NSView *view, NSUInteger depth, NSUInteger *count, NSMutableString *out){
  @try{
    if(!view || !out || !count || *count>=320 || depth>9) return;
    *count += 1;
    NSString *pad=[@"" stringByPaddingToLength:depth*2 withString:@" " startingAtIndex:0];
    id cell=[view respondsToSelector:@selector(cell)]?[(id)view cell]:nil;
    id image=[view respondsToSelector:@selector(image)]?[(id)view image]:nil;
    NSString *imageName=[image respondsToSelector:@selector(name)]?[(id)image name]:@"";
    id textColor=[view respondsToSelector:@selector(textColor)]?[(id)view textColor]:nil;
    CGColorRef layerColor=view.layer.backgroundColor;
    [out appendFormat:@"%@%@ frame={{%.0f,%.0f},{%.0f,%.0f}} cell=%@ text='%@' textColor=%@ image=%@ imageName='%@' layer=%p\n",
      pad, NSStringFromClass(view.class), view.frame.origin.x, view.frame.origin.y,
      view.frame.size.width, view.frame.size.height, cell?NSStringFromClass([cell class]):@"-",
      fc_sheetViewText(view), textColor?:@"-", image?NSStringFromClass([image class]):@"-",
      imageName?:@"", layerColor];
    for(NSView *subview in view.subviews) fc_dumpSheetView(subview, depth+1, count, out);
  }@catch(__unused NSException*e){}
}
static void fc_captureSheetHierarchy(NSWindow *window){
  @try{
    if(!fc_debugEnabled() || !window || !window.sheetParent || objc_getAssociatedObject(window,&kFCSheetDiagKey)) return;
    if(!fc_isCreateNewTrackSheetView(window.contentView)) return;
    objc_setAssociatedObject(window,&kFCSheetDiagKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableString *out=[NSMutableString stringWithFormat:@"Theme4Logic sheet discovery\nwindow=%@ title='%@' parent=%@\n",
      NSStringFromClass(window.class), window.title?:@"", NSStringFromClass(window.sheetParent.class)];
    NSUInteger count=0;
    fc_dumpSheetView(window.contentView, 0, &count, out);
    fc_sheetDiagWrite(out);
  }@catch(__unused NSException*e){}
}
static NSColor* fc_sheetIconTint(id cell){
  NSColor *accent=gTheme[@"AccentColor"]?:gTheme[@"ToolbarGlyphColor"];
  @try{
    if([cell respondsToSelector:@selector(state)] && [(NSCell*)cell state]==NSControlStateValueOn)
      return gTheme[@"TextColor"]?:accent;
  }@catch(__unused NSException*e){}
  return accent;
}
static void fc_cellDrawImg(id self, SEL _cmd, id image, NSRect frame, id view){
  @try{
    NSColor *t=gTheme[@"ToolbarGlyphColor"];
    if(t && [image isKindOfClass:[NSImage class]]){
      NSImage *src=(NSImage*)image; NSSize sz=src.size;
      BOOL tmpl=NO; @try{ tmpl=src.isTemplate; }@catch(__unused NSException*e){}
      BOOL sheetIcon=fc_isCreateNewTrackSheetView(view) && sz.width>=12 && sz.height>=12 && sz.width<=128 && sz.height<=128;
      if(sheetIcon){
        // Do not use the normal glyph cache: the same source image may also be
        // drawn outside a sheet with ToolbarGlyphColor instead of AccentColor.
        NSColor *sheetTint=fc_sheetIconTint(self);
        if(sheetTint){
          NSImage *tinted=[[NSImage alloc] initWithSize:sz];
          [tinted lockFocus];
          [src drawInRect:NSMakeRect(0,0,sz.width,sz.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
          [sheetTint set];
          NSRectFillUsingOperation(NSMakeRect(0,0,sz.width,sz.height), NSCompositingOperationSourceAtop);
          [tinted unlockFocus];
          [tinted setTemplate:NO];
          ((void(*)(id,SEL,id,NSRect,id))gO_cellDrawImg)(self,_cmd,tinted,frame,view);
          return;
        }
      }
      if(sz.width>=1 && sz.height>=1 && (tmpl || fc_imgIsMono(src))){
        static const void *TK=&TK;
        NSImage *tinted=objc_getAssociatedObject(src,TK);
        if(!tinted){
          tinted=[[NSImage alloc] initWithSize:sz];
          [tinted lockFocus];
          [src drawInRect:NSMakeRect(0,0,sz.width,sz.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
          [t set];
          NSRectFillUsingOperation(NSMakeRect(0,0,sz.width,sz.height), NSCompositingOperationSourceAtop);
          [tinted unlockFocus];
          [tinted setTemplate:NO];
          objc_setAssociatedObject(src,TK,tinted,OBJC_ASSOCIATION_RETAIN);
        }
        ((void(*)(id,SEL,id,NSRect,id))gO_cellDrawImg)(self,_cmd,tinted,frame,view);
        return;
      }
    }
  }@catch(__unused NSException*e){}
  ((void(*)(id,SEL,id,NSRect,id))gO_cellDrawImg)(self,_cmd,image,frame,view);
}

// THE button-CONTAINER fix the user asked for: the gray rounded button backgrounds (loop-browser
// Instrument/Genre/Scale/Signature, dialog buttons, etc.) are drawn by the cell's -drawBezelWithFrame:
// inView:. For BORDERED cells we replace that gray bezel with a themed fill (+ optional border) so
// the whole control goes with the theme. Borderless toolbar glyph buttons (isBordered==NO) pass
// through untouched so they stay transparent on the toolbar.
static IMP gO_cellBezel=NULL;
static void fc_cellBezel(id self, SEL _cmd, NSRect frame, id view){
  @try{
    NSColor *fill=gTheme[@"ToolbarButtonFill"];
    BOOL bordered=YES; @try{ bordered=[(NSButtonCell*)self isBordered]; }@catch(__unused NSException*e){}
    if(fill && bordered && frame.size.width>=8 && frame.size.height>=8 && frame.size.height<=40){
      CGFloat rad=MIN(6.0, frame.size.height*0.28);
      NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame,0.5,0.5) xRadius:rad yRadius:rad];
      NSColor *f=[fill colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]; if(f){ [f set]; [p fill]; }
      NSColor *bd=gTheme[@"ToolbarButtonBorder"]; if(bd){ NSColor*s=[bd colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]; if(s){[s set];[p setLineWidth:1.0];[p stroke];} }
      return;
    }
  }@catch(__unused NSException*e){}
  ((void(*)(id,SEL,NSRect,id))gO_cellBezel)(self,_cmd,frame,view);
}

// Loop-browser & MA popup/segmented button CONTAINERS: these custom cells draw their own gray
// background (bypassing NSButtonCell), via the method names we dumped. Replace/overlay with the
// themed button fill, and theme their title + menu-arrow colors.
static NSColor* fc_btnFillColor(void){ NSColor*f=gTheme[@"ToolbarButtonFill"]; return f?[f colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]:nil; }
static void fc_fillRoundRect(NSRect frame){
  NSColor *f=fc_btnFillColor(); if(!f) return;
  CGFloat rad=MIN(6.0, frame.size.height*0.28);
  [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame,0.5,0.5) xRadius:rad yRadius:rad] setClip];
  NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame,0.5,0.5) xRadius:rad yRadius:rad];
  [f set]; [p fill];
}
static IMP gO_ppBg=NULL;          // MAPopUpButtonCell drawBorderAndBackgroundWithFrame:inView: (replace)
static void fc_ppBg(id self,SEL _cmd,NSRect frame,id view){
  @try{ if(fc_btnFillColor()){ [NSGraphicsContext saveGraphicsState]; fc_fillRoundRect(frame); [NSGraphicsContext restoreGraphicsState]; return; } }@catch(__unused NSException*e){}
  ((void(*)(id,SEL,NSRect,id))gO_ppBg)(self,_cmd,frame,view);
}
static IMP gO_segLbl=NULL;        // MALoopBrowserSegmentedTextLabelCell drawWithFrame:inView: (pre-fill, then text)
static void fc_segLbl(id self,SEL _cmd,NSRect frame,id view){
  @try{ [NSGraphicsContext saveGraphicsState]; fc_fillRoundRect(frame); [NSGraphicsContext restoreGraphicsState]; }@catch(__unused NSException*e){}
  ((void(*)(id,SEL,NSRect,id))gO_segLbl)(self,_cmd,frame,view);
}
static IMP gO_ppTitle=NULL;       // popup/button title color → themed light text
static id fc_ppTitle(id self,SEL _cmd){ NSColor*t=gTheme[@"TextColor"]; return t?:((id(*)(id,SEL))gO_ppTitle)(self,_cmd); }
static IMP gO_btnTitle=NULL;
static id fc_btnTitle(id self,SEL _cmd){ NSColor*t=gTheme[@"TextColor"]; return t?:((id(*)(id,SEL))gO_btnTitle)(self,_cmd); }
static IMP gO_ppArrow=NULL;       // popup menu-arrow chevron → themed glyph color
static id fc_ppArrow(id self,SEL _cmd){ NSColor*t=gTheme[@"ToolbarGlyphColor"]; return t?:((id(*)(id,SEL))gO_ppArrow)(self,_cmd); }

// Button TITLE text (the secondary-toolbar tool LABELS under each icon are NSButtonCell titles on
// MAActionBarButton; also general button labels). Recolor the attributed title's foreground to the
// themed glyph color (grayish-preserve keeps colored titles). Catches every NSButtonCell subclass.
static int gTitleDiag=0;
static IMP gO_cellDrawTitle=NULL;
static NSRect fc_cellDrawTitle(id self, SEL _cmd, id title, NSRect frame, id view){
  id useTitle=title;
  @try{
    NSColor *t=gTheme[@"ToolbarGlyphColor"];
    if(gTitleDiag<40 && [title isKindOfClass:[NSAttributedString class]]){ gTitleDiag++; fc_diag([NSString stringWithFormat:@"TITLE %@ '%@'",NSStringFromClass([self class]),[[(NSAttributedString*)title string] substringToIndex:MIN((NSUInteger)14,[(NSAttributedString*)title length])]]); }
    if(t && [title isKindOfClass:[NSAttributedString class]] && [(NSAttributedString*)title length]>0){
      NSAttributedString *as=(NSAttributedString*)title;
      NSColor *cur=[as attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
      BOOL retint=YES;
      if(cur){ NSColor*s=[cur colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        if(s){ CGFloat rr=0,gg=0,bb=0,aa=1;[s getRed:&rr green:&gg blue:&bb alpha:&aa];
          CGFloat mx=MAX(rr,MAX(gg,bb)),mn=MIN(rr,MIN(gg,bb)); if(mx-mn>0.18) retint=NO; } }
      if(retint){ NSMutableAttributedString *m=[as mutableCopy]; [m addAttribute:NSForegroundColorAttributeName value:t range:NSMakeRange(0,m.length)]; useTitle=m; }
    }
  }@catch(__unused NSException*e){ useTitle=title; }
  return ((NSRect(*)(id,SEL,id,NSRect,id))gO_cellDrawTitle)(self,_cmd,useTitle,frame,view);
}

// The secondary-toolbar tool LABELS are drawn directly inside -[MAActionBarButton drawRect:]
// (the class has only initWithFrame:/setActionButtonAppearance/drawRect:) via NSString text-draw,
// NOT a cell title. So: set a flag for the duration of that drawRect:, and recolor any string
// drawn while the flag is up. Scoped this way it touches only action-bar captions.
static int gInActionBar=0;
static int gAttrRecolor=0;
static int gAbDiag=0;
static int gAbStructDone=0;
static IMP gO_abDrawRect=NULL;
static void fc_abDrawRect(id self, SEL _cmd, NSRect r){
  gInActionBar++;
  if(!gAbStructDone){ gAbStructDone=1; @try{
    NSView *v=(NSView*)self;
    id title=[v respondsToSelector:@selector(title)]?[(id)v title]:@"-";
    id atitle=[v respondsToSelector:@selector(attributedTitle)]?[(id)v attributedTitle]:nil;
    NSMutableString *chain=[NSMutableString string]; NSView *p=v.superview; int dd=0;
    while(p && dd<6){ [chain appendFormat:@" < %@",NSStringFromClass([p class])]; p=p.superview; dd++; }
    fc_diag([NSString stringWithFormat:@"ABSELF %@ title='%@' atitle=%@ subs=%lu chain:%@", NSStringFromClass([v class]), title, atitle?@"YES":@"no", (unsigned long)v.subviews.count, chain]);
    for(NSView*sv in v.subviews){ id s=[sv respondsToSelector:@selector(stringValue)]?[(id)sv stringValue]:@"-"; fc_diag([NSString stringWithFormat:@"ABSUB %@ str='%@'",NSStringFromClass([sv class]),s]); }
    for(CALayer*ly in v.layer.sublayers){ NSString*x=@""; if([ly isKindOfClass:objc_getClass("CATextLayer")]){ id s=[(id)ly string]; x=[NSString stringWithFormat:@" CATEXT='%@'",s]; } fc_diag([NSString stringWithFormat:@"ABLAYER %@%@",NSStringFromClass([ly class]),x]); }
  }@catch(__unused NSException*e){} }
  @try{ ((void(*)(id,SEL,NSRect))gO_abDrawRect)(self,_cmd,r); }@catch(__unused NSException*e){}
  if(gInActionBar>0) gInActionBar--;
}
// The action-bar CONTAINER (CLgActionBarSegmentedControl / CLgActionBarView) draws the captions,
// not the button. Set the flag for the duration of the container's drawRect: too.
static IMP gO_segDR=NULL;
static void fc_segDR(id self,SEL _cmd,NSRect r){ gInActionBar++; if(gAbDiag<60){gAbDiag++;fc_diag(@"SEGDRAW");} @try{((void(*)(id,SEL,NSRect))gO_segDR)(self,_cmd,r);}@catch(__unused NSException*e){} if(gInActionBar>0)gInActionBar--; }
static IMP gO_abvDR=NULL;
static void fc_abvDR(id self,SEL _cmd,NSRect r){ gInActionBar++; @try{((void(*)(id,SEL,NSRect))gO_abvDR)(self,_cmd,r);}@catch(__unused NSException*e){} if(gInActionBar>0)gInActionBar--; }
static NSDictionary* fc_retintAttrs(NSDictionary *attrs){
  NSColor *t=gTheme[@"ToolbarGlyphColor"]; if(!t) return attrs;
  NSMutableDictionary *m=attrs?[attrs mutableCopy]:[NSMutableDictionary dictionary];
  m[NSForegroundColorAttributeName]=t; return m;
}
// NSAttributedString draw (the action-bar caption is most likely this). When inside an action-bar
// drawRect:, draw a recolored copy. gAttrRecolor guards the re-entrant copy-draw.
static id fc_asRetint(id as){
  NSColor *t=gTheme[@"ToolbarGlyphColor"]; if(!t||![as isKindOfClass:[NSAttributedString class]]||[(NSAttributedString*)as length]==0) return as;
  NSMutableAttributedString *m=[as mutableCopy]; [m addAttribute:NSForegroundColorAttributeName value:t range:NSMakeRange(0,m.length)]; return m;
}
static IMP gO_asRect=NULL;
static void fc_asRect(id self, SEL _cmd, NSRect r){
  if(gInActionBar>0 && !gAttrRecolor){ @try{ gAttrRecolor++; ((void(*)(id,SEL,NSRect))gO_asRect)(fc_asRetint(self),_cmd,r); gAttrRecolor--; return; }@catch(__unused NSException*e){ gAttrRecolor=0; } }
  ((void(*)(id,SEL,NSRect))gO_asRect)(self,_cmd,r);
}
static IMP gO_asPt=NULL;
static void fc_asPt(id self, SEL _cmd, NSPoint p){
  if(gInActionBar>0 && !gAttrRecolor){ @try{ gAttrRecolor++; ((void(*)(id,SEL,NSPoint))gO_asPt)(fc_asRetint(self),_cmd,p); gAttrRecolor--; return; }@catch(__unused NSException*e){ gAttrRecolor=0; } }
  ((void(*)(id,SEL,NSPoint))gO_asPt)(self,_cmd,p);
}
static IMP gO_asRectOpt=NULL;
static void fc_asRectOpt(id self, SEL _cmd, NSRect r, NSUInteger opts, id ctx){
  if(gInActionBar>0 && !gAttrRecolor){ @try{ gAttrRecolor++; ((void(*)(id,SEL,NSRect,NSUInteger,id))gO_asRectOpt)(fc_asRetint(self),_cmd,r,opts,ctx); gAttrRecolor--; return; }@catch(__unused NSException*e){ gAttrRecolor=0; } }
  ((void(*)(id,SEL,NSRect,NSUInteger,id))gO_asRectOpt)(self,_cmd,r,opts,ctx);
}

// Loop-browser volume slider hooks — must NOT affect MAZoomSliderCell (arrange zoom sliders).
static BOOL fc_isLoopBrowserVolumeSlider(id self){
  return [NSStringFromClass([self class]) isEqualToString:@"MALoopBrowserVolumeSliderCell"];
}
// Loop-browser volume slider track only — hook the specific cell class, not NSSliderCell globally.
static IMP gO_sliderBar=NULL;
static void fc_sliderBar(id self, SEL _cmd, NSRect rect, BOOL flipped){
  if(!fc_isLoopBrowserVolumeSlider(self)){
    if(gO_sliderBar) ((void(*)(id,SEL,NSRect,BOOL))gO_sliderBar)(self,_cmd,rect,flipped);
    return;
  }
  @try{
    NSColor *t=gTheme[@"ToolbarButtonFill"];
    if(t){ NSColor*s=[t colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
      if(s){ CGFloat rad=MIN(3.0,rect.size.height*0.45); [s set]; [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:rad yRadius:rad] fill]; return; } }
  }@catch(__unused NSException*e){}
  if(gO_sliderBar) ((void(*)(id,SEL,NSRect,BOOL))gO_sliderBar)(self,_cmd,rect,flipped);
}
// Loop-browser volume slider is a custom MALoopBrowserVolumeSliderCell that draws its whole face via
// drawWithFrame:inView: (neither drawBarInside: nor drawKnob: fire). Replace with a themed track +
// AccentColor knob positioned at the cell's current value.
// IMPORTANT: only run on MALoopBrowserVolumeSliderCell — never on MAZoomSliderCell (arrange zoom).
static IMP gO_volSlider=NULL;
static void fc_volSlider(id self, SEL _cmd, NSRect frame, id view){
  if(!fc_isLoopBrowserVolumeSlider(self)){
    if(gO_volSlider) ((void(*)(id,SEL,NSRect,id))gO_volSlider)(self,_cmd,frame,view);
    return;
  }
  @try{
    NSColor *track=[gTheme[@"ToolbarButtonFill"] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    NSColor *knob=[gTheme[@"AccentColor"] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if(track && knob){
      double v=0,mn=0,mx=1;
      @try{ v=[(NSSliderCell*)self doubleValue]; mn=[(NSSliderCell*)self minValue]; mx=[(NSSliderCell*)self maxValue]; }@catch(__unused NSException*e){}
      double frac=(mx>mn)?(v-mn)/(mx-mn):0.5; if(frac<0)frac=0; if(frac>1)frac=1;
      CGFloat dim=MIN(frame.size.width, frame.size.height);
      CGFloat kr=MIN(dim*0.35, 8.0); if(kr<3) kr=3;
      CGFloat cy=frame.origin.y+frame.size.height*0.5;
      NSRect trk=NSMakeRect(frame.origin.x+kr, cy-1.5, frame.size.width-2*kr, 3.0);
      [track set]; [[NSBezierPath bezierPathWithRoundedRect:trk xRadius:1.5 yRadius:1.5] fill];
      CGFloat kx=frame.origin.x+kr + frac*(frame.size.width-2*kr) - kr;
      [knob set]; [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(NSMakeRect(kx,cy-kr,2*kr,2*kr),1,1)] fill];
      return;
    }
  }@catch(__unused NSException*e){}
  if(gO_volSlider) ((void(*)(id,SEL,NSRect,id))gO_volSlider)(self,_cmd,frame,view);
}

// NOTE: CoreUI CUIDraw was investigated for the gray push buttons / blue toggles and ruled out —
// runtime logging showed only image/OverlayScrollBar/WindowFrame widgets go through CUIDraw in
// Logic; its buttons and segmented controls are custom-drawn (MAKit/CLg), never CoreUI. So there
// is no CUIDraw hook here and CoreUI is no longer linked.

static IMP gO_symSetSymbol=NULL;
static void fc_symSetSymbol(id self, SEL _cmd, id symbol){
  ((void(*)(id,SEL,id))gO_symSetSymbol)(self,_cmd,symbol);
  @try{
    NSColor *t=gTheme[@"ToolbarGlyphColor"]; if(!t) return;
    if(gO_symSetTint) ((void(*)(id,SEL,id))gO_symSetTint)(self,NSSelectorFromString(@"setContentTintColor:"),t);
    if(gO_symSetFg)   ((void(*)(id,SEL,id))gO_symSetFg)(self,NSSelectorFromString(@"setForegroundColor:"),t);
  }@catch(__unused NSException*e){}
}

// Layer-backed fills (e.g. the empty mixer background) bypass NSColor AND drawRect.
// Intercept -[CALayer setBackgroundColor:]: when a layer is set to Logic's default
// mixer-gray (~#575757), substitute our themed MixerArea color.
static const CGFloat kSystemBlueR=0.0f, kSystemBlueG=0.478f, kSystemBlueB=1.0f, kSystemBlueTol=0.085f;
static inline BOOL fc_isSystemBlue(CGFloat r, CGFloat g, CGFloat b){
  return (r<=kSystemBlueR+kSystemBlueTol && g>=kSystemBlueG-kSystemBlueTol && g<=kSystemBlueG+kSystemBlueTol && b>=kSystemBlueB-kSystemBlueTol);
}
static IMP gO_layerBg=NULL;
static void fc_layerBg(id self, SEL _cmd, CGColorRef color){
  CGColorRef use=color;
  @try{
    if(color){
      size_t n=CGColorGetNumberOfComponents(color); const CGFloat*c=CGColorGetComponents(color);
      CGFloat r=0,g=0,b=0,a=1; if(n>=4){r=c[0];g=c[1];b=c[2];a=c[3];} else if(n==2){r=g=b=c[0];a=c[1];}
      if(a>0.85 && fabs(r-g)<0.06 && fabs(g-b)<0.06 && r>0.17 && r<0.47){   // opaque gray (rows, empty areas)
        NSColor *t=fc_lookupMixer(@"MixerArea");
        if(t){ NSColor*s=[t colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]; if(s) use=s.CGColor; }
      } else if(n>=4 && a>0.4 && b>0.45 && (b-r)>0.12 && (b-g)>0.08){   // accent/selection BLUE layer
        NSColor *t=fc_isSystemBlue(r,g,b)?gTheme[@"AccentColor"]:(gTheme[@"TabBackgroundSelectedColor"]?:gTheme[@"SelectionColor"]);
        if(t){ NSColor*s=[t colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]; if(s) use=s.CGColor; }
      }
    }
  }@catch(__unused NSException*e){ use=color; }
  ((void(*)(id,SEL,CGColorRef))gO_layerBg)(self,_cmd,use);
}

// Table ROW backgrounds (event list, etc.): the alternate rows are set as a gray
// on the row view itself. Remap that gray to our color — scoped to table rows.
static IMP gO_rowBg=NULL;
static void fc_rowBg(id self, SEL _cmd, NSColor *color){
  NSColor *use=color;
  @try{
    if([color isKindOfClass:[NSColor class]]){
      NSColor *s=[color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
      if(s){ CGFloat r=s.redComponent,g=s.greenComponent,b=s.blueComponent,a=s.alphaComponent;
        if(a>0.5 && fabs(r-g)<0.07 && fabs(g-b)<0.07 && r>0.13 && r<0.50){
          NSColor *t=gTheme[@"ListRowB"]; if(t) use=t; } }
    }
  }@catch(__unused NSException*e){ use=color; }
  ((void(*)(id,SEL,id))gO_rowBg)(self,_cmd,use);
}

// Window title bar: make the titlebar transparent so it shows the window's
// background, set to our toolbar color. Scoped to large (main) windows so we
// don't recolor small dialogs/panels.
// The Logic control bar / title bar sits on a BEHIND-WINDOW NSVisualEffectView (samples the
// desktop → orange wallpaper bleed that washes out the title text + toolbar glyphs). Pin an
// opaque navy CALayer on TOP of the material's container layer (below the toolbar's subviews,
// so glyphs/title stay visible) to kill the translucency. Scoped to behind-window blending.
static char kFCCoverKey;
static IMP gO_vevUpdate=NULL;
// The toolbar cover color: a near-black "ToolbarButtonBackground" (always dark, on ANY theme)
// so the un-recolorable gray tool glyphs AND the light text/buttons CONTRAST against it.
static NSColor* fc_toolbarCoverColor(void){
  return [(gTheme[@"ToolbarButtonBackground"]?:gTheme[@"MainWindowColor"]) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
}
// Add an opaque SUBVIEW at the BOTTOM of v, colored c (idempotent). Subview-based (not a layer on
// the material container) so it does NOT fight the vibrancy renderer → no 100% CPU repaint loop.
// Sits above the view's drawn/material background but below its button/glyph subviews.
static void fc_addCoverSubview(NSView *v, NSColor *c){
  @try{
    if(!v || !c) return;
    NSView *cover=objc_getAssociatedObject(v,&kFCCoverKey);
    if(cover && cover.superview==v){                 // already installed — just refresh color
      if(!CGColorEqualToColor(cover.layer.backgroundColor, c.CGColor)) cover.layer.backgroundColor=c.CGColor;
      return;
    }
    if(!cover){
      cover=[[NSView alloc] initWithFrame:v.bounds];
      [cover setWantsLayer:YES];
      [cover setAutoresizingMask:(NSViewWidthSizable|NSViewHeightSizable)];
      objc_setAssociatedObject(v,&kFCCoverKey,cover,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    cover.frame=v.bounds;
    cover.layer.backgroundColor=c.CGColor;
    [v addSubview:cover positioned:NSWindowBelow relativeTo:nil];   // bottom of subviews
  }@catch(__unused NSException*e){}
}
static void fc_vevCover(id self){
  @try{
    NSView *v=(NSView*)self;
    NSRect f=v.frame;
    // Cover short toolbar bars (any blend), NOT the window's full-width titlebar VEV (covering it
    // breaks OS title rendering) and NOT tall panels/sheets.
    if(f.size.height > 60 || f.size.height < 8 || f.size.width < 120 || f.size.width > 1200) return;
    NSColor *c=fc_toolbarCoverColor(); if(c) fc_addCoverSubview(v, c);
  }@catch(__unused NSException*e){}
}
// updateLayer is a pass-through: covering from inside it re-marks the view for display → loop.
// The periodic sweep maintains the cover instead, idempotently.
static void fc_vevUpdate(id self, SEL _cmd){ ((void(*)(id,SEL))gO_vevUpdate)(self,_cmd); }
// Sweep the view tree: cover short toolbar vibrancy bars AND the editor control-header row
// (CLgDocwControlHeaderView — the Cmd+Ctrl+Opt+T tool glyph row, a regular view not a VEV) so
// its fixed-gray glyphs get a dark high-contrast backdrop too.
static void fc_coverSweep(id v){
  @try{
    Class vev=objc_getClass("NSVisualEffectView");
    NSString *cn=NSStringFromClass([v class]);
    if(vev && [v isKindOfClass:vev]) fc_vevCover(v);
    // The control-bar background + editor control-header are regular full-width CLg views (NOT
    // the window titlebar VEV) — cover them dark so the gray tool glyphs + text on them contrast.
    else if([cn isEqualToString:@"CLgTransportBackgroundView"] || [cn containsString:@"ControlHeader"]){
      NSColor *c=fc_toolbarCoverColor(); if(c) fc_addCoverSubview((NSView*)v, c);
    }
    else if([cn isEqualToString:@"CLgEditorTabButtonsView"]){
      NSColor *c=[(gTheme[@"PanelHeaderColor"]?:gTheme[@"GIEditorContainerBackground"]) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
      if(c) fc_addCoverSubview((NSView*)v, c);
    }
    for(id s in [v subviews]) fc_coverSweep(s);
  }@catch(__unused NSException*e){}
}
static void fc_coverAllVEVs(void){
  @try{ for(NSWindow*w in [NSApp windows]){ id cv=[w contentView]; id fr=cv?[cv superview]:cv; fc_coverSweep(fr?:cv); } }@catch(__unused NSException*e){}
}

static void fc_diag(NSString *line);   // defined further below
// DIAGNOSTIC: dump every text-bearing view's class + string + textColor so we can identify what
// draws the toolbar labels, event-list columns, and ruler chord labels. Re-runs a few times so
// surfaces toggled on after launch get captured.
static int gLblDiag=0;
static void fc_dumpTextLabels(id v){
  @try{
    if([v respondsToSelector:@selector(stringValue)]){
      NSString *s=nil; @try{ s=[(id)v stringValue]; }@catch(__unused NSException*e){}
      if([s isKindOfClass:[NSString class]] && s.length>0 && gLblDiag<200){
        gLblDiag++;
        NSString *tc=@"?";
        @try{ if([v respondsToSelector:@selector(textColor)]){ id c=[(id)v performSelector:@selector(textColor)]; if(c) tc=[c description]; } }@catch(__unused NSException*e){}
        id cell=nil; @try{ if([v respondsToSelector:@selector(cell)]) cell=[(id)v performSelector:@selector(cell)]; }@catch(__unused NSException*e){}
        fc_diag([NSString stringWithFormat:@"LBL %@ cell=%@ '%@' tc=%@",NSStringFromClass([v class]),cell?NSStringFromClass([cell class]):@"-",[s substringToIndex:MIN((NSUInteger)16,s.length)],tc]);
      }
    }
    for(id sub in [v subviews]) fc_dumpTextLabels(sub);
  }@catch(__unused NSException*e){}
}
static void fc_dumpTextLabelsAll(void){ gLblDiag=0; @try{ for(NSWindow*w in [NSApp windows]){ id cv=[w contentView]; fc_dumpTextLabels([cv superview]?:cv); } }@catch(__unused NSException*e){} }
// Find a view whose title/stringValue/attributedTitle mentions "Sound"/"More" → identify Get More Sounds.
static void fc_findGetMore(id v){
  @try{
    NSString *txt=nil;
    for(NSString *sel in @[@"title",@"stringValue"]){ @try{ if([v respondsToSelector:NSSelectorFromString(sel)]){ id t=[v valueForKey:sel]; if([t isKindOfClass:[NSString class]]&&[t length]){ txt=t; break; } } }@catch(__unused NSException*e){} }
    if(!txt){ @try{ if([v respondsToSelector:@selector(attributedTitle)]){ id at=[(id)v performSelector:@selector(attributedTitle)]; if([at isKindOfClass:[NSAttributedString class]]) txt=[(NSAttributedString*)at string]; } }@catch(__unused NSException*e){} }
    if(txt && ([txt rangeOfString:@"Sound" options:NSCaseInsensitiveSearch].location!=NSNotFound || [txt rangeOfString:@"More" options:NSCaseInsensitiveSearch].location!=NSNotFound)){
      NSString *cell=@"-",*csuper=@""; @try{ if([v respondsToSelector:@selector(cell)]){id c=[(id)v performSelector:@selector(cell)]; if(c){cell=NSStringFromClass([c class]);csuper=NSStringFromClass([c superclass]);}} }@catch(__unused NSException*e){}
      NSMutableString *chain=[NSMutableString string]; id p=[v superview]; int d=0; while(p&&d<6){[chain appendFormat:@" <%@",NSStringFromClass([p class])];p=[p superview];d++;}
      fc_diag([NSString stringWithFormat:@"GMS '%@' %@ cell=%@(<%@)%@",txt,NSStringFromClass([v class]),cell,csuper,chain]);
    }
    for(id s in [v subviews]) fc_findGetMore(s);
  }@catch(__unused NSException*e){}
}
static void fc_findGetMoreAll(void){ @try{ for(NSWindow*w in [NSApp windows]){ id cv=[w contentView]; fc_findGetMore([cv superview]?:cv); } }@catch(__unused NSException*e){} }
// DIAGNOSTIC: full method list of a class (to find a custom label-draw selector).
static void fc_dumpAllMethods(NSString *cn){
  Class c=objc_getClass([cn UTF8String]); if(!c){ fc_diag([NSString stringWithFormat:@"NOCLASS %@",cn]); return; }
  unsigned int n=0; Method *ms=class_copyMethodList(c,&n);
  NSMutableArray *a=[NSMutableArray array];
  for(unsigned i=0;i<n;i++) [a addObject:NSStringFromSelector(method_getName(ms[i]))];
  if(ms) free(ms);
  fc_diag([NSString stringWithFormat:@"METH %@ (super %@): %@",cn,NSStringFromClass([c superclass]),[a componentsJoinedByString:@", "]]);
}


static void fc_tintWindow(NSWindow *w){
  @try{
    if(![w isKindOfClass:[NSWindow class]]) return;
    fc_captureSheetHierarchy(w);
    NSRect f=w.frame;
    // Tint main windows AND dialogs/sheets (Create New Track, prefs, etc.); skip tiny
    // popovers/tooltips/HUDs which look wrong filled with the panel color.
    if(f.size.width < 360 || f.size.height < 170) return;
    NSColor *c = gTheme[@"ToolbarBackground"]?:gTheme[@"MainWindowColor"]; if(!c) return;
    if(w.styleMask & NSWindowStyleMaskTitled) w.titlebarAppearsTransparent = YES;
    [w setBackgroundColor:c];
  }@catch(__unused NSException*e){}
}
// Fader handle + knob ring are drawn (often from .tif images) with NO color getter.
// After the node draws, overlay the tint via kCGBlendModeMultiply — transparent groove
// stays transparent (multiply by 0 = 0) and the bright metallic grip darkens toward
// the tint (white*blue = blue). Scoped to the fader/knob node rect.
static IMP gO_faderDraw=NULL, gO_knobDraw=NULL;
static void fc_tintDraw(CGContextRef ctx, NSRect rect, NSString *key){
  return; // disabled: overlay discolored the track without reaching the handle. Diagnosing real path.
  @try{
    NSColor *t=fc_lookupMixer(key); if(!t||!ctx) return;
    NSColor *s=[t colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]; if(!s) return;
    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeMultiply);
    CGContextSetRGBFillColor(ctx, s.redComponent, s.greenComponent, s.blueComponent, 1.0);
    CGContextFillRect(ctx, NSRectToCGRect(rect));
    CGContextRestoreGState(ctx);
  }@catch(__unused NSException*e){}
}
static void fc_faderDraw(id self, SEL _cmd, NSRect r, CGContextRef ctx){ ((void(*)(id,SEL,NSRect,CGContextRef))gO_faderDraw)(self,_cmd,r,ctx); fc_tintDraw(ctx,r,@"FaderTint"); }
static void fc_knobDraw(id self, SEL _cmd, NSRect r, CGContextRef ctx){ ((void(*)(id,SEL,NSRect,CGContextRef))gO_knobDraw)(self,_cmd,r,ctx); fc_tintDraw(ctx,r,@"KnobTint"); }

// ---- Diagnostic: discover how the metallic fader handle / knob ring image is delivered.
// The drawRect overlay proves the handle is NOT drawn in the node's drawRect (it stays
// gray). Log named-image loads + small layer-contents CGImages so we can find the real path.
static BOOL fc_debugEnabled(void) {
  static int cached = -1;
  if (cached < 0) cached = getenv("THEME4LOGIC_DEBUG") ? 1 : 0;
  return cached != 0;
}
static void fc_diag(NSString *line){
  if (!fc_debugEnabled()) return;
  static dispatch_queue_t q; static dispatch_once_t o;
  dispatch_once(&o, ^{ q = dispatch_queue_create("fc.diag", DISPATCH_QUEUE_SERIAL); });
  dispatch_async(q, ^{ @try{
    NSString *p=[fc_dir() stringByAppendingPathComponent:@"handle-diag.txt"];
    NSFileHandle *fh=[NSFileHandle fileHandleForWritingAtPath:p];
    if(!fh){ [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]; fh=[NSFileHandle fileHandleForWritingAtPath:p]; }
    [fh seekToEndOfFile];
    [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
  }@catch(__unused NSException*e){} });
}
// Toolbar / tool glyphs (Tools/*, Glyphs/*, ActionBarIcons/*) are named TEMPLATE images that
// Logic loads via imageNamed: and the system tints ~30% gray (barely visible on dark). We can't
// reach that tint via NSColor, but we CAN intercept imageNamed: and return a non-template image
// pre-painted with our ToolbarGlyphColor (re-drawn at any scale, so it stays crisp on Retina).
static IMP gO_imgNamed=NULL;
static NSMutableDictionary *gGlyphCache=nil;
static id fc_imgNamed(id self, SEL _cmd, NSString *name){
  id img=((id(*)(id,SEL,NSString*))gO_imgNamed)(self,_cmd,name);
  @try{
    if(!name || !img) return img;
    if(!([name hasPrefix:@"Tools/"]||[name hasPrefix:@"Glyphs/"]||[name hasPrefix:@"ActionBarIcons/"])) return img;
    NSColor *tint=gTheme[@"ToolbarGlyphColor"]; if(!tint) return img;
    if(!gGlyphCache) gGlyphCache=[NSMutableDictionary dictionary];
    @synchronized(gGlyphCache){ id c=gGlyphCache[name]; if(c) return c; }
    NSImage *src=(NSImage*)img; NSSize sz=src.size; if(sz.width<1||sz.height<1) return img;
    NSColor *t=[tint colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]; if(!t) return img;
    NSImage *out=[NSImage imageWithSize:sz flipped:NO drawingHandler:^BOOL(NSRect r){
      [src drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
      [t set]; NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop); return YES; }];
    [out setTemplate:NO];
    @synchronized(gGlyphCache){ gGlyphCache[name]=out; }
    return out;
  }@catch(__unused NSException*e){ return img; }
}
// NSToolbar restores its glyph images from saved config (bypassing imageNamed:), so also tint
// at DRAW time: every paint goes through drawInRect:…; read the image's name and overlay our
// ToolbarGlyphColor (SourceAtop = only the drawn glyph pixels). Catches the cached toolbar glyphs.
static IMP gO_imgDraw=NULL;
static BOOL fc_isGlyphName(NSString *n){ return n && ([n hasPrefix:@"Tools/"]||[n hasPrefix:@"Glyphs/"]||[n hasPrefix:@"ActionBarIcons/"]); }
static void fc_imgDraw(id self, SEL _cmd, NSRect dst, NSRect srcR, NSUInteger op, CGFloat frac, BOOL flip, NSDictionary* hints){
  ((void(*)(id,SEL,NSRect,NSRect,NSUInteger,CGFloat,BOOL,NSDictionary*))gO_imgDraw)(self,_cmd,dst,srcR,op,frac,flip,hints);
  @try{
    NSString *name=[(NSImage*)self name];
    if(!fc_isGlyphName(name)) return;
    NSColor *t=[gTheme[@"ToolbarGlyphColor"] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]; if(!t) return;
    [NSGraphicsContext saveGraphicsState];
    [t set]; NSRectFillUsingOperation(dst, NSCompositingOperationSourceAtop);
    [NSGraphicsContext restoreGraphicsState];
  }@catch(__unused NSException*e){}
}
// Tint a grayscale/metallic CGImage toward `tint`, preserving its shape, shadow, and
// anti-aliased alpha: draw the original, then multiply the tint clipped to the image's
// own alpha (so transparent corners stay transparent). Returns a new image (caller releases).
static CGImageRef fc_tintImage(CGImageRef src, NSColor *tint){
  if(!src||!tint) return NULL;
  size_t w=CGImageGetWidth(src), h=CGImageGetHeight(src); if(!w||!h) return NULL;
  NSColor *s=[tint colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]; if(!s) return NULL;
  CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB(); if(!cs) return NULL;
  CGContextRef c=CGBitmapContextCreate(NULL,w,h,8,0,cs,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs); if(!c) return NULL;
  CGRect r=CGRectMake(0,0,w,h);
  CGContextDrawImage(c,r,src);
  CGContextSaveGState(c);
  CGContextClipToMask(c,r,src);                 // restrict tint to the handle's opaque pixels
  CGContextSetBlendMode(c,kCGBlendModeMultiply);
  CGContextSetRGBFillColor(c,s.redComponent,s.greenComponent,s.blueComponent,1.0);
  CGContextFillRect(c,r);
  CGContextRestoreGState(c);
  CGImageRef out=CGBitmapContextCreateImage(c);
  CGContextRelease(c);
  return out;
}
// Fill a glyph image's alpha shape with a SOLID color (for toolbar template glyphs already
// rendered dim — replace, don't multiply, so they become bright on the dark theme).
static CGImageRef fc_recolorAlpha(CGImageRef src, NSColor *color){
  if(!src||!color) return NULL;
  size_t w=CGImageGetWidth(src), h=CGImageGetHeight(src); if(!w||!h) return NULL;
  NSColor *s=[color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]; if(!s) return NULL;
  CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB(); if(!cs) return NULL;
  CGContextRef c=CGBitmapContextCreate(NULL,w,h,8,0,cs,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs); if(!c) return NULL;
  CGRect r=CGRectMake(0,0,w,h);
  CGContextClipToMask(c,r,src);
  CGContextSetRGBFillColor(c,s.redComponent,s.greenComponent,s.blueComponent,1.0);
  CGContextFillRect(c,r);
  CGImageRef out=CGBitmapContextCreateImage(c);
  CGContextRelease(c);
  return out;
}
// Is this layer owned by a view inside an NSToolbar? (walk the delegate view's superview chain)
static BOOL fc_layerInToolbar(id layer){
  @try{
    id v=[layer valueForKey:@"delegate"]; int d=0;
    while(v && d<9){
      NSString *n=NSStringFromClass([v class]);
      if([n rangeOfString:@"Toolbar"].location!=NSNotFound) return YES;
      @try{ v=[v valueForKey:@"superview"]; }@catch(__unused NSException*e){ v=nil; }
      d++;
    }
  }@catch(__unused NSException*e){}
  return NO;
}
// Walk up the layer's superlayer chain (the node that owns it may be several levels up).
// Return the first MA-mixer-node ancestor's delegate class name + the depth, into *outName.
static NSString* fc_firstMAAncestor(id layer){
  id l=layer; int depth=0;
  while(l && depth<10){
    id dlg=nil; @try{ dlg=[l valueForKey:@"delegate"]; }@catch(__unused NSException*e){}
    if(dlg){ NSString *n=NSStringFromClass([dlg class]); if([n hasPrefix:@"MA"]||[n hasPrefix:@"_MA"]||[n containsString:@".MA"]) return [NSString stringWithFormat:@"%@@%d", n, depth]; }
    @try{ l=[l valueForKey:@"superlayer"]; }@catch(__unused NSException*e){ l=nil; }
    depth++;
  }
  return nil;
}
// Tint to apply, based on the owning mixer node found by walking up the chain.
static NSColor* fc_chainTint(id layer){
  id l=layer; int depth=0;
  while(l && depth<10){
    id dlg=nil; @try{ dlg=[l valueForKey:@"delegate"]; }@catch(__unused NSException*e){}
    if(dlg){
      NSString *n=NSStringFromClass([dlg class]);
      if([n isEqualToString:@"MAFaderNode"]) return fc_lookupMixer(@"FaderTint");
      if([n isEqualToString:@"_MACapNode"]||[n isEqualToString:@"MAKnobNode"]) return fc_lookupMixer(@"KnobTint");
      if([n isEqualToString:@"MAKitScroller"]) return fc_lookupMixer(@"ScrollerTint");
    }
    @try{ l=[l valueForKey:@"superlayer"]; }@catch(__unused NSException*e){ l=nil; }
    depth++;
  }
  return nil;
}
static IMP gO_setContents=NULL;
static void fc_setContents(id self, SEL _cmd, id contents){
  @try{
    if(contents && CFGetTypeID((__bridge CFTypeRef)contents)==CGImageGetTypeID()){
      NSColor *t=fc_chainTint(self);
      if(t){
        CGImageRef out=fc_tintImage((__bridge CGImageRef)contents,t);
        if(out){ ((void(*)(id,SEL,id))gO_setContents)(self,_cmd,(__bridge id)out); CGImageRelease(out); return; }
      }
      // Toolbar glyph layers: small image owned by a view inside an NSToolbar → recolor bright.
      size_t w=CGImageGetWidth((__bridge CGImageRef)contents), h=CGImageGetHeight((__bridge CGImageRef)contents);
      if(w<=64 && h<=64 && fc_layerInToolbar(self)){
        NSColor *g=gTheme[@"ToolbarGlyphColor"];
        if(g){ CGImageRef out=fc_recolorAlpha((__bridge CGImageRef)contents,g);
          if(out){ ((void(*)(id,SEL,id))gO_setContents)(self,_cmd,(__bridge id)out); CGImageRelease(out); fc_diag([NSString stringWithFormat:@"GLYPH %zux%zu",w,h]); return; } } }
    }
  }@catch(__unused NSException*e){}
  ((void(*)(id,SEL,id))gO_setContents)(self,_cmd,contents);
}
// The secondary (editing-tools) toolbar's glyphs are a fixed dim gray we can't recolor, so give
// them CONTRAST instead: paint the toolbar's own background view an always-dark color (independent
// of the chosen theme). Also set contentTintColor (helps any glyphs that DO honor it).
static void fc_tintToolbarView(id v, BOOL inToolbar){
  @try{
    NSString *cn=NSStringFromClass([v class]);
    BOOL isToolbar = [cn containsString:@"Toolbar"] || [cn containsString:@"ControlHeader"];
    BOOL nowIn = inToolbar || isToolbar;
    if(isToolbar){
      // Darken the toolbar container's background → gray glyphs pop on near-black.
      NSColor *bg=gTheme[@"ToolbarButtonBackground"];
      if(bg){ @try{ [v setWantsLayer:YES]; ((CALayer*)[v layer]).backgroundColor=[bg colorUsingColorSpace:[NSColorSpace sRGBColorSpace]].CGColor; }@catch(__unused NSException*e){} }
    }
    if(nowIn && [v respondsToSelector:@selector(setContentTintColor:)]){
      NSColor *g=gTheme[@"ToolbarGlyphColor"]; if(g) [v setContentTintColor:g];
    }
    for(id sub in [v subviews]) fc_tintToolbarView(sub, nowIn);
  }@catch(__unused NSException*e){}
}
// DIAGNOSTIC: dump wide-short views (toolbar-row candidates) with class + on-screen frame.
static void fc_dumpBars(id v){
  @try{
    NSRect f=[v frame]; id win=[v window];
    if(win && f.size.width>=500 && f.size.height>=16 && f.size.height<=44){
      NSRect scr=[win convertRectToScreen:[v convertRect:[v bounds] toView:nil]];
      fc_diag([NSString stringWithFormat:@"BAR %@ scrY=%.0f h=%.0f w=%.0f", NSStringFromClass([v class]), scr.origin.y, f.size.height, f.size.width]);
    }
    for(id s in [v subviews]) fc_dumpBars(s);
  }@catch(__unused NSException*e){}
}
static void fc_tintToolbars(void){
  @try{ id app=[objc_getClass("NSApplication") sharedApplication];
    for(id w in [app windows]){ id cv=[w contentView]; id frame=cv?[cv superview]:nil; fc_tintToolbarView(frame?:cv, NO); fc_dumpBars(frame?:cv); }
  }@catch(__unused NSException*e){}
}
// The editor control-header / tool-bar paints its navy background in drawRect: (layer bg can't
// override it). Fill it dark AFTER the original draws — the glyph/menu subviews render on top,
// so they stay visible and the fixed gray tool glyphs get a high-contrast dark backdrop.
static void fc_paintToolbarBackdrop(id self){
  @try{ NSColor *bg=gTheme[@"defaultToolbarBackgroundColor"]?:gTheme[@"ToolbarButtonBackground"]?:gTheme[@"GIEditorContainerBackground"]; if(!bg) return;
    [[bg colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] set]; NSRectFill([self bounds]);
  }@catch(__unused NSException*e){}
}
static IMP gO_ctrlHdrDraw=NULL;
static void fc_ctrlHdrDraw(id self, SEL _cmd, NSRect rect){
  ((void(*)(id,SEL,NSRect))gO_ctrlHdrDraw)(self,_cmd,rect);
  fc_paintToolbarBackdrop(self);
}
static IMP gO_editorTabDraw=NULL;
static void fc_editorTabDraw(id self, SEL _cmd, NSRect rect){
  ((void(*)(id,SEL,NSRect))gO_editorTabDraw)(self,_cmd,rect);
  @try{ NSColor *bg=gTheme[@"PanelHeaderColor"]?:gTheme[@"GIEditorContainerBackground"]?:gTheme[@"MainWindowColor"]; if(!bg) return;
    [[bg colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] set]; NSRectFill([self bounds]);
  }@catch(__unused NSException*e){}
}
// Track / audio / sample editor waveform canvas: stock Logic fills a flat gray in drawRect:
// via Core Graphics, bypassing catalog NSColor hooks. Pre-fill with the themed editor bg so
// grid lines + waveform render on top of the preset surface instead of stock #2e2e2e.
static NSColor* fc_editorCanvasBg(void){
  return [(gTheme[@"GIEditorViewBackground1"]?:gTheme[@"GIEditorContainerBackground"]?:gTheme[@"ArrangeWorkspaceColor"]) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
}
static NSColor* fc_editorScaleBg(void){
  return [(gTheme[@"GIEditorViewBackground2"]?:gTheme[@"EditorScale"]?:gTheme[@"GIEditorViewBackground1"]?:gTheme[@"GIEditorContainerBackground"]) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
}
#define FC_EDCANVAS(gOrig, fn, bgfn) \
  static IMP gOrig=NULL; \
  static void fn(id self,SEL _cmd,NSRect r){ \
    @try{ NSColor*b=bgfn(); if(b){ [b set]; NSRectFill([self bounds]); } }@catch(__unused NSException*e){} \
    if(gOrig) ((void(*)(id,SEL,NSRect))gOrig)(self,_cmd,r); }
FC_EDCANVAS(gO_edBodyDraw, fc_edBodyDraw, fc_editorCanvasBg)
FC_EDCANVAS(gO_audioEdDraw, fc_audioEdDraw, fc_editorCanvasBg)
FC_EDCANVAS(gO_sampleEdDraw, fc_sampleEdDraw, fc_editorCanvasBg)
FC_EDCANVAS(gO_beatsEdDraw, fc_beatsEdDraw, fc_editorCanvasBg)
FC_EDCANVAS(gO_docwEdDraw, fc_docwEdDraw, fc_editorCanvasBg)
FC_EDCANVAS(gO_docwEdScrollDraw, fc_docwEdScrollDraw, fc_editorCanvasBg)
FC_EDCANVAS(gO_edAreaDraw, fc_edAreaDraw, fc_editorCanvasBg)
FC_EDCANVAS(gO_audioScaleDraw, fc_audioScaleDraw, fc_editorScaleBg)
#undef FC_EDCANVAS
static void fc_installEditorCanvasHooks(void){
  #define HOOK(cls,gOrig,fn) { if(fc_hookAllowed(@"instance", @cls, @"drawRect:")){ Class _c=objc_getClass(cls); if(_c){ IMP _o=fc_swizzleInstSubclassOnly(_c,NSSelectorFromString(@"drawRect:"),(IMP)fn); if(_o)gOrig=_o; } } }
  HOOK("CLgDocwEditorBodyView", gO_edBodyDraw, fc_edBodyDraw)
  HOOK("CLgDocwEditorView", gO_docwEdDraw, fc_docwEdDraw)
  HOOK("CLgDocwEditorViewScrolling", gO_docwEdScrollDraw, fc_docwEdScrollDraw)
  HOOK("CLgEditorAreaView", gO_edAreaDraw, fc_edAreaDraw)
  HOOK("CLgAudioEditorView", gO_audioEdDraw, fc_audioEdDraw)
  HOOK("CLgAudioEditorKeyboardContentsView", gO_audioScaleDraw, fc_audioScaleDraw)
  HOOK("CLgSampleEditorView", gO_sampleEdDraw, fc_sampleEdDraw)
  HOOK("CLgBeatsEditorView", gO_beatsEdDraw, fc_beatsEdDraw)
  #undef HOOK
}
static void fc_installDiag(void){
  static dispatch_once_t o; dispatch_once(&o,^{
    // setContents hook is the live cap/scroller image tinter (not diagnostic) — keep it.
    Class cl=objc_getClass("CALayer"); if(cl && fc_hookAllowed(@"instance", @"CALayer", @"setContents:")){ IMP p=fc_swizzleInst(cl,NSSelectorFromString(@"setContents:"),(IMP)fc_setContents); if(p)gO_setContents=p; }
    Class ni=objc_getClass("NSImage");
    if(ni && fc_hookAllowed(@"class", @"NSImage", @"imageNamed:")){ IMP p=fc_swizzleClass(ni,NSSelectorFromString(@"imageNamed:"),(IMP)fc_imgNamed); if(p)gO_imgNamed=p; }
    // Draw-time glyph tint (catches NSToolbar's restored/cached glyph images).
    if(ni && fc_hookAllowed(@"instance", @"NSImage", @"drawInRect:fromRect:operation:fraction:respectFlipped:hints:")){ IMP p=fc_swizzleInst(ni,NSSelectorFromString(@"drawInRect:fromRect:operation:fraction:respectFlipped:hints:"),(IMP)fc_imgDraw); if(p)gO_imgDraw=p; }
  });
}

// ---- Vibrancy diagnostic: the Library / Loop-Browser panels render as translucent GRAY
// (NSVisualEffectView material), which our NSColor hooks don't touch. Enumerate the live
// view tree to confirm exactly which views draw the gray, with frame/material/state.
static void fc_vdiag(NSString *s){
  static dispatch_queue_t q; static dispatch_once_t o; dispatch_once(&o,^{ q=dispatch_queue_create("fc.vdiag",DISPATCH_QUEUE_SERIAL); });
  dispatch_async(q, ^{ @try{
    NSString *p=[fc_dir() stringByAppendingPathComponent:@"vibrancy-diag.txt"];
    NSFileHandle *fh=[NSFileHandle fileHandleForWritingAtPath:p];
    if(!fh){ [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]; fh=[NSFileHandle fileHandleForWritingAtPath:p]; }
    [fh seekToEndOfFile]; [fh writeData:[[s stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile];
  }@catch(__unused NSException*e){} });
}
// Logic paints two distinct accent blues as flat CG fills (outside catalog hooks):
//   • system accent ~ sRGB (0.073, 0.384, 0.730) — segmented tabs, active tools
//   • catalog selection ~ sRGB (0.176, 0.380, 0.600) — Browser/SelectionPrimary, table rows
static const CGFloat kAccentBlueR=0.073f, kAccentBlueG=0.384f, kAccentBlueB=0.730f, kAccentBlueTol=0.060f;
static const CGFloat kLogicSelR=0.176f, kLogicSelG=0.380f, kLogicSelB=0.600f, kLogicSelTol=0.070f;
static BOOL gAccentRGBValid=NO; static CGFloat gAccentR=0,gAccentG=0,gAccentB=0;
static BOOL gTabSelRGBValid=NO; static CGFloat gTabSelR=0,gTabSelG=0,gTabSelB=0;
static void fc_ensureAccentRGB(void){
  if(gAccentRGBValid) return;
  NSColor*t=[gTheme[@"AccentColor"] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
  if(t){ gAccentR=t.redComponent; gAccentG=t.greenComponent; gAccentB=t.blueComponent; gAccentRGBValid=YES; }
}
static void fc_ensureTabSelRGB(void){
  if(gTabSelRGBValid) return;
  NSColor*t=[(gTheme[@"TabBackgroundSelectedColor"]?:gTheme[@"Browser/SelectionPrimary"]?:gTheme[@"SelectionColor"]) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
  if(t){ gTabSelR=t.redComponent; gTabSelG=t.greenComponent; gTabSelB=t.blueComponent; gTabSelRGBValid=YES; }
}
static inline BOOL fc_isAccentBlue(CGFloat r, CGFloat g, CGFloat b){
  if(fc_isSystemBlue(r,g,b)) return YES;
  return (r>=kAccentBlueR-kAccentBlueTol && r<=kAccentBlueR+kAccentBlueTol && g>=kAccentBlueG-kAccentBlueTol && g<=kAccentBlueG+kAccentBlueTol && b>=kAccentBlueB-kAccentBlueTol && b<=kAccentBlueB+kAccentBlueTol);
}
static inline BOOL fc_isSelectionBlue(CGFloat r, CGFloat g, CGFloat b){
  return (r>=kLogicSelR-kLogicSelTol && r<=kLogicSelR+kLogicSelTol && g>=kLogicSelG-kLogicSelTol && g<=kLogicSelG+kLogicSelTol && b>=kLogicSelB-kLogicSelTol && b<=kLogicSelB+kLogicSelTol);
}
// Gray control-face faces (X/heart/filter-container/Get-More-Sounds/etc.) are flat CG fills of a
// neutral mid-dark gray that the named-color hooks never see. Substitute neutral grays in a bounded
// range → ToolbarButtonFill (navy). Light grays (icon glyphs/text) are left alone so they stay legible.
// LayerEditorBackground (~35/255≈0.137) and ArrangeWorkspace (~46/255≈0.18) sit below the
// old kGrayLo=0.155 — extend downward so editor canvas fills bypassing NSColor get themed.
static const CGFloat kGrayLo=0.10f, kGrayHi=0.42f, kGraySplit=0.205f;
static const CGFloat kLightSelLo=0.60f, kLightSelHi=0.88f;
// Two cached targets: dark grays (panel/header/footer bg) → ToolbarButtonBackground (dark navy);
// mid grays (button faces) → ToolbarButtonFill (lighter navy, so controls stand out from the panel).
static BOOL gFillRGBValid=NO; static CGFloat gFillR=0,gFillG=0,gFillB=0;     // button face
static BOOL gPanelRGBValid=NO; static CGFloat gPanelR=0,gPanelG=0,gPanelB=0; // panel/bg
static BOOL gSelRGBValid=NO; static CGFloat gSelR=0,gSelG=0,gSelB=0;         // ruler/time selection
static void fc_ensureFillRGB(void){
  if(!gFillRGBValid){ NSColor*t=[(gTheme[@"ToolbarButtonFill"]?:gTheme[@"ControlColor"]) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if(t){ gFillR=t.redComponent; gFillG=t.greenComponent; gFillB=t.blueComponent; gFillRGBValid=YES; } }
  if(!gPanelRGBValid){ NSColor*t=[(gTheme[@"ToolbarButtonBackground"]?:gTheme[@"PanelBackgroundColor"]?:gTheme[@"MainWindowColor"]) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if(t){ gPanelR=t.redComponent; gPanelG=t.greenComponent; gPanelB=t.blueComponent; gPanelRGBValid=YES; } }
  if(!gSelRGBValid){ NSColor*t=[(gTheme[@"GlobalTracksChordGhostRulerOverlay"]?:gTheme[@"RulerMarkerSelectedColor"]?:gTheme[@"SelectionColor"]) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if(t){ gSelR=t.redComponent; gSelG=t.greenComponent; gSelB=t.blueComponent; gSelRGBValid=YES; } }
}
// 0 = not a control gray; 1 = dark/panel gray; 2 = mid/button-face gray.
static inline int fc_grayClass(CGFloat r, CGFloat g, CGFloat b){
  CGFloat mx=fmax(r,fmax(g,b)), mn=fmin(r,fmin(g,b));
  if((mx-mn)>0.030f || mx<kGrayLo || mx>kGrayHi) return 0;
  return (mx<kGraySplit)?1:2;
}
// Light neutral grays (RulerMarkerSelectedColor ~0.71, ArrangeWorkspaceBrightColor ~0.70) drawn
// as flat CG fills bypass catalog hooks — remap to themed ruler/time selection.
static inline BOOL fc_lightSelGray(CGFloat r, CGFloat g, CGFloat b){
  CGFloat mx=fmax(r,fmax(g,b)), mn=fmin(r,fmin(g,b));
  return (mx-mn)<=0.030f && mx>=kLightSelLo && mx<=kLightSelHi;
}
// Logic's default region swatches are saturated fills painted via Core
// Graphics, so they bypass the catalog and AppKit semantic color hooks. Keep
// this deliberately narrow: match the Logic 12.3 stock swatch table by
// distance (rather than every yellow/green pixel), and require a large,
// horizontal drawing context so meters, warnings, and plugin controls stay
// untouched. Each source swatch maps to the same slot in the theme palette.
static const CGFloat kLogicStockRegionSwatches[12][3] = {
  {0.761f, 0.651f, 0.231f}, {0.557f, 0.698f, 0.325f},
  {0.318f, 0.710f, 0.424f}, {0.294f, 0.710f, 0.655f},
  {0.310f, 0.569f, 0.757f}, {0.361f, 0.439f, 0.745f},
  {0.541f, 0.408f, 0.733f}, {0.706f, 0.420f, 0.635f},
  {0.757f, 0.420f, 0.510f}, {0.788f, 0.459f, 0.396f},
  {0.784f, 0.541f, 0.333f}, {0.667f, 0.627f, 0.298f}
};
static BOOL fc_stockRegionColor(CGContextRef ctx, CGFloat r, CGFloat g, CGFloat b, NSUInteger *index){
  if (!gRegionPalette.count || gRegionPalette.count < 12 || !ctx) return NO;
  CGRect clip=CGContextGetClipBoundingBox(ctx);
  if (clip.size.width < 180.0f || clip.size.height < 8.0f ||
      clip.size.height > 260.0f || clip.size.width < clip.size.height * 2.0f) return NO;
  NSUInteger best=0; CGFloat bestDistance=CGFLOAT_MAX;
  for (NSUInteger i=0; i<12; i++) {
    CGFloat dr=r-kLogicStockRegionSwatches[i][0], dg=g-kLogicStockRegionSwatches[i][1], db=b-kLogicStockRegionSwatches[i][2];
    CGFloat distance=dr*dr+dg*dg+db*db;
    if(distance<bestDistance){ bestDistance=distance; best=i; }
  }
  if(bestDistance>0.055f*0.055f) return NO;
  if(index) *index=best;
  return YES;
}
static NSColor *fc_regionReplacement(CGContextRef ctx, CGFloat r, CGFloat g, CGFloat b){
  NSUInteger index=0;
  if (!fc_stockRegionColor(ctx,r,g,b,&index) || index>=gRegionPalette.count) return nil;
  return gRegionPalette[index];
}
// ---- Mixer slot titles ------------------------------------------------------------
// -[MAStripNode drawSlotTitle:frame:inContext:] draws the placeholder labels of empty channel
// strip slots ("EQ", "Audio FX") in pure black, sized for Logic's mid-grey slot. Themes darken
// that slot, so black-on-dark becomes unreadable. While a slot title draws in a dark theme,
// near-black neutral ink is swapped for the theme's secondary text color. Plug-in names (white
// on blue) and every other fill are untouched.
static __thread int gInSlotTitle = 0;
static IMP gO_slotTitle = NULL;
static BOOL fc_slotTitleInk(CGFloat r, CGFloat g, CGFloat b, CGFloat a, CGFloat *or_, CGFloat *og, CGFloat *ob){
  if (gInSlotTitle <= 0 || a < 0.5) return NO;   // opaque caption ink only; faint outlines/shadows stay
  CGFloat mx=MAX(r,MAX(g,b)), mn=MIN(r,MIN(g,b));
  if (mx > 0.2 || mx - mn > 0.04) return NO;
  NSColor *t=[(gTheme[@"TextSecondaryColor"] ?: gTheme[@"TextColor"]) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
  if (!t) return NO;
  CGFloat tl=0.2126*t.redComponent + 0.7152*t.greenComponent + 0.0722*t.blueComponent;
  if (tl < 0.45) return NO;   // light theme: its text is dark already, black reads fine
  *or_=t.redComponent; *og=t.greenComponent; *ob=t.blueComponent;
  return YES;
}
static void fc_slotTitle(id s, SEL c, id title, CGRect frame, CGContextRef ctx){
  gInSlotTitle++;
  @try { ((void(*)(id,SEL,id,CGRect,CGContextRef))gO_slotTitle)(s,c,title,frame,ctx); }
  @finally { gInSlotTitle--; }
}
// Slot buttons draw the empty "Group" slot's caption in black the same way.
static IMP gO_slotBtnLayer = NULL;
static void fc_slotBtnLayer(id s, SEL c, id layer, CGContextRef ctx){
  gInSlotTitle++;
  @try { ((void(*)(id,SEL,id,CGContextRef))gO_slotBtnLayer)(s,c,layer,ctx); }
  @finally { gInSlotTitle--; }
}
// The empty EQ thumbnail draws its "EQ" caption the same way, in its own node class.
static IMP gO_eqTitle = NULL;
static void fc_eqTitle(id s, SEL c, CGRect r, CGContextRef ctx){
  gInSlotTitle++;
  @try { ((void(*)(id,SEL,CGRect,CGContextRef))gO_eqTitle)(s,c,r,ctx); }
  @finally { gInSlotTitle--; }
}

// CG fill interposition (calls to the real symbol from THIS image are not re-interposed by dyld).
static void fc_cgSetFill(CGContextRef ctx, CGColorRef color){
  if (!fc_hookAllowed(@"interpose", @"CoreGraphics", @"CGContextSetFillColorWithColor")) {
    CGContextSetFillColorWithColor(ctx,color);
    return;
  }
  @try{
    if(color && gInSlotTitle>0){
      size_t n=CGColorGetNumberOfComponents(color); const CGFloat *c=CGColorGetComponents(color);
      if(c && (n==2 || n>=3)){
        CGFloat r=c[0], g=(n>=3?c[1]:c[0]), b=(n>=3?c[2]:c[0]), a=c[n-1], nr,ng,nb;
        if(n==3) a=1.0;
        if(fc_slotTitleInk(r,g,b,a,&nr,&ng,&nb)){ CGColorRef cc=CGColorCreateGenericRGB(nr,ng,nb,a); CGContextSetFillColorWithColor(ctx,cc); CGColorRelease(cc); return; }
      }
    }
    if(color){
      size_t n=CGColorGetNumberOfComponents(color); const CGFloat *c=CGColorGetComponents(color);
      if(n>=3 && c){ CGFloat r=c[0],g=c[1],b=c[2],a=(n>=4?c[3]:1.0);
        NSColor *region=fc_regionReplacement(ctx,r,g,b); if(region){
          NSColor *s=[region colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
          if(s){ CGColorRef cc=CGColorCreateGenericRGB(s.redComponent,s.greenComponent,s.blueComponent,a); CGContextSetFillColorWithColor(ctx,cc); CGColorRelease(cc); return; }
        }
        if(fc_isAccentBlue(r,g,b)){ fc_ensureAccentRGB(); if(gAccentRGBValid){
          CGColorRef cc=CGColorCreateGenericRGB(gAccentR,gAccentG,gAccentB,a); CGContextSetFillColorWithColor(ctx,cc); CGColorRelease(cc); return; } }
        if(fc_isSelectionBlue(r,g,b)){ fc_ensureTabSelRGB(); if(gTabSelRGBValid){
          CGColorRef cc=CGColorCreateGenericRGB(gTabSelR,gTabSelG,gTabSelB,a); CGContextSetFillColorWithColor(ctx,cc); CGColorRelease(cc); return; } }
        { CGFloat nr,ng,nb; if(fc_autoAccentRGB(r,g,b,&nr,&ng,&nb)){ CGColorRef cc=CGColorCreateGenericRGB(nr,ng,nb,a); CGContextSetFillColorWithColor(ctx,cc); CGColorRelease(cc); return; } }
        if(!fc_isThemedRGB(r,g,b)){ int gc=fc_grayClass(r,g,b); if(gc){ fc_ensureFillRGB();
          if(gc==1 && gPanelRGBValid){ CGColorRef cc=CGColorCreateGenericRGB(gPanelR,gPanelG,gPanelB,a); CGContextSetFillColorWithColor(ctx,cc); CGColorRelease(cc); return; }
          if(gc==2 && gFillRGBValid){ CGColorRef cc=CGColorCreateGenericRGB(gFillR,gFillG,gFillB,a); CGContextSetFillColorWithColor(ctx,cc); CGColorRelease(cc); return; } }
        if(fc_lightSelGray(r,g,b)){ fc_ensureFillRGB(); if(gSelRGBValid){
          CGColorRef cc=CGColorCreateGenericRGB(gSelR,gSelG,gSelB,a); CGContextSetFillColorWithColor(ctx,cc); CGColorRelease(cc); return; } } }
      }
    }
  }@catch(__unused NSException*e){}
  CGContextSetFillColorWithColor(ctx,color);
}
static void fc_cgSetRGBFill(CGContextRef ctx, CGFloat r, CGFloat g, CGFloat b, CGFloat a){
  if (!fc_hookAllowed(@"interpose", @"CoreGraphics", @"CGContextSetRGBFillColor")) {
    CGContextSetRGBFillColor(ctx,r,g,b,a);
    return;
  }
  @try{
    { CGFloat nr,ng,nb; if(fc_slotTitleInk(r,g,b,a,&nr,&ng,&nb)){ CGContextSetRGBFillColor(ctx,nr,ng,nb,a); return; } }
    NSColor *region=fc_regionReplacement(ctx,r,g,b); if(region){
      NSColor *s=[region colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
      if(s){ CGContextSetRGBFillColor(ctx,s.redComponent,s.greenComponent,s.blueComponent,a); return; }
    }
    if(fc_isAccentBlue(r,g,b)){ fc_ensureAccentRGB(); if(gAccentRGBValid){ CGContextSetRGBFillColor(ctx,gAccentR,gAccentG,gAccentB,a); return; } }
    if(fc_isSelectionBlue(r,g,b)){ fc_ensureTabSelRGB(); if(gTabSelRGBValid){ CGContextSetRGBFillColor(ctx,gTabSelR,gTabSelG,gTabSelB,a); return; } }
    { CGFloat nr,ng,nb; if(fc_autoAccentRGB(r,g,b,&nr,&ng,&nb)){ CGContextSetRGBFillColor(ctx,nr,ng,nb,a); return; } }
    if(!fc_isThemedRGB(r,g,b)){ int gc=fc_grayClass(r,g,b); if(gc){ fc_ensureFillRGB();
      if(gc==1 && gPanelRGBValid){ CGContextSetRGBFillColor(ctx,gPanelR,gPanelG,gPanelB,a); return; }
      if(gc==2 && gFillRGBValid){ CGContextSetRGBFillColor(ctx,gFillR,gFillG,gFillB,a); return; } }
    if(fc_lightSelGray(r,g,b)){ fc_ensureFillRGB(); if(gSelRGBValid){ CGContextSetRGBFillColor(ctx,gSelR,gSelG,gSelB,a); return; } } }
  }@catch(__unused NSException*e){}
  CGContextSetRGBFillColor(ctx,r,g,b,a);
}
__attribute__((used)) static struct{const void*a;const void*b;}
  _fc_ip_setfill __attribute__((section("__DATA,__interpose"))) = {(const void*)fc_cgSetFill,(const void*)CGContextSetFillColorWithColor};
__attribute__((used)) static struct{const void*a;const void*b;}
  _fc_ip_setrgbfill __attribute__((section("__DATA,__interpose"))) = {(const void*)fc_cgSetRGBFill,(const void*)CGContextSetRGBFillColor};

// Dump every color-returning selector on the mixer node classes so we know exactly
// what to hook (knob/fader/scale/legend/pan/meter getters) — written once.
static void fc_dumpNodeMethods(void){
  NSArray *classes=@[@"MAStripNode",@"MAFaderNode",@"MAKnobNode",@"MAScaleNode",@"MAScaleTick",
    @"MAGainReductionMeterNode",@"MAPlanarPannerNode",@"MAStereoPannerNode",@"MAButtonNode",
    @"MASymbolButtonNode",@"MATextNode",@"MADisplayNode",@"MAImageNode",@"MAShapeNode",
    @"MixerLegendView",@"MixerLegendViewController",@"MANodeView",@"MAView",@"MAPopUpButton"];
  NSMutableString *out=[NSMutableString string];
  for(NSString *cn in classes){
    Class c=objc_getClass(cn.UTF8String); if(!c){[out appendFormat:@"\n== %@ (not loaded) ==\n",cn];continue;}
    [out appendFormat:@"\n== %@ ==\n",cn];
    unsigned int n=0; Method *ms=class_copyMethodList(c,&n);
    for(unsigned int i=0;i<n;i++){
      NSString *sel=NSStringFromSelector(method_getName(ms[i]));
      NSString *lo=sel.lowercaseString;
      if([lo containsString:@"color"]||[lo containsString:@"draw"]) [out appendFormat:@"  %@\n",sel];
    }
    if(ms) free(ms);
  }
  [out writeToFile:[fc_dir() stringByAppendingPathComponent:@"node-methods.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void fc_tryInstallNodes(void){
  Class strip = objc_getClass("MAStripNode");
  if(!strip) return;
  dispatch_once(&gNodesOnce, ^{
    if (fc_debugEnabled()) fc_dumpNodeMethods();
    #define INST(cls,sel,gOrig,fn){if(fc_hookAllowed(@"instance", @cls, @sel)){Class _c=objc_getClass(cls);if(_c){IMP _o=fc_swizzleInstSubclassOnly(_c,NSSelectorFromString(@sel),(IMP)fn);if(_o)gOrig=_o;}}}
    INST("MAStripNode","backgroundColor",gO_stripBg,fc_stripBg)
    INST("MAStripNode","highlightedBackgroundColor",gO_stripSel,fc_stripSel)
    INST("MAStripNode","borderColor",gO_stripBd,fc_stripBd)
    INST("MAStripNode","drawSlotTitle:frame:inContext:",gO_slotTitle,fc_slotTitle)  // "Audio FX" etc. placeholders
    INST("MAEQThumbnailNode","drawTitleInRect:inContext:",gO_eqTitle,fc_eqTitle)    // empty EQ thumbnail caption
    INST("MASlotButtonNode","drawLayer:inContext:",gO_slotBtnLayer,fc_slotBtnLayer) // empty "Group" slot caption
    INST("MAKnobNode","trackColor",gO_knobTrk,fc_knobTrk)
    INST("MAKnobNode","indicatorColor",gO_knobInd,fc_knobInd)
    INST("MAScaleNode","labelColor",gO_scaleLbl,fc_scaleLbl)
    INST("MAScaleTick","color",gO_tickCol,fc_tickCol)
    INST("MAGainReductionMeterNode","fillColor",gO_meterFill,fc_meterFill)
    INST("MAGainReductionMeterNode","backgroundFillColor",gO_meterBg,fc_meterBg)
    INST("MAFaderNode","drawRect:inContext:",gO_faderDraw,fc_faderDraw)
    INST("MAKnobNode","drawRect:inContext:",gO_knobDraw,fc_knobDraw)
    INST("MixerLegendView","backgroundColor",gO_legendBg,fc_legendBg)
    INST("MAShapeNode","fillColor",gO_shapeFill,fc_shapeFill)
    INST("MAShapeNode","strokeColor",gO_shapeStrk,fc_shapeStrk)
    INST("MAKitView","backgroundColor",gO_kitBg,fc_kitBg)
    INST("MAKitTableView","backgroundColor",gO_tblBg,fc_tblBg)
    INST("MAKitTableView","_alternatingRowBackgroundColors",gO_maAltRows,fc_maAltRows)
    INST("MAKitOutlineView","backgroundColor",gO_outBg,fc_outBg)
    // Toolbar/button glyph recolor via the node color SETTERS (see fc_glyphSub).
    INST("MASymbolButtonNode","setForegroundColor:",gO_symSetFg,fc_symSetFg)
    INST("MASymbolButtonNode","setContentTintColor:",gO_symSetTint,fc_symSetTint)
    INST("MAButtonNode","setForegroundColor:",gO_btnSetFg,fc_btnSetFg)
    INST("MAButtonNode","setContentTintColor:",gO_btnSetTint,fc_btnSetTint)
    INST("MASymbolButtonNode","setSymbol:",gO_symSetSymbol,fc_symSetSymbol)
    INST("MAButtonNode","foregroundColor",gO_btnFgGet,fc_btnFgGet)
    INST("MATextNode","foregroundColor",gO_txtFgGet,fc_txtFgGet)
    INST("MADisplayNode","foregroundColor",gO_dispFgGet,fc_dispFgGet)
    INST("MAActionBarButton","drawRect:",gO_abDrawRect,fc_abDrawRect)  // secondary-toolbar tool labels
    INST("CLgActionBarSegmentedControl","drawRect:",gO_segDR,fc_segDR)  // container that draws the captions
    INST("CLgActionBarView","drawRect:",gO_abvDR,fc_abvDR)
    // Loop-browser / MA popup + segmented button containers (the gray bezels the user flagged):
    INST("MAPopUpButtonCell","drawBorderAndBackgroundWithFrame:inView:",gO_ppBg,fc_ppBg)
    INST("MAPopUpButtonCell","titleColor",gO_ppTitle,fc_ppTitle)
    INST("MAPopUpButtonCell","menuArrowColor",gO_ppArrow,fc_ppArrow)
    INST("MALoopBrowserSegmentedTextLabelCell","drawWithFrame:inView:",gO_segLbl,fc_segLbl)
    INST("MALoopBrowserVolumeSliderCell","drawWithFrame:inView:",gO_volSlider,fc_volSlider)
    INST("MALoopBrowserVolumeSliderCell","drawBarInside:flipped:",gO_sliderBar,fc_sliderBar)
    INST("MAButtonCell","titleColor",gO_btnTitle,fc_btnTitle)
    { Class cl=objc_getClass("CALayer"); if(cl && fc_hookAllowed(@"instance", @"CALayer", @"setBackgroundColor:")){IMP o=fc_swizzleInst(cl,NSSelectorFromString(@"setBackgroundColor:"),(IMP)fc_layerBg); if(o)gO_layerBg=o;} }
    #undef INST
    os_log(OS_LOG_DEFAULT,"[Theme4Logic] mixer node hooks installed");
    // Repaint anything already drawn.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1500*NSEC_PER_MSEC)),dispatch_get_main_queue(),^{
      for(NSWindow*w in [NSApp windows]) [w.contentView setNeedsDisplay:YES];
    });
  });
}
static void fc_imageAdded(const struct mach_header *mh, intptr_t slide){ (void)mh;(void)slide; fc_tryInstallMixer(); fc_tryInstallNodes(); }

// ---- CoreUI asset-catalog pipeline -------------------------------------------------
// Every named color Logic (AppKit *and* SwiftUI) loads from an asset catalog is resolved
// through -[CUINamedColor cgColor]. Hooking it covers names no theme key
// mentions: an explicit theme entry wins; otherwise the "auto" block of theme.json
// recolors the stock color — neutrals are re-mapped along the theme's lightness ramp,
// and Logic's blue accent hue is re-mapped to the theme accent. Saturated functional
// colors (record red, solo yellow, meters, user track colors) are left alone.
typedef struct { CGFloat l, r, g, b; } FCStop;
static FCStop gRamp[16];
static int gRampN = 0;
static BOOL gAutoOn = NO;
static BOOL gRampInverted = NO;   // light theme: Logic's light-on-dark neutrals become dark-on-light
static CGFloat gAutoNeutralSat = 0.22;
static CGFloat gAccentHues[4][2] = {{211, 32}};   // {hue, tolerance} pairs remapped to the theme accent
static int gAccentHueN = 1;
static CGFloat gAutoAccH = -1, gAutoAccS = 0, gAutoAccV = 0;
static NSMutableSet<NSString*> *gSeenCatalog = nil;
static NSMutableDictionary<NSString*, NSArray*> *gCatalogCache = nil;   // name -> [orig CGColor ptr, themed CGColor or NSNull]
static IMP gO_cuiCG = NULL;

// Exact 8-bit sRGB values the theme itself sets (colors, mixer, region palette). The CG
// fill accent remap skips them, so a theme's own blues — e.g. a blue selection in a
// yellow-accent theme — are never re-tinted a second time. Open addressing, 0 = empty.
#define FC_THEMED_SLOTS 2048
static uint32_t gThemedRGB[FC_THEMED_SLOTS];
static inline uint32_t fc_rgbKey(CGFloat r, CGFloat g, CGFloat b) {
  uint32_t ri = (uint32_t)lround(MAX(0.0, MIN(1.0, r)) * 255.0);
  uint32_t gi = (uint32_t)lround(MAX(0.0, MIN(1.0, g)) * 255.0);
  uint32_t bi = (uint32_t)lround(MAX(0.0, MIN(1.0, b)) * 255.0);
  return 0x1000000u | (ri << 16) | (gi << 8) | bi;
}
static void fc_themedAddRGB(CGFloat r, CGFloat g, CGFloat b) {
  uint32_t key = fc_rgbKey(r, g, b);
  for (uint32_t i = 0, slot = (key * 2654435761u) % FC_THEMED_SLOTS; i < FC_THEMED_SLOTS; i++, slot = (slot + 1) % FC_THEMED_SLOTS) {
    if (gThemedRGB[slot] == key) return;
    if (gThemedRGB[slot] == 0) { gThemedRGB[slot] = key; return; }
  }
}
static void fc_themedAdd(NSColor *c) {
  NSColor *s = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
  if (!s) return;
  uint32_t key = fc_rgbKey(s.redComponent, s.greenComponent, s.blueComponent);
  for (uint32_t i = 0, slot = (key * 2654435761u) % FC_THEMED_SLOTS; i < FC_THEMED_SLOTS; i++, slot = (slot + 1) % FC_THEMED_SLOTS) {
    if (gThemedRGB[slot] == key) return;
    if (gThemedRGB[slot] == 0) { gThemedRGB[slot] = key; return; }
  }
}
static BOOL fc_isThemedRGB(CGFloat r, CGFloat g, CGFloat b) {
  uint32_t key = fc_rgbKey(r, g, b);
  for (uint32_t i = 0, slot = (key * 2654435761u) % FC_THEMED_SLOTS; i < FC_THEMED_SLOTS; i++, slot = (slot + 1) % FC_THEMED_SLOTS) {
    if (gThemedRGB[slot] == key) return YES;
    if (gThemedRGB[slot] == 0) return NO;
  }
  return NO;
}

static void fc_loadAuto(NSDictionary *j) {
  gAutoOn = NO; gRampN = 0; gAutoAccH = -1; gRampInverted = NO;
  memset(gThemedRGB, 0, sizeof gThemedRGB);
  for (NSColor *c in gTheme.allValues) fc_themedAdd(c);
  for (NSColor *c in gMixer.allValues) fc_themedAdd(c);
  for (NSColor *c in gRegionPalette) fc_themedAdd(c);
  NSDictionary *a = [j[@"auto"] isKindOfClass:[NSDictionary class]] ? j[@"auto"] : nil;
  if (!a || ![a[@"enabled"] boolValue]) return;
  NSArray *ramp = [a[@"ramp"] isKindOfClass:[NSArray class]] ? a[@"ramp"] : nil;
  for (id stop in ramp) {
    if (gRampN >= 16 || ![stop isKindOfClass:[NSArray class]] || [stop count] != 2) continue;
    NSColor *c = fc_hexColor(stop[1]);
    if (!c) continue;
    CGFloat r, g, b, al;
    [c getRed:&r green:&g blue:&b alpha:&al];
    gRamp[gRampN++] = (FCStop){ [stop[0] doubleValue], r, g, b };
  }
  if (gRampN < 2) return;
  {
    // A "light" theme inverts Logic's dark UI: the ramp maps stock light greys to dark.
    FCStop lo = gRamp[gRampN > 2 ? 1 : 0], hi = gRamp[gRampN - 2];
    CGFloat llo = 0.2126 * lo.r + 0.7152 * lo.g + 0.0722 * lo.b, lhi = 0.2126 * hi.r + 0.7152 * hi.g + 0.0722 * hi.b;
    gRampInverted = lhi < llo;
  }
  if ([a[@"neutralSaturation"] respondsToSelector:@selector(doubleValue)]) gAutoNeutralSat = [a[@"neutralSaturation"] doubleValue];
  NSArray *hues = [a[@"accentHues"] isKindOfClass:[NSArray class]] ? a[@"accentHues"] : nil;
  if (hues.count) {
    gAccentHueN = 0;
    for (id pair in hues) {
      if (gAccentHueN >= 4 || ![pair isKindOfClass:[NSArray class]] || [pair count] != 2) continue;
      gAccentHues[gAccentHueN][0] = [pair[0] doubleValue];
      gAccentHues[gAccentHueN][1] = [pair[1] doubleValue];
      gAccentHueN++;
    }
  }
  NSColor *acc = fc_hexColor(a[@"accent"]);
  if (acc) { CGFloat h, s, b, al; [acc getHue:&h saturation:&s brightness:&b alpha:&al]; gAutoAccH = h * 360.0; gAutoAccS = s; gAutoAccV = b; }
  gAutoOn = YES;
}

static NSColor *fc_autoRemap(CGColorRef orig) {
  if (!gAutoOn || !orig) return nil;
  NSColor *src = [NSColor colorWithCGColor:orig];
  src = [src colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
  if (!src) return nil;
  CGFloat r, g, b, a;
  [src getRed:&r green:&g blue:&b alpha:&a];
  CGFloat mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
  CGFloat sat = mx > 0 ? (mx - mn) / mx : 0;
  if (mx < 0.05 || sat < gAutoNeutralSat || (mx - mn) < 0.07) {
    CGFloat l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    int i = 0;
    while (i < gRampN - 2 && l > gRamp[i + 1].l) i++;
    FCStop lo = gRamp[i], hi = gRamp[i + 1];
    CGFloat span = hi.l - lo.l;
    CGFloat t = span > 1e-6 ? MAX(0, MIN(1, (l - lo.l) / span)) : 0;
    gFCInternal++;
    NSColor *mapped = [NSColor colorWithSRGBRed:lo.r + (hi.r - lo.r) * t
                               green:lo.g + (hi.g - lo.g) * t
                                blue:lo.b + (hi.b - lo.b) * t
                               alpha:a];
    gFCInternal--;
    return mapped;
  }
  if (gAutoAccH >= 0 && sat >= 0.35) {
    CGFloat h, s, v, al;
    [src getHue:&h saturation:&s brightness:&v alpha:&al];
    BOOL family = NO;
    for (int k = 0; k < gAccentHueN && !family; k++) {
      CGFloat dh = fabs(h * 360.0 - gAccentHues[k][0]);
      if (dh > 180) dh = 360 - dh;
      family = dh <= gAccentHues[k][1];
    }
    if (family) {
      CGFloat ns = MIN(1.0, s * gAutoAccS / 0.9), nv = MIN(1.0, v * gAutoAccV / 1.0);
      gFCInternal++;
      NSColor *acc = [NSColor colorWithHue:gAutoAccH / 360.0 saturation:ns brightness:nv alpha:a];
      gFCInternal--;
      return acc;
    }
  }
  return nil;
}

// Pure-C accent-family test for the CoreGraphics fill interposes (hot path: no ObjC objects).
// Saturated colors whose hue sits in one of the theme's accent families become the theme accent.
static BOOL fc_autoAccentRGB(CGFloat r, CGFloat g, CGFloat b, CGFloat *or_, CGFloat *og, CGFloat *ob) {
  if (!gAutoOn || gAutoAccH < 0) return NO;
  CGFloat mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
  if (mx <= 0 || (mx - mn) / mx < 0.35) return NO;
  if (fc_isThemedRGB(r, g, b)) return NO;
  CGFloat d = mx - mn, h;
  if (mx == r) h = fmod((g - b) / d + 6.0, 6.0); else if (mx == g) h = (b - r) / d + 2.0; else h = (r - g) / d + 4.0;
  h *= 60.0;
  BOOL family = NO;
  for (int k = 0; k < gAccentHueN && !family; k++) {
    CGFloat dh = fabs(h - gAccentHues[k][0]); if (dh > 180) dh = 360 - dh;
    family = dh <= gAccentHues[k][1];
  }
  if (!family) return NO;
  CGFloat s = MIN(1.0, ((mx - mn) / mx) * gAutoAccS / 0.9), v = MIN(1.0, mx * gAutoAccV);
  CGFloat hh = gAutoAccH / 60.0, c = v * s, x = c * (1 - fabs(fmod(hh, 2.0) - 1)), m = v - c, rr, gg, bb;
  if (hh < 1) { rr = c; gg = x; bb = 0; } else if (hh < 2) { rr = x; gg = c; bb = 0; } else if (hh < 3) { rr = 0; gg = c; bb = x; }
  else if (hh < 4) { rr = 0; gg = x; bb = c; } else if (hh < 5) { rr = x; gg = 0; bb = c; } else { rr = c; gg = 0; bb = x; }
  *or_ = rr + m; *og = gg + m; *ob = bb + m;
  return YES;
}
// Light themes only: Logic's own label classes (MATextField, CustomTextField,
// CLgTearOffEditorTextField, MAKitTextField…) hard-code sRGB white text instead of asking for a
// named color, so track, region and panel names would stay white on light grey. In a light
// theme, any light neutral text color a text field reports is moved along the inverted ramp
// (white → the theme's dark text, keeping alpha). Dark text is already right and is left alone.
static BOOL fc_lightNeutralRGB(CGFloat r, CGFloat g, CGFloat b, CGFloat *or_, CGFloat *og, CGFloat *ob) {
  if (!gAutoOn || !gRampInverted || gRampN < 2) return NO;
  CGFloat mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
  if (mx - mn > 0.04) return NO;
  CGFloat l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  if (l < 0.5) return NO;
  int i = 0;
  while (i < gRampN - 2 && l > gRamp[i + 1].l) i++;
  FCStop lo = gRamp[i], hi = gRamp[i + 1];
  CGFloat span = hi.l - lo.l, t = span > 1e-6 ? MAX(0, MIN(1, (l - lo.l) / span)) : 0;
  *or_ = lo.r + (hi.r - lo.r) * t; *og = lo.g + (hi.g - lo.g) * t; *ob = lo.b + (hi.b - lo.b) * t;
  return YES;
}
// Light themes: Logic forces the Dark Aqua appearance, so standard AppKit controls (pop-up
// buttons, toolbar labels, segmented controls) keep drawing light-on-dark chrome on top of the
// light surfaces. Run Logic's app and windows in Aqua instead; Dark requests are dropped.
static IMP gO_appSetAppearance = NULL, gO_winSetAppearance = NULL;
static BOOL fc_isDarkAppearance(id ap) {
  if (![ap isKindOfClass:[NSAppearance class]]) return NO;
  return [[(NSAppearance *)ap name] rangeOfString:@"Dark"].location != NSNotFound;
}
static void fc_appSetAppearance(id self, SEL c, id ap) {
  if (gRampInverted && (ap == nil || fc_isDarkAppearance(ap))) ap = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
  ((void(*)(id, SEL, id))gO_appSetAppearance)(self, c, ap);
}
static void fc_winSetAppearance(id self, SEL c, id ap) {
  if (gRampInverted && fc_isDarkAppearance(ap)) ap = nil;   // inherit the app's Aqua
  ((void(*)(id, SEL, id))gO_winSetAppearance)(self, c, ap);
}
static void fc_installLightAppearance(void) {
  if (!gRampInverted) return;
  if (fc_hookAllowed(@"instance", @"NSApplication", @"setAppearance:")) {
    IMP o = fc_swizzleInst(objc_getClass("NSApplication"), @selector(setAppearance:), (IMP)fc_appSetAppearance);
    if (o) gO_appSetAppearance = o;
  }
  if (fc_hookAllowed(@"instance", @"NSWindow", @"setAppearance:")) {
    IMP o = fc_swizzleInst(objc_getClass("NSWindow"), @selector(setAppearance:), (IMP)fc_winSetAppearance);
    if (o) gO_winSetAppearance = o;
  }
  if (!gO_appSetAppearance) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    @try {
      [NSApp setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameAqua]];
      for (NSWindow *w in [NSApp windows]) if (fc_isDarkAppearance(w.appearance)) w.appearance = nil;
    } @catch (__unused NSException *e) {}
  });
}
// Light themes: Logic builds many label colors in code (white / light grey via NSColor
// constructors) and draws them itself, outside every named-color path. In a light theme, light
// neutral colors built by Logic are moved along the inverted ramp as they are created.
static IMP gO_cSRGB = NULL, gO_cCalRGB = NULL, gO_cDevRGB = NULL, gO_cRGB = NULL;
static IMP gO_cWhite = NULL, gO_cCalWhite = NULL, gO_cDevWhite = NULL, gO_cG22White = NULL, gO_cWhiteColor = NULL;
static id fc_lightCtorMap(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
  if (gFCInternal) return nil;
  CGFloat nr, ng, nb;
  if (!fc_lightNeutralRGB(r, g, b, &nr, &ng, &nb)) return nil;
  gFCInternal++;
  NSColor *m = [NSColor colorWithSRGBRed:nr green:ng blue:nb alpha:a];
  gFCInternal--;
  return m;
}
#define FC_RGB_CTOR(fn, gOrig) \
  static id fn(id s, SEL c, CGFloat r, CGFloat g, CGFloat b, CGFloat a) { \
    id m = fc_lightCtorMap(r, g, b, a); \
    return m ?: ((id(*)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat))gOrig)(s, c, r, g, b, a); }
#define FC_WHITE_CTOR(fn, gOrig) \
  static id fn(id s, SEL c, CGFloat w, CGFloat a) { \
    id m = fc_lightCtorMap(w, w, w, a); \
    return m ?: ((id(*)(id, SEL, CGFloat, CGFloat))gOrig)(s, c, w, a); }
FC_RGB_CTOR(fc_cSRGB, gO_cSRGB)
FC_RGB_CTOR(fc_cCalRGB, gO_cCalRGB)
FC_RGB_CTOR(fc_cDevRGB, gO_cDevRGB)
FC_RGB_CTOR(fc_cRGB, gO_cRGB)
FC_WHITE_CTOR(fc_cWhite, gO_cWhite)
FC_WHITE_CTOR(fc_cCalWhite, gO_cCalWhite)
FC_WHITE_CTOR(fc_cDevWhite, gO_cDevWhite)
FC_WHITE_CTOR(fc_cG22White, gO_cG22White)
static id fc_cWhiteColor(id s, SEL c) {
  id m = fc_lightCtorMap(1, 1, 1, 1);
  return m ?: ((id(*)(id, SEL))gO_cWhiteColor)(s, c);
}
static void fc_installLightConstructors(void) {
  if (!gRampInverted) return;
  Class nc = objc_getClass("NSColor");
  #define LCTOR(name, fn, gOrig) do { if (fc_hookAllowed(@"class", @"NSColor", @name)) { IMP o = fc_swizzleClass(nc, NSSelectorFromString(@name), (IMP)fn); if (o) gOrig = o; } } while (0)
  LCTOR("colorWithSRGBRed:green:blue:alpha:", fc_cSRGB, gO_cSRGB);
  LCTOR("colorWithCalibratedRed:green:blue:alpha:", fc_cCalRGB, gO_cCalRGB);
  LCTOR("colorWithDeviceRed:green:blue:alpha:", fc_cDevRGB, gO_cDevRGB);
  LCTOR("colorWithRed:green:blue:alpha:", fc_cRGB, gO_cRGB);
  LCTOR("colorWithWhite:alpha:", fc_cWhite, gO_cWhite);
  LCTOR("colorWithCalibratedWhite:alpha:", fc_cCalWhite, gO_cCalWhite);
  LCTOR("colorWithDeviceWhite:alpha:", fc_cDevWhite, gO_cDevWhite);
  LCTOR("colorWithGenericGamma22White:alpha:", fc_cG22White, gO_cG22White);
  LCTOR("whiteColor", fc_cWhiteColor, gO_cWhiteColor);
  #undef LCTOR
}
static IMP gO_tfcTextColor = NULL;
static id fc_tfcTextColor(id self, SEL c) {
  id orig = ((id(*)(id, SEL))gO_tfcTextColor)(self, c);
  if (!gRampInverted || ![orig isKindOfClass:[NSColor class]]) return orig;
  @try {
    NSColor *s = [(NSColor *)orig colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!s) return orig;
    CGFloat nr, ng, nb;
    if (fc_lightNeutralRGB(s.redComponent, s.greenComponent, s.blueComponent, &nr, &ng, &nb)) {
      gFCInternal++;
      NSColor *m = [NSColor colorWithSRGBRed:nr green:ng blue:nb alpha:s.alphaComponent];
      gFCInternal--;
      return m;
    }
  } @catch (__unused NSException *e) {}
  return orig;
}
// Catalog colors that reference a macOS system color (labelColor, secondaryLabelColor,
// systemBlueColor…) carry a light-appearance fallback (black at 85% / 50%). Remapping that
// fallback along the ramp made those labels near-black on dark themes, so they resolve to the
// theme's matching text / accent color instead, exactly as the NSColor system-color hooks do.
static NSColor *fc_themeForSystemColor(NSString *sys) {
  if (![sys isKindOfClass:[NSString class]] || !sys.length) return nil;
  NSString *n = [sys hasSuffix:@"Color"] ? sys : [sys stringByAppendingString:@"Color"];
  static NSDictionary<NSString*, NSArray<NSString*>*> *map; static dispatch_once_t once;
  dispatch_once(&once, ^{ map = @{
    @"labelColor": @[@"TextColor"], @"textColor": @[@"TextColor"], @"controlTextColor": @[@"TextColor"],
    @"headerTextColor": @[@"TextColor"], @"selectedControlTextColor": @[@"TextColor"],
    @"selectedTextColor": @[@"TextColor"], @"selectedMenuItemTextColor": @[@"TextColor"],
    @"secondaryLabelColor": @[@"TextSecondaryColor", @"TextColor"],
    @"placeholderTextColor": @[@"TextSecondaryColor", @"TextColor"],
    @"tertiaryLabelColor": @[@"TextTertiaryColor", @"TextSecondaryColor", @"TextColor"],
    @"quaternaryLabelColor": @[@"TextMutedColor", @"TextTertiaryColor", @"TextColor"],
    @"disabledControlTextColor": @[@"TextMutedColor", @"TextTertiaryColor", @"TextColor"],
    @"controlAccentColor": @[@"AccentColor"], @"systemBlueColor": @[@"AccentColor"],
    @"keyboardFocusIndicatorColor": @[@"FocusRingColor", @"AccentColor"],
    @"separatorColor": @[@"DividerPrimaryColor"],
    @"windowBackgroundColor": @[@"MainWindowColor"],
    @"controlBackgroundColor": @[@"TableviewColor", @"PanelBackgroundColor"],
    @"textBackgroundColor": @[@"TableviewColor", @"PanelBackgroundColor"],
    @"controlColor": @[@"ControlColor", @"ToolbarButtonFill"], @"systemGrayColor": @[@"ControlColor", @"ToolbarButtonFill"],
  }; });
  for (NSString *key in map[n]) { NSColor *c = gTheme[key]; if (c) return c; }
  return nil;
}
static CGColorRef fc_catalogFinishWith(NSString *name, CGColorRef orig, NSColor *forced, BOOL allowAuto);
static CGColorRef fc_catalogFinish(NSString *name, CGColorRef orig) { return fc_catalogFinishWith(name, orig, nil, YES); }
static CGColorRef fc_catalogFinishWith(NSString *name, CGColorRef orig, NSColor *forced, BOOL allowAuto) {
  if (!orig || ![name isKindOfClass:[NSString class]]) return orig;
  @try {
    @synchronized (gCatalogCache) {
      NSArray *hit = gCatalogCache[name];
      if (hit && [hit[0] pointerValue] == orig) return [hit[1] isKindOfClass:[NSNull class]] ? orig : (__bridge CGColorRef)hit[1];
    }
    if (fc_debugEnabled() && gSeenCatalog) {
      CGFloat r = 0, g = 0, b = 0, a = 0;
      NSColor *o = [[NSColor colorWithCGColor:orig] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
      if (o) [o getRed:&r green:&g blue:&b alpha:&a];
      NSString *line = [NSString stringWithFormat:@"%@\t%02x%02x%02x\t%d", name, (int)lround(r*255), (int)lround(g*255), (int)lround(b*255), (int)lround(a*100)];
      fc_logSeen(gSeenCatalog, @"seen-catalog.txt", line);
    }
    NSColor *themed = gTheme[name];
    if (!themed && ([name hasPrefix:@"Colors/"] || [name hasPrefix:@"Colors."])) themed = gTheme[[name substringFromIndex:7]];
    if (!themed) themed = forced;
    if (!themed && allowAuto) themed = fc_autoRemap(orig);
    CGColorRef result = orig;
    id keep = nil;
    if (themed) {
      NSColor *t = [themed colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
      CGFloat r, g, b, a;
      [t getRed:&r green:&g blue:&b alpha:&a];
      keep = (__bridge_transfer id)CGColorCreateSRGB(r, g, b, a);
      result = (__bridge CGColorRef)keep;
      fc_themedAddRGB(r, g, b);
    }
    @synchronized (gCatalogCache) {
      gCatalogCache[name] = @[[NSValue valueWithPointer:orig], keep ?: [NSNull null]];
    }
    return result;
  } @catch (__unused NSException *e) {}
  return orig;
}
// CUINamedColor is what every catalog color lookup (AppKit and SwiftUI) hands back;
// -cgColor is where its value is read, so one hook covers all callers.
static CGColorRef fc_namedColorCG(id self, SEL c) {
  CGColorRef o = ((CGColorRef(*)(id,SEL))gO_cuiCG)(self, c);
  NSString *name = nil, *sys = nil;
  @try {
    name = [self name];
    SEL ss = NSSelectorFromString(@"systemColorName");
    if ([self respondsToSelector:ss]) sys = ((id(*)(id, SEL))objc_msgSend)(self, ss);
  } @catch (__unused NSException *e) {}
  if ([sys isKindOfClass:[NSString class]] && sys.length)
    return fc_catalogFinishWith(name, o, fc_themeForSystemColor(sys), NO);
  return fc_catalogFinish(name, o);
}
static void fc_installCatalogHooks(void) {
  Class nc = objc_getClass("CUINamedColor");
  if (!nc || !fc_hookAllowed(@"instance", @"CUINamedColor", @"cgColor")) return;
  gSeenCatalog = [NSMutableSet set];
  gCatalogCache = [NSMutableDictionary dictionary];
  IMP o = fc_swizzleInst(nc, NSSelectorFromString(@"cgColor"), (IMP)fc_namedColorCG);
  if (o) gO_cuiCG = o;
}

__attribute__((constructor))
static void fc_init(void) {
  gSeen=[NSMutableSet set]; gSeenMixer=[NSMutableSet set];
  fc_loadTheme();
  if (!fc_loadHookManifest() || !fc_hooksAllowed()) {
    fc_writeDisabledMarker();
    os_log(OS_LOG_DEFAULT, "[Theme4Logic] hooks disabled for Logic %{public}@: %{public}@", gLogicVersion ?: @"unknown", gHookDisabledReason ?: @"no manifest");
    return;
  }
  Class nc = objc_getClass("NSColor");
  NSMutableArray *got=[NSMutableArray array];
  #define HOOKCLS(name,fn,gOrig) do { \
    if (fc_hookAllowed(@"class", @"NSColor", @name)) { \
      IMP _o=fc_swizzleClass(nc, NSSelectorFromString(@name), (IMP)fn); \
      if(_o)gOrig=_o; \
    } \
  } while(0);
  #define HOOKCLS_REQUIRED(name,fn,gOrig) do { \
    HOOKCLS(name,fn,gOrig); \
    if(gOrig)[got addObject:@name]; \
  } while(0);
  HOOKCLS_REQUIRED("colorNamed:bundle:", fc_colorNamedBundle, gOrigNamedBundle)
  HOOKCLS_REQUIRED("colorNamed:", fc_colorNamed, gOrigNamed)
  HOOKCLS_REQUIRED("colorWithCatalogName:colorName:", fc_colorWithCatalog, gOrigCatalog)
  HOOKCLS("alternatingContentBackgroundColors", fc_altColors, gO_altColors)
  HOOKCLS("controlAlternatingRowBackgroundColors", fc_altRows, gO_altRows)
  HOOKCLS("controlColor", fc_ctlColor, gO_ctlColor)
  HOOKCLS("controlBackgroundColor", fc_ctlBg, gO_ctlBg)
  HOOKCLS("windowBackgroundColor", fc_winBg, gO_winBg)
  HOOKCLS("underPageBackgroundColor", fc_pageBg, gO_pageBg)
  HOOKCLS("labelColor",              fc_t_label,  gO_t_label)
  HOOKCLS("textColor",               fc_t_text,   gO_t_text)
  HOOKCLS("windowFrameTextColor",    fc_t_winfrm, gO_t_winfrm)
  HOOKCLS("controlTextColor",        fc_t_ctl,    gO_t_ctl)
  HOOKCLS("headerTextColor",         fc_t_hdr,    gO_t_hdr)
  HOOKCLS("selectedControlTextColor",fc_t_selctl, gO_t_selctl)
  HOOKCLS("selectedTextColor",       fc_t_seltxt, gO_t_seltxt)
  HOOKCLS("selectedMenuItemTextColor",fc_t_selmenu,gO_t_selmenu)
  HOOKCLS("secondaryLabelColor",     fc_t_sec,    gO_t_sec)
  HOOKCLS("tertiaryLabelColor",      fc_t_ter,    gO_t_ter)
  HOOKCLS("quaternaryLabelColor",    fc_t_quad,   gO_t_quad)
  HOOKCLS("disabledControlTextColor",fc_t_dis,    gO_t_dis)
  HOOKCLS("placeholderTextColor",    fc_t_ph,     gO_t_ph)
  HOOKCLS("controlAccentColor",          fc_a_accent, gO_a_accent)
  HOOKCLS("controlAccentColorForAppearance:", fc_a_accentApp, gO_a_accentApp)
  HOOKCLS("keyboardFocusIndicatorColor", fc_a_focus,  gO_a_focus)
  HOOKCLS("systemBlueColor",             fc_a_sysblue,gO_a_sysblue)
  HOOKCLS("selectedContentBackgroundColor",fc_a_selbg,gO_a_selbg)
  HOOKCLS("selectedControlColor",        fc_a_selctl, gO_a_selctl)
  HOOKCLS("selectedTextBackgroundColor", fc_a_seltbg, gO_a_seltbg)
  HOOKCLS("systemGrayColor",             fc_sysGray,  gO_sysGray)
  HOOKCLS("textBackgroundColor",          fc_txtBg,    gO_txtBg)
  HOOKCLS("separatorColor",              fc_sep,      gO_sep)
  #undef HOOKCLS_REQUIRED
  #undef HOOKCLS
  // Make the behind-window vibrancy (control bar / title bar) opaque navy.
  { Class vev=objc_getClass("NSVisualEffectView"); if(vev && fc_hookAllowed(@"instance", @"NSVisualEffectView", @"updateLayer")){ IMP o=fc_swizzleInst(vev,NSSelectorFromString(@"updateLayer"),(IMP)fc_vevUpdate); if(o)gO_vevUpdate=o; } }
  { Class rv=objc_getClass("NSTableRowView"); if(rv && fc_hookAllowed(@"instance", @"NSTableRowView", @"setBackgroundColor:")){IMP o=fc_swizzleInst(rv,NSSelectorFromString(@"setBackgroundColor:"),(IMP)fc_rowBg); if(o)gO_rowBg=o;} }
  // Base private NSTableView alternating-row colors — catches every table/outline view
  // (file browser, media lists) whose class doesn't override it like MAKitTableView does.
  { Class tv=objc_getClass("NSTableView"); if(tv && fc_hookAllowed(@"instance", @"NSTableView", @"_alternatingRowBackgroundColors")){fc_swizzleInst(tv,NSSelectorFromString(@"_alternatingRowBackgroundColors"),(IMP)fc_maAltRows);} }
  // Control-bar / toolbar glyph recolor at the cell draw layer (catches every NSButtonCell subclass).
  { Class bc=objc_getClass("NSButtonCell"); if(bc && fc_hookAllowed(@"instance", @"NSButtonCell", @"drawImage:withFrame:inView:")){IMP o=fc_swizzleInst(bc,NSSelectorFromString(@"drawImage:withFrame:inView:"),(IMP)fc_cellDrawImg); if(o)gO_cellDrawImg=o;} }
  // Selected-segment / tab / active-tool blue is handled globally by the CG-fill interpose
  // (fc_cgSetFill / fc_cgSetRGBFill substitute the exact foreign accent-blue) — no per-cell hook needed.
  { Class bc=objc_getClass("NSButtonCell"); if(bc && fc_hookAllowed(@"instance", @"NSButtonCell", @"drawBezelWithFrame:inView:")){IMP o=fc_swizzleInst(bc,NSSelectorFromString(@"drawBezelWithFrame:inView:"),(IMP)fc_cellBezel); if(o)gO_cellBezel=o;} }
  { Class bc=objc_getClass("NSButtonCell"); if(bc && fc_hookAllowed(@"instance", @"NSButtonCell", @"drawTitle:withFrame:inView:")){IMP o=fc_swizzleInst(bc,NSSelectorFromString(@"drawTitle:withFrame:inView:"),(IMP)fc_cellDrawTitle); if(o)gO_cellDrawTitle=o;} }
  { Class s=objc_getClass("NSAttributedString"); if(s){
      if(fc_hookAllowed(@"instance", @"NSAttributedString", @"drawInRect:")){ IMP o1=fc_swizzleInst(s,NSSelectorFromString(@"drawInRect:"),(IMP)fc_asRect); if(o1)gO_asRect=o1; }
      if(fc_hookAllowed(@"instance", @"NSAttributedString", @"drawAtPoint:")){ IMP o2=fc_swizzleInst(s,NSSelectorFromString(@"drawAtPoint:"),(IMP)fc_asPt); if(o2)gO_asPt=o2; }
      if(fc_hookAllowed(@"instance", @"NSAttributedString", @"drawWithRect:options:context:")){ IMP o3=fc_swizzleInst(s,NSSelectorFromString(@"drawWithRect:options:context:"),(IMP)fc_asRectOpt); if(o3)gO_asRectOpt=o3; }
  } }
  // Arrange + track-editor toolbar rows (Functions / View / Snap, Edit / Functions / View).
  { Class hdr=objc_getClass("CLgDocwControlHeaderView");
    if(!hdr) hdr=objc_getClass("CLgControlHeaderView");
    if(hdr && fc_hookAllowed(@"instance", NSStringFromClass(hdr), @"drawRect:")){ IMP o=fc_swizzleInst(hdr,NSSelectorFromString(@"drawRect:"),(IMP)fc_ctrlHdrDraw); if(o)gO_ctrlHdrDraw=o; } }
  { Class tab=objc_getClass("CLgEditorTabButtonsView");
    if(tab && fc_hookAllowed(@"instance", @"CLgEditorTabButtonsView", @"drawRect:")){ IMP o=fc_swizzleInst(tab,NSSelectorFromString(@"drawRect:"),(IMP)fc_editorTabDraw); if(o)gO_editorTabDraw=o; } }
  fc_installEditorCanvasHooks();
  fc_installCatalogHooks();
  fc_installLightAppearance();
  fc_installLightConstructors();
  if (fc_hookAllowed(@"instance", @"NSTextFieldCell", @"textColor")) {
    IMP o = fc_swizzleInst(objc_getClass("NSTextFieldCell"), @selector(textColor), (IMP)fc_tfcTextColor);
    if (o) gO_tfcTextColor = o;
  }
  // Debug builds of a session (THEME4LOGIC_DEBUG=1): record every text-bearing view and its
  // color once the main window is up, so un-themed labels can be traced to their source.
  if (fc_debugEnabled()) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ fc_dumpTextLabelsAll(); });
  fc_writeMarker(got.count?[got componentsJoinedByString:@", "]:@"NONE", @"pending (waiting for MACore)");
  // MACore may already be loaded, or load later — cover both.
  fc_tryInstallMixer();
  fc_tryInstallNodes();
  fc_installDiag();
  _dyld_register_func_for_add_image(fc_imageAdded);
  // Title-bar tint: tint main windows as they appear + an initial sweep.
  [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeMainNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*n){ fc_tintWindow((NSWindow*)n.object); }];
  // Sheets/dialogs become KEY (not main) — tint those too (Create New Track, prefs, etc.).
  [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*n){ fc_tintWindow((NSWindow*)n.object); }];
  [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResizeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*n){ fc_tintWindow((NSWindow*)n.object); }];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ for(NSWindow*w in [NSApp windows]) fc_tintWindow(w); });
  // Cover behind-window vibrancy when the toolbar toggles — a few retries, not a minute of polling.
  for(int t=2;t<=12;t+=2) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(t*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ fc_coverAllVEVs(); });
  for(int t=3;t<=12;t+=3) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(t*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ fc_tintToolbars(); });
  [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResizeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*n){ fc_coverAllVEVs(); fc_tintToolbars(); }];
  os_log(OS_LOG_DEFAULT, "[Theme4Logic] active pid %d appkit=%{public}@", getpid(), [got componentsJoinedByString:@","]);
}
