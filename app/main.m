// Theme4Logic — free macOS app for Logic Pro color themes.
// Injects colorize.dylib at launch; presets live in Resources/themes/.

#import <Cocoa/Cocoa.h>

@class T4LColorRow;

static NSString *const kLastPresetSlugKey = @"lastPresetSlug";
static NSString *const kCustomizationsKey = @"presetCustomizations";  // { slug: { overrides: {role: hex}, auto: BOOL } }
static NSString *const kImportedThemeKey = @"importedTheme";
static NSString *const kProjectPathKey = @"logicProjectPath";
static NSString *const kLastTabKey = @"lastTabIndex";
static NSString *const kImportedSlug = @"custom";
static NSString *const kRepoURLString = @"https://github.com/iacompa/Theme4Logic";
static NSString *const kLogicBundleID = @"com.apple.logic10";
static NSString *const kAccentRoleID = @"ArrangeWorkspaceBrightColor";
static NSString *const kMixerPrefix = @"mixer:";
static NSString *const kRegionPrefix = @"region:";
static const NSInteger kMaxRegionRoles = 12;

#pragma mark - Built-in preset list (used only if the bundled manifest is missing)

static NSArray<NSDictionary *> *FallbackBundledPresets(void) {
  return @[
    @{@"title": @"Midnight", @"slug": @"midnight", @"tagline": @"Deep navy - the original Theme4Logic look",
      @"accent": @"#9097cc", @"category": @"Featured"},
    @{@"title": @"Ableton Classic", @"slug": @"ableton-classic", @"tagline": @"Neutral charcoal with warm orange accents",
      @"accent": @"#FF8C00", @"category": @"DAW-inspired"},
    @{@"title": @"Ableton Dark", @"slug": @"ableton-dark", @"tagline": @"Live-style graphite with cyan transport",
      @"accent": @"#2fc6d4", @"category": @"DAW-inspired"},
    @{@"title": @"Angst Robot", @"slug": @"angst-robot", @"tagline": @"Purple cyberpunk with neon highlights",
      @"accent": @"#7b68ee", @"category": @"DAW-inspired"},
    @{@"title": @"FL Studio", @"slug": @"fl-studio-fruity", @"tagline": @"Warm brown-orange Fruity edition",
      @"accent": @"#e87820", @"category": @"DAW-inspired"},
    @{@"title": @"Pro Tools", @"slug": @"pro-tools", @"tagline": @"Avid charcoal with green LCD transport",
      @"accent": @"#0078D7", @"category": @"DAW-inspired"},
    @{@"title": @"Studio One", @"slug": @"studio-one", @"tagline": @"PreSonus cool grey & blue",
      @"accent": @"#2478ba", @"category": @"DAW-inspired"},
    @{@"title": @"Reaper", @"slug": @"reaper", @"tagline": @"Flat utilitarian grey with teal",
      @"accent": @"#339887", @"category": @"DAW-inspired"},
    @{@"title": @"Voice Memos", @"slug": @"voice-memos", @"tagline": @"OLED black with iOS red accents",
      @"accent": @"#ff3b30", @"category": @"DAW-inspired"},
    @{@"title": @"Dawnamite Dark", @"slug": @"dawnamite-dark", @"tagline": @"Cool graphite with a sky-blue playhead",
      @"accent": @"#63b3ff", @"category": @"Dawnamite"},
    @{@"title": @"Dawnamite Light", @"slug": @"dawnamite-light", @"tagline": @"Soft grey daylight theme (experimental)",
      @"accent": @"#005aa8", @"category": @"Dawnamite"},
    @{@"title": @"Dawnamite High Contrast", @"slug": @"dawnamite-high-contrast", @"tagline": @"Pure black, white text, yellow focus",
      @"accent": @"#ffff00", @"category": @"Dawnamite"},
    @{@"title": @"Dawnamite Safe", @"slug": @"dawnamite-safe", @"tagline": @"Near-black accessible theme, yellow focus",
      @"accent": @"#ffff00", @"category": @"Dawnamite"},
  ];
}

static NSArray<NSDictionary *> *BundledPresets(void) {
  static NSArray<NSDictionary *> *cached = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *path = [[NSBundle mainBundle] pathForResource:@"preset-manifest" ofType:@"json"];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (data) {
      id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if ([parsed isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
        for (id item in (NSArray *)parsed) {
          if (![item isKindOfClass:[NSDictionary class]])
            continue;
          NSDictionary *dict = (NSDictionary *)item;
          NSArray<NSString *> *required = @[ @"title", @"slug", @"tagline", @"accent", @"category" ];
          BOOL ok = YES;
          for (NSString *key in required) {
            if (![dict[key] isKindOfClass:[NSString class]]) {
              ok = NO;
              break;
            }
          }
          if (ok)
            [items addObject:dict];
        }
        if (items.count > 0)
          cached = [items copy];
      }
    }
    if (!cached)
      cached = FallbackBundledPresets();
  });
  return cached;
}

static NSDictionary *PresetMeta(NSString *slug) {
  for (NSDictionary *p in BundledPresets())
    if ([p[@"slug"] isEqualToString:slug]) return p;
  return nil;
}

#pragma mark - Paths and Logic discovery

static NSString *SupportDir(void) {
  NSString *d = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Theme4Logic"];
  [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
  return d;
}

static NSString *ThemesBundleDir(void) {
  return [[NSBundle mainBundle] pathForResource:@"themes" ofType:nil];
}

static NSURL *LogicAppURL(void) {
  NSArray<NSString *> *names = @[ @"Logic Pro.app", @"Logic Pro X.app" ];
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *name in names) {
    NSString *path = [@"/Applications" stringByAppendingPathComponent:name];
    if ([fm fileExistsAtPath:path])
      return [NSURL fileURLWithPath:path];
  }
  return nil;
}

static BOOL LogicIsRunning(void) {
  return [NSRunningApplication runningApplicationsWithBundleIdentifier:kLogicBundleID].count > 0;
}

static NSArray<NSRunningApplication *> *RunningLogicApps(void) {
  return [NSRunningApplication runningApplicationsWithBundleIdentifier:kLogicBundleID];
}

static NSString *ActivationStatusPath(void) {
  return [SupportDir() stringByAppendingPathComponent:@"colorize-status.json"];
}

static NSString *LegacyActivationMarkerPath(void) {
  return [SupportDir() stringByAppendingPathComponent:@"colorize-active.txt"];
}

static NSString *HookManifestDir(void) {
  return [SupportDir() stringByAppendingPathComponent:@"hook-manifests"];
}

static BOOL ReplacePreparedItem(NSString *prepared, NSString *dest, NSError **outError) {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *parent = [dest stringByDeletingLastPathComponent];
  [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
  if (![fm fileExistsAtPath:dest])
    return [fm moveItemAtPath:prepared toPath:dest error:outError];

  NSURL *preparedURL = [NSURL fileURLWithPath:prepared];
  NSURL *destURL = [NSURL fileURLWithPath:dest];
  NSURL *resultURL = nil;
  return [fm replaceItemAtURL:destURL
                withItemAtURL:preparedURL
               backupItemName:nil
                      options:NSFileManagerItemReplacementUsingNewMetadataOnly
             resultingItemURL:&resultURL
                        error:outError];
}

// Detects the installed Logic Pro and whether this build of Theme4Logic carries a verified hook manifest for
// exactly that version and build (the engine refuses to hook anything else, so Apply is disabled in that case).
// Keys: found, supported (BOOL), level (0 ok, 1 notice, 2 problem), message, version, build.
static NSDictionary *DetectLogicSupport(void) {
  NSURL *url = LogicAppURL();
  if (!url) {
    return @{@"found": @NO, @"supported": @NO, @"level": @2,
             @"message": @"Logic Pro was not found in /Applications. Install it there, then reopen Theme4Logic."};
  }
  NSDictionary *info = [NSBundle bundleWithURL:url].infoDictionary;
  NSString *version = [info[@"CFBundleShortVersionString"] isKindOfClass:[NSString class]] ? info[@"CFBundleShortVersionString"] : nil;
  NSString *build = [info[@"CFBundleVersion"] isKindOfClass:[NSString class]] ? info[@"CFBundleVersion"] : nil;
  NSString *bundleID = [info[@"CFBundleIdentifier"] isKindOfClass:[NSString class]] ? info[@"CFBundleIdentifier"] : nil;
  if (version.length == 0 || build.length == 0 || ![bundleID isEqualToString:kLogicBundleID]) {
    return @{@"found": @YES, @"supported": @NO, @"level": @2,
             @"message": @"Couldn’t read the version of the Logic Pro in /Applications, so the theme will not apply."};
  }

  NSString *dir = [[NSBundle mainBundle] pathForResource:@"hook-manifests" ofType:nil];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableArray<NSString *> *versions = [NSMutableArray array];
  NSDictionary *mine = nil;
  for (NSString *name in (dir ? [fm contentsOfDirectoryAtPath:dir error:nil] : @[])) {
    if (![name hasPrefix:@"logic-"] || ![name hasSuffix:@"-hooks.json"] || name.length <= 17) continue;
    NSString *v = [name substringWithRange:NSMakeRange(6, name.length - 6 - 11)];
    NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![parsed isKindOfClass:[NSDictionary class]] || ![parsed[@"logicVersion"] isEqual:v]) continue;
    [versions addObject:v];
    if ([v isEqualToString:version]) mine = parsed;
  }
  [versions sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
    return [a compare:b options:NSNumericSearch];
  }];

  if (mine) {
    NSString *mineBuild = mine[@"logicBuild"];
    BOOL allow = [mine[@"allowHooks"] isKindOfClass:[NSNumber class]] && [mine[@"allowHooks"] boolValue];
    BOOL bundleOK = [mine[@"logicBundleIdentifier"] isEqual:kLogicBundleID];
    if (allow && bundleOK && [mineBuild isEqual:build]) {
      return @{@"found": @YES, @"supported": @YES, @"level": @0, @"version": version, @"build": build,
               @"message": [NSString stringWithFormat:@"Logic Pro %@ (build %@) — supported by this build of Theme4Logic.", version, build]};
    }
    if (allow && bundleOK && [mineBuild isKindOfClass:[NSString class]]) {
      return @{@"found": @YES, @"supported": @NO, @"level": @2, @"version": version, @"build": build,
               @"message": [NSString stringWithFormat:@"Logic Pro %@ build %@ differs from the verified build %@ — the theme will not apply. Update Theme4Logic.", version, build, mineBuild]};
    }
  }
  NSString *message;
  if (versions.count > 0 && [version compare:versions.lastObject options:NSNumericSearch] == NSOrderedDescending) {
    message = [NSString stringWithFormat:@"Logic Pro %@ is newer than this build supports — the theme will not apply; update Theme4Logic.", version];
  } else if (versions.count > 0 && [version compare:versions.firstObject options:NSNumericSearch] == NSOrderedAscending) {
    message = [NSString stringWithFormat:@"Logic Pro %@ is older than this build supports (%@) — the theme will not apply.",
               version, [versions componentsJoinedByString:@", "]];
  } else {
    message = [NSString stringWithFormat:@"Logic Pro %@ is not in this build’s verified list — the theme will not apply; update Theme4Logic.", version];
  }
  return @{@"found": @YES, @"supported": @NO, @"level": @2, @"version": version, @"build": build, @"message": message};
}

static NSURL *ValidProjectURL(NSString *path) {
  if (![path isKindOfClass:[NSString class]] || path.length == 0) return nil;
  BOOL isDir = NO;
  if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]) return nil;
  if (![path.pathExtension.lowercaseString isEqualToString:@"logicx"]) return nil;
  return [NSURL fileURLWithPath:path];
}

#pragma mark - Color helpers

static NSString *HexDigits(NSString *s, BOOL allowAlpha) {
  if (![s isKindOfClass:[NSString class]]) return nil;
  NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([t hasPrefix:@"#"]) t = [t substringFromIndex:1];
  NSUInteger n = t.length;
  if (n == 3) {
    unichar c[6];
    for (NSUInteger i = 0; i < 3; i++) {
      unichar ch = [t characterAtIndex:i];
      c[2 * i] = ch;
      c[2 * i + 1] = ch;
    }
    t = [NSString stringWithCharacters:c length:6];
    n = 6;
  }
  if (!(n == 6 || (allowAlpha && n == 8))) return nil;
  static NSCharacterSet *nonHex;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
  });
  if ([t rangeOfCharacterFromSet:nonHex].location != NSNotFound) return nil;
  return t.lowercaseString;
}

// "#rrggbb" from user input (accepts rgb, #rgb, rrggbb, #rrggbb), or nil.
static NSString *NormalizeHex(NSString *s) {
  NSString *d = HexDigits(s, NO);
  return d ? [@"#" stringByAppendingString:d] : nil;
}

// "#rrggbb" from a theme value (drops any alpha), or nil.
static NSString *OpaqueHexFromTheme(id v) {
  NSString *d = HexDigits(v, YES);
  return d ? [@"#" stringByAppendingString:[d substringToIndex:6]] : nil;
}

// Theme value as stored on disk ("#rrggbb" or "#rrggbbaa"), or nil.
static NSString *ThemeHexKeepingAlpha(id v) {
  NSString *d = HexDigits(v, YES);
  return d ? [@"#" stringByAppendingString:d] : nil;
}

static NSColor *ColorFromHex(NSString *hex) {
  NSString *n = OpaqueHexFromTheme(hex);
  if (!n) return NSColor.grayColor;
  unsigned long v = strtoul([n substringFromIndex:1].UTF8String, NULL, 16);
  return [NSColor colorWithSRGBRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1.0];
}

static NSString *HexFromColor(NSColor *c) {
  NSColor *s = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
  if (!s) return @"#808080";
  return [NSString stringWithFormat:@"#%02x%02x%02x",
          (int)lround(s.redComponent * 255), (int)lround(s.greenComponent * 255), (int)lround(s.blueComponent * 255)];
}

static NSColor *MixColors(NSColor *a, NSColor *b, CGFloat t) {
  NSColor *x = [a colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: a;
  NSColor *y = [b colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: b;
  return [NSColor colorWithSRGBRed:x.redComponent + (y.redComponent - x.redComponent) * t
                             green:x.greenComponent + (y.greenComponent - x.greenComponent) * t
                              blue:x.blueComponent + (y.blueComponent - x.blueComponent) * t
                             alpha:1.0];
}

// WCAG 2.x relative luminance and contrast ratio. Anything drawn on top of a preset's own colors (which can be
// dark or light) takes its ink from these helpers instead of a fixed color.
static CGFloat RelativeLuminance(NSColor *c) {
  NSColor *x = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: c;
  CGFloat ch[3] = { x.redComponent, x.greenComponent, x.blueComponent };
  for (int i = 0; i < 3; i++) ch[i] = ch[i] <= 0.03928 ? ch[i] / 12.92 : pow((ch[i] + 0.055) / 1.055, 2.4);
  return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2];
}

static CGFloat ContrastRatio(NSColor *a, NSColor *b) {
  CGFloat la = RelativeLuminance(a), lb = RelativeLuminance(b);
  return (MAX(la, lb) + 0.05) / (MIN(la, lb) + 0.05);
}

// Near-white or near-black, whichever reads better on `bg`; falls back to pure white/black so the ratio never drops below 4.5:1.
static NSColor *ReadableInk(NSColor *bg) {
  NSColor *white = [NSColor colorWithSRGBRed:0.965 green:0.965 blue:0.975 alpha:1];
  NSColor *black = [NSColor colorWithSRGBRed:0.07 green:0.07 blue:0.08 alpha:1];
  NSColor *best = ContrastRatio(white, bg) >= ContrastRatio(black, bg) ? white : black;
  if (ContrastRatio(best, bg) >= 4.5) return best;
  NSColor *pureWhite = [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:1];
  NSColor *pureBlack = [NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:1];
  return ContrastRatio(pureWhite, bg) >= ContrastRatio(pureBlack, bg) ? pureWhite : pureBlack;
}

// `fg` if it already reads on `bg` (at least 4.5:1), otherwise the better of near-white / near-black.
static NSColor *LegibleOn(NSColor *fg, NSColor *bg) {
  return ContrastRatio(fg, bg) >= 4.5 ? fg : ReadableInk(bg);
}

static NSColor *InkOn(NSColor *bg, CGFloat alpha) {
  return [ReadableInk(bg) colorWithAlphaComponent:alpha];
}

// App-chrome text colors. All dynamic, so they follow Light and Dark. Plain secondaryLabelColor is too faint for small
// text on the light window, so supporting text is the primary label color at reduced opacity instead.
// (A real dynamic provider, not labelColor-with-alpha: that would freeze to whichever appearance was current when it was created.)
static BOOL AppearanceIsDark(NSAppearance *appearance) {
  NSAppearanceName n = [appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
  return [n isEqualToString:NSAppearanceNameDarkAqua];
}

static NSColor *SecondaryText(void) {
  return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
    return AppearanceIsDark(appearance) ? [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.74]
                                        : [NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:0.70];
  }];
}

static NSColor *ErrorText(void) {
  return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
    return AppearanceIsDark(appearance) ? [NSColor colorWithSRGBRed:1.0 green:0.42 blue:0.38 alpha:1]
                                        : [NSColor colorWithSRGBRed:0.72 green:0.09 blue:0.07 alpha:1];
  }];
}

static NSNumber *HueDegrees(NSString *hex) {
  CGFloat h = 0, s = 0, b = 0, a = 0;
  [ColorFromHex(hex) getHue:&h saturation:&s brightness:&b alpha:&a];
  int deg = (int)lround(h * 360.0);
  if (deg < 1) deg = 360;
  if (deg > 360) deg = 360;
  return @(deg);
}

#pragma mark - Text helpers

static CGFloat WrappedHeight(NSTextField *f, CGFloat width) {
  if (width < 20) width = 20;
  NSSize sz = [f.cell cellSizeForBounds:NSMakeRect(0, 0, width, 10000)];
  return ceil(sz.height);
}

static NSTextField *Label(NSString *text, NSFont *font, NSColor *color) {
  NSTextField *t = [NSTextField labelWithString:text ?: @""];
  t.font = font;
  t.textColor = color ?: NSColor.labelColor;
  t.lineBreakMode = NSLineBreakByTruncatingTail;
  return t;
}

static NSTextField *WrapLabel(NSString *text, NSFont *font, NSColor *color) {
  NSTextField *t = [NSTextField wrappingLabelWithString:text ?: @""];
  t.font = font;
  t.textColor = color ?: NSColor.labelColor;
  t.selectable = NO;
  return t;
}

static NSTextField *SectionHeaderLabel(NSString *text) {
  return Label(text.uppercaseString, [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold], SecondaryText());
}

static NSFont *MonoFont(CGFloat size) {
  return [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
}

#pragma mark - Plist / JSON helpers

static NSDictionary *DictOf(id v) { return [v isKindOfClass:[NSDictionary class]] ? v : @{}; }
static NSArray *ArrayOf(id v) { return [v isKindOfClass:[NSArray class]] ? v : @[]; }

// Deep copy keeping only JSON/plist-safe types (drops NSNull and anything else), so it can go to
// NSUserDefaults and back into theme.json.
static id PlistSafeCopy(id v, int depth) {
  if (depth > 8) return nil;
  if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) return v;
  if ([v isKindOfClass:[NSArray class]]) {
    NSMutableArray *out = [NSMutableArray array];
    for (id x in (NSArray *)v) {
      id c = PlistSafeCopy(x, depth + 1);
      if (c) [out addObject:c];
    }
    return out;
  }
  if ([v isKindOfClass:[NSDictionary class]]) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (id k in (NSDictionary *)v) {
      if (![k isKindOfClass:[NSString class]]) continue;
      id c = PlistSafeCopy(((NSDictionary *)v)[k], depth + 1);
      if (c) out[k] = c;
    }
    return out;
  }
  return nil;
}

static NSDictionary *FilterHexDictionary(id raw) {
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  for (id k in DictOf(raw)) {
    if (![k isKindOfClass:[NSString class]] || [k length] == 0 || [k length] > 160) continue;
    NSString *hex = ThemeHexKeepingAlpha(((NSDictionary *)raw)[k]);
    if (hex) out[k] = hex;
  }
  return out;
}

// Validates a theme loaded from a file the user picked (or from theme.json) and normalizes it into the
// shape the engine reads: name, colors, mixer, auto, region_palette, region_palette_hues. Unknown top-level
// keys are preserved. Returns nil (and a reason) if it contains no usable colors.
static NSDictionary *SanitizeImportedTheme(id raw, NSString **reason) {
  if (![raw isKindOfClass:[NSDictionary class]]) {
    if (reason) *reason = @"The file is not a JSON object.";
    return nil;
  }
  NSDictionary *root = PlistSafeCopy(raw, 0);
  BOOL flat = ![root[@"colors"] isKindOfClass:[NSDictionary class]];  // the engine also accepts a bare { key: "#hex" } file
  NSDictionary *colors = FilterHexDictionary(flat ? root : root[@"colors"]);
  if (colors.count == 0) {
    if (reason) *reason = @"The file has no usable “colors” (expected hex values like #1a1d2e).";
    return nil;
  }
  NSMutableDictionary *theme = [NSMutableDictionary dictionary];
  for (NSString *k in root) {
    if (flat && ThemeHexKeepingAlpha(root[k])) continue;  // flat-file color entries are not metadata
    theme[k] = root[k];
  }
  NSString *name = [root[@"name"] isKindOfClass:[NSString class]] ? [root[@"name"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
  if (name.length > 64) name = [name substringToIndex:64];
  theme[@"name"] = name.length ? name : @"Imported theme";
  theme[@"colors"] = colors;
  theme[@"mixer"] = FilterHexDictionary(root[@"mixer"]);
  NSMutableArray *regions = [NSMutableArray array];
  for (id v in ArrayOf(root[@"region_palette"])) {
    NSString *h = OpaqueHexFromTheme(v);
    if (h && regions.count < 64) [regions addObject:h];
  }
  theme[@"region_palette"] = regions;
  NSArray *hues = ArrayOf(root[@"region_palette_hues"]);
  BOOL huesOK = hues.count == regions.count;
  for (id h in hues) if (![h isKindOfClass:[NSNumber class]]) huesOK = NO;
  if (!huesOK) {
    NSMutableArray *fresh = [NSMutableArray array];
    for (NSString *h in regions) [fresh addObject:HueDegrees(h)];
    hues = fresh;
  }
  theme[@"region_palette_hues"] = hues;
  NSMutableDictionary *autoBlock = [DictOf(root[@"auto"]) mutableCopy];
  if (![autoBlock[@"enabled"] isKindOfClass:[NSNumber class]]) autoBlock[@"enabled"] = @YES;
  theme[@"auto"] = autoBlock;
  return theme;
}

// NSJSONSerialization prints doubles with 17 digits (0.08 becomes 0.08000000000000000167). Re-box them as short
// decimals so exported/applied theme files stay as readable as the bundled ones; the parsed values are identical.
static id TidyNumbers(id v) {
  if ([v isKindOfClass:[NSDictionary class]]) {
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:[v count]];
    for (id k in (NSDictionary *)v) out[k] = TidyNumbers(((NSDictionary *)v)[k]);
    return out;
  }
  if ([v isKindOfClass:[NSArray class]]) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:[v count]];
    for (id x in (NSArray *)v) [out addObject:TidyNumbers(x)];
    return out;
  }
  if ([v isKindOfClass:[NSNumber class]] && CFNumberIsFloatType((__bridge CFNumberRef)v)) {
    NSDecimalNumber *d = [NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%.9g", [v doubleValue]]];
    return isnan(d.doubleValue) ? v : d;
  }
  return v;
}

#pragma mark - Editable roles (what the Customize tab exposes)

static NSDictionary *Role(NSString *rid, NSString *label) { return @{@"id": rid, @"label": label}; }

static NSArray<NSDictionary *> *RoleSections(void) {
  static NSArray<NSDictionary *> *sections;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableArray *regionRoles = [NSMutableArray array];
    for (NSInteger i = 0; i < kMaxRegionRoles; i++)
      [regionRoles addObject:Role([NSString stringWithFormat:@"%@%ld", kRegionPrefix, (long)i],
                                  [NSString stringWithFormat:@"Region %ld", (long)i + 1])];
    sections = @[
      @{@"name": @"Surfaces", @"roles": @[
          Role(@"ArrangeWorkspaceColor", @"Arrange workspace"),
          Role(@"MainWindowColor", @"Toolbar & window chrome"),
          Role(@"PanelBackgroundColor", @"Side panels & library"),
          Role(@"PanelHeaderColor", @"Panel headers"),
          Role(@"RulerColor", @"Ruler"),
          Role(@"TrackHeader/Background", @"Track headers"),
          Role(@"TrackHeader/EmptyAreaBelow", @"Empty area below tracks"),
          Role(@"InspectorColor", @"Inspector"),
          Role(@"InspectorAlternatingRowColor", @"Inspector rows"),
          Role(@"ChannelstripColor", @"Mixer channel strips"),
          Role(@"mixer:MixerArea", @"Mixer background"),
      ]},
      @{@"name": @"Text", @"roles": @[
          Role(@"TextColor", @"Primary text"),
          Role(@"TextSecondaryColor", @"Secondary text"),
          Role(@"TextMutedColor", @"Muted text"),
          Role(@"ToolbarTextColor", @"Toolbar text"),
          Role(@"TableViewHeaderTextColor", @"List headers"),
          Role(@"ControlTextTitleColor", @"Control titles"),
      ]},
      @{@"name": @"Accent & selection", @"roles": @[
          Role(kAccentRoleID, @"Accent & highlights"),
          Role(@"SelectionColor", @"Selection"),
          Role(@"TrackHeader/SelectedBackground", @"Selected track"),
          Role(@"ChannelstripSelectedColor", @"Selected channel strip"),
          Role(@"FocusRingColor", @"Focus ring"),
      ]},
      @{@"name": @"Transport & LCD", @"roles": @[
          Role(@"TransportDisplay/Text", @"LCD text"),
          Role(@"TransportDisplay/Label", @"LCD labels"),
          Role(@"TransportDisplay/SelectedText", @"LCD highlighted text"),
          Role(@"TransportDisplay/PerformanceMeterBackground", @"LCD meter background"),
          Role(@"ToolbarGlyphColor", @"Toolbar icons"),
          Role(@"ToolbarButtonFill", @"Toolbar buttons"),
          Role(@"ToolbarButtonBorder", @"Toolbar button borders"),
      ]},
      @{@"name": @"Regions", @"isRegions": @YES, @"roles": regionRoles},
    ];
  });
  return sections;
}

static NSSet<NSString *> *AllRoleIDs(void) {
  static NSSet *ids;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableSet *s = [NSMutableSet set];
    for (NSDictionary *sec in RoleSections())
      for (NSDictionary *r in sec[@"roles"]) [s addObject:r[@"id"]];
    ids = [s copy];
  });
  return ids;
}

static NSString *RoleMixerKey(NSString *rid) {
  return [rid hasPrefix:kMixerPrefix] ? [rid substringFromIndex:kMixerPrefix.length] : nil;
}

static NSInteger RoleRegionIndex(NSString *rid) {
  if (![rid hasPrefix:kRegionPrefix]) return -1;
  return [[rid substringFromIndex:kRegionPrefix.length] integerValue];
}

#pragma mark - Theme state (preset or imported theme + the user's overrides)

@interface T4LThemeState : NSObject
@property (nonatomic, copy, readonly) NSDictionary *base;
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString *, NSString *> *overrides;
@property (nonatomic, strong) NSNumber *autoOverride;
- (instancetype)initWithBase:(NSDictionary *)base;
- (NSString *)baseHexForRole:(NSString *)rid;
- (NSString *)effectiveHexForRole:(NSString *)rid;
- (BOOL)roleIsModified:(NSString *)rid;
- (void)setHex:(NSString *)hex forRole:(NSString *)rid;
- (void)resetAll;
- (NSUInteger)changeCount;
- (BOOL)baseAutoEnabled;
- (BOOL)autoEnabled;
- (NSUInteger)regionCount;
- (NSDictionary *)mergedTheme;
- (NSDictionary *)persistable;
- (void)loadPersisted:(NSDictionary *)stored;
@end

@implementation T4LThemeState {
  NSMutableDictionary<NSString *, NSString *> *_parentOf;
  NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *_childrenOf;
}

- (instancetype)initWithBase:(NSDictionary *)base {
  self = [super init];
  if (!self) return nil;
  _base = [base copy] ?: @{};
  _overrides = [NSMutableDictionary dictionary];
  _parentOf = [NSMutableDictionary dictionary];
  _childrenOf = [NSMutableDictionary dictionary];
  [self computeLinks];
  return self;
}

- (void)link:(NSString *)child to:(NSString *)parent {
  if (_parentOf[child] || [child isEqualToString:parent]) return;
  _parentOf[child] = parent;
  NSMutableArray *kids = _childrenOf[parent];
  if (!kids) { kids = [NSMutableArray array]; _childrenOf[parent] = kids; }
  [kids addObject:child];
}

// Keys whose value in the preset equals the value of a role are "derived" from it and follow it when it is
// edited: channel-strip roles drive the matching mixer keys, and the accent drives everything colored with it.
- (void)computeLinks {
  NSDictionary *colors = DictOf(_base[@"colors"]), *mixer = DictOf(_base[@"mixer"]);
  NSDictionary *pairs = @{@"ChannelstripColor": @"mixer:ChannelstripBackground",
                          @"ChannelstripSelectedColor": @"mixer:ChannelstripBackgroundSelected"};
  for (NSString *parent in pairs) {
    NSString *a = [self baseHexForRole:parent], *b = [self baseHexForRole:pairs[parent]];
    if (a && b && [a isEqualToString:b]) [self link:pairs[parent] to:parent];
  }
  NSString *accent = [self baseHexForRole:kAccentRoleID];
  if (!accent) return;
  for (NSString *k in colors)
    if ([OpaqueHexFromTheme(colors[k]) isEqualToString:accent]) [self link:k to:kAccentRoleID];
  for (NSString *k in mixer)
    if ([OpaqueHexFromTheme(mixer[k]) isEqualToString:accent]) [self link:[kMixerPrefix stringByAppendingString:k] to:kAccentRoleID];
}

- (NSString *)baseHexForRole:(NSString *)rid {
  NSInteger ri = RoleRegionIndex(rid);
  if (ri >= 0) {
    NSArray *a = ArrayOf(_base[@"region_palette"]);
    return (NSUInteger)ri < a.count ? OpaqueHexFromTheme(a[ri]) : nil;
  }
  NSString *mk = RoleMixerKey(rid);
  if (mk) return OpaqueHexFromTheme(DictOf(_base[@"mixer"])[mk]);
  return OpaqueHexFromTheme(DictOf(_base[@"colors"])[rid]);
}

- (NSString *)effectiveHexForRole:(NSString *)rid {
  NSString *own = _overrides[rid];
  if (own) return own;
  NSString *parent = _parentOf[rid];
  if (parent && _overrides[parent]) return _overrides[parent];
  return [self baseHexForRole:rid];
}

- (BOOL)roleIsModified:(NSString *)rid {
  NSString *eff = [self effectiveHexForRole:rid], *base = [self baseHexForRole:rid];
  return eff != nil && ![eff isEqualToString:base ?: @""];
}

- (void)setHex:(NSString *)hex forRole:(NSString *)rid {
  NSString *n = NormalizeHex(hex);
  if (!n || ![AllRoleIDs() containsObject:rid]) return;
  NSString *base = [self baseHexForRole:rid];
  NSString *parent = _parentOf[rid];
  BOOL parentEdited = parent && _overrides[parent] != nil;
  if (base && [base isEqualToString:n] && !parentEdited) [_overrides removeObjectForKey:rid];
  else _overrides[rid] = n;
}

- (void)resetAll {
  [_overrides removeAllObjects];
  self.autoOverride = nil;
}

- (NSUInteger)changeCount {
  return _overrides.count + (_autoOverride ? 1 : 0);
}

- (BOOL)baseAutoEnabled {
  id e = DictOf(_base[@"auto"])[@"enabled"];
  return [e isKindOfClass:[NSNumber class]] ? [e boolValue] : YES;
}

- (BOOL)autoEnabled {
  return _autoOverride ? _autoOverride.boolValue : [self baseAutoEnabled];
}

- (NSUInteger)regionCount {
  return ArrayOf(_base[@"region_palette"]).count;
}

- (void)put:(NSString *)hex role:(NSString *)rid colors:(NSMutableDictionary *)colors mixer:(NSMutableDictionary *)mixer
    regions:(NSMutableArray *)regions changedRegions:(NSMutableIndexSet *)changed {
  NSInteger ri = RoleRegionIndex(rid);
  if (ri >= 0) {
    if ((NSUInteger)ri < regions.count) { regions[ri] = hex; [changed addIndex:ri]; }
    return;
  }
  NSString *mk = RoleMixerKey(rid);
  if (mk) mixer[mk] = hex;
  else colors[rid] = hex;
}

// The complete theme.json dictionary: the base theme with every edit applied. Keys the user did not touch
// are left exactly as they were, and keys that were derived from an edited role are kept in step with it.
- (NSDictionary *)mergedTheme {
  NSMutableDictionary *theme = [_base mutableCopy] ?: [NSMutableDictionary dictionary];
  NSMutableDictionary *colors = [DictOf(_base[@"colors"]) mutableCopy];
  NSMutableDictionary *mixer = [DictOf(_base[@"mixer"]) mutableCopy];
  NSMutableArray *regions = [ArrayOf(_base[@"region_palette"]) mutableCopy];
  NSMutableArray *hues = [ArrayOf(_base[@"region_palette_hues"]) mutableCopy];
  NSMutableIndexSet *changed = [NSMutableIndexSet indexSet];

  for (NSString *parent in _childrenOf) {
    NSString *ov = _overrides[parent];
    if (!ov) continue;
    for (NSString *child in _childrenOf[parent])
      if (!_overrides[child]) [self put:ov role:child colors:colors mixer:mixer regions:regions changedRegions:changed];
  }
  for (NSString *rid in _overrides)
    [self put:_overrides[rid] role:rid colors:colors mixer:mixer regions:regions changedRegions:changed];

  if (hues.count != regions.count) {
    hues = [NSMutableArray array];
    for (id h in regions) [hues addObject:HueDegrees(OpaqueHexFromTheme(h) ?: @"#808080")];
  } else {
    [changed enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) { hues[i] = HueDegrees(regions[i]); }];
  }

  NSMutableDictionary *autoBlock = [DictOf(_base[@"auto"]) mutableCopy];
  autoBlock[@"enabled"] = @([self autoEnabled]);
  if (_overrides[kAccentRoleID]) autoBlock[@"accent"] = _overrides[kAccentRoleID];

  NSString *name = [_base[@"name"] isKindOfClass:[NSString class]] && [_base[@"name"] length] ? _base[@"name"] : @"Custom";
  if ([self changeCount] > 0 && ![name hasSuffix:@" (customized)"]) {
    if (name.length > 50) name = [name substringToIndex:50];
    name = [name stringByAppendingString:@" (customized)"];
  }
  theme[@"name"] = name;
  theme[@"colors"] = colors;
  theme[@"mixer"] = mixer;
  theme[@"auto"] = autoBlock;
  theme[@"region_palette"] = regions;
  theme[@"region_palette_hues"] = hues;
  return theme;
}

- (NSDictionary *)persistable {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  d[@"overrides"] = [_overrides copy];
  if (_autoOverride) d[@"auto"] = _autoOverride;
  return d;
}

- (void)loadPersisted:(NSDictionary *)stored {
  [self resetAll];
  if (![stored isKindOfClass:[NSDictionary class]]) return;
  NSDictionary *ov = DictOf(stored[@"overrides"]);
  for (id k in ov) {
    if (![k isKindOfClass:[NSString class]] || ![AllRoleIDs() containsObject:k]) continue;
    NSString *n = NormalizeHex(ov[k]);
    if (n) _overrides[k] = n;
  }
  if ([stored[@"auto"] isKindOfClass:[NSNumber class]] && [stored[@"auto"] boolValue] != [self baseAutoEnabled])
    _autoOverride = stored[@"auto"];
}

@end

#pragma mark - Mock palette (colors taken from a theme dictionary)

@interface T4LMockPalette : NSObject
@property (strong) NSColor *window, *toolbar, *workspace, *panel, *ruler, *header, *headerSel, *divider, *emptyBelow;
@property (strong) NSColor *text, *textDim, *accent, *glyph, *lcdBg, *lcdText, *lcdLabel;
@property (strong) NSColor *mixerArea, *strip, *stripSel, *meter, *meterBg, *knob, *knobInd, *btnBg, *btnLine;
@property (copy) NSArray<NSColor *> *regions;
@end
@implementation T4LMockPalette
@end

static NSColor *ThemeColor(NSDictionary *dict, NSArray<NSString *> *keys, NSColor *fallback) {
  for (NSString *k in keys) {
    NSString *h = OpaqueHexFromTheme(dict[k]);
    if (h) return ColorFromHex(h);
  }
  return fallback;
}

static T4LMockPalette *PaletteFromTheme(NSDictionary *theme) {
  NSDictionary *c = DictOf(theme[@"colors"]), *m = DictOf(theme[@"mixer"]);
  T4LMockPalette *p = [T4LMockPalette new];
  NSColor *gray = [NSColor colorWithSRGBRed:0.16 green:0.16 blue:0.18 alpha:1];
  p.window = ThemeColor(c, @[@"MainWindowColor", @"PanelBackgroundColor"], gray);
  p.workspace = ThemeColor(c, @[@"ArrangeWorkspaceColor"], p.window);
  p.toolbar = ThemeColor(c, @[@"defaultToolbarBackgroundColor", @"MainWindowColor"], p.window);
  p.panel = ThemeColor(c, @[@"PanelBackgroundColor"], p.window);
  p.ruler = ThemeColor(c, @[@"RulerColor"], p.panel);
  p.header = ThemeColor(c, @[@"TrackHeader/Background"], p.panel);
  p.text = ThemeColor(c, @[@"TextColor", @"ToolbarTextColor"], ReadableInk(p.window));
  p.headerSel = ThemeColor(c, @[@"TrackHeader/SelectedBackground", @"SelectionColor"], MixColors(p.header, p.text, 0.15));
  p.divider = ThemeColor(c, @[@"TrackHeader/BottomLine", @"DividerPrimaryColor"], MixColors(p.window, p.text, 0.2));
  p.emptyBelow = ThemeColor(c, @[@"TrackHeader/EmptyAreaBelow"], p.workspace);
  p.textDim = ThemeColor(c, @[@"TextSecondaryColor"], MixColors(p.window, p.text, 0.6));
  p.accent = ThemeColor(c, @[kAccentRoleID, @"AccentColor", @"CustomAccentColor"], NSColor.systemBlueColor);
  p.glyph = ThemeColor(c, @[@"ToolbarGlyphColor"], p.text);
  p.lcdBg = ThemeColor(c, @[@"TransportDisplay/PerformanceMeterBackground"], MixColors(p.toolbar, p.workspace, 0.6));
  p.lcdText = ThemeColor(c, @[@"TransportDisplay/Text"], p.text);
  p.lcdLabel = ThemeColor(c, @[@"TransportDisplay/Label"], p.accent);
  p.strip = ThemeColor(c, @[@"ChannelstripColor"], ThemeColor(m, @[@"ChannelstripBackground"], p.panel));
  p.stripSel = ThemeColor(c, @[@"ChannelstripSelectedColor"], ThemeColor(m, @[@"ChannelstripBackgroundSelected"], p.headerSel));
  p.mixerArea = ThemeColor(m, @[@"MixerArea"], MixColors(p.strip, p.workspace, 0.5));
  p.meter = ThemeColor(m, @[@"Meter"], p.accent);
  p.meterBg = ThemeColor(m, @[@"MeterBg"], MixColors(p.strip, p.workspace, 0.7));
  p.knob = ThemeColor(m, @[@"Knob"], p.divider);
  p.knobInd = ThemeColor(m, @[@"KnobIndicator"], p.text);
  p.btnBg = ThemeColor(m, @[@"ButtonBackground"], MixColors(p.strip, p.text, 0.1));
  p.btnLine = ThemeColor(m, @[@"ButtonOutline"], p.divider);

  NSMutableArray<NSColor *> *cols = [NSMutableArray array];
  for (id v in ArrayOf(theme[@"region_palette"])) {
    NSString *h = OpaqueHexFromTheme(v);
    if (h) [cols addObject:ColorFromHex(h)];
  }
  if (cols.count == 0) {
    cols = [@[p.accent, MixColors(p.accent, p.text, 0.35), MixColors(p.accent, p.window, 0.4), MixColors(p.accent, p.text, 0.15)] mutableCopy];
  }
  NSUInteger n = cols.count, stride = n >= 8 ? n / 4 : 1;
  NSMutableArray *picked = [NSMutableArray array];
  for (NSUInteger i = 0; i < 7; i++) [picked addObject:cols[(i * stride + i / 4) % n]];
  p.regions = picked;

  // Anything that stands in for text is forced to stay legible on the surface it sits on, whatever the theme says.
  p.text = LegibleOn(p.text, p.header);
  p.textDim = LegibleOn(p.textDim, p.header);
  p.glyph = LegibleOn(p.glyph, p.toolbar);
  p.lcdText = LegibleOn(p.lcdText, p.lcdBg);
  p.lcdLabel = LegibleOn(p.lcdLabel, p.lcdBg);
  p.knobInd = LegibleOn(p.knobInd, p.knob);
  return p;
}

#pragma mark - Window mock (a tiny drawing of a Logic window in a theme's colors)

static void FillR(NSColor *c, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
  [c setFill];
  NSRectFillUsingOperation(NSMakeRect(x, y, w, h), NSCompositingOperationSourceOver);
}

static void FillRound(NSColor *c, CGFloat x, CGFloat y, CGFloat w, CGFloat h, CGFloat r) {
  [c setFill];
  [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, w, h) xRadius:r yRadius:r] fill];
}

static void StrokeRound(NSColor *c, CGFloat x, CGFloat y, CGFloat w, CGFloat h, CGFloat r, CGFloat lw) {
  NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x + lw / 2, y + lw / 2, w - lw, h - lw) xRadius:r yRadius:r];
  p.lineWidth = lw;
  [c setStroke];
  [p stroke];
}

static void FillCircle(NSColor *c, CGFloat cx, CGFloat cy, CGFloat r) {
  [c setFill];
  [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - r, cy - r, 2 * r, 2 * r)] fill];
}

static void FillTri(NSColor *c, NSPoint a, NSPoint b, NSPoint d) {
  NSBezierPath *p = [NSBezierPath bezierPath];
  [p moveToPoint:a];
  [p lineToPoint:b];
  [p lineToPoint:d];
  [p closePath];
  [c setFill];
  [p fill];
}

static void DrawMockRegion(T4LMockPalette *p, NSColor *c, CGFloat x0, CGFloat y, CGFloat x1, CGFloat h, BOOL midi, int seed) {
  NSRect r = NSMakeRect(x0, y, x1 - x0, h);
  [NSGraphicsContext saveGraphicsState];
  [[NSBezierPath bezierPathWithRoundedRect:r xRadius:2.5 yRadius:2.5] addClip];
  NSColor *body = MixColors(p.workspace, c, 0.45);
  FillR(body, x0, y, x1 - x0, h);
  FillR(c, x0, y, x1 - x0, 8);
  FillRound(InkOn(c, 0.85), x0 + 4, y + 2.9, MIN(22.0, (x1 - x0) * 0.35), 2.2, 1.1);
  NSColor *mark = InkOn(body, 0.6);
  CGFloat mid = y + 8 + (h - 8) / 2;
  if (!midi) {
    int k = 0;
    for (CGFloat x = x0 + 3; x < x1 - 3; x += 2.1, k++) {
      CGFloat a = fabs(sin(k * 0.55 + seed)) * (0.55 + 0.45 * sin(k * 0.13 + seed * 1.7));
      CGFloat hh = 2 + a * (h - 12) * 0.9;
      FillR(mark, x, mid - hh / 2, 1.1, hh);
    }
  } else {
    uint32_t s = (uint32_t)(seed * 7919 + 13);
    for (int k = 0; k < 10; k++) {
      s = s * 1103515245u + 12345u;
      CGFloat nx = x0 + 4 + ((s >> 8) % 100) / 100.0 * (x1 - x0 - 20);
      s = s * 1103515245u + 12345u;
      int row = (int)((s >> 8) % 5);
      CGFloat len = 6 + (CGFloat)((s >> 12) % 9);
      FillRound(mark, nx, y + 10.5 + row * 3.6, MIN(len, x1 - nx - 3), 2, 0.8);
    }
  }
  [NSGraphicsContext restoreGraphicsState];
}

static void DrawMockStrip(T4LMockPalette *p, CGFloat x, CGFloat y, CGFloat w, CGFloat h, BOOL selected, CGFloat level) {
  FillRound(selected ? p.stripSel : p.strip, x, y, w, h, 3);
  CGFloat cx = x + w / 2;
  for (int i = 0; i < 3; i++) {  // M S R buttons
    FillRound(p.btnBg, x + 3.5 + i * 7.8, y + 4, 6.5, 6, 1.5);
    StrokeRound(p.btnLine, x + 3.5 + i * 7.8, y + 4, 6.5, 6, 1.5, 0.7);
  }
  FillCircle(p.knob, cx, y + 24, 6.2);  // pan knob
  NSBezierPath *ind = [NSBezierPath bezierPath];
  [ind moveToPoint:NSMakePoint(cx, y + 24)];
  [ind lineToPoint:NSMakePoint(cx + 2.6, y + 19.2)];
  ind.lineWidth = 1.3;
  ind.lineCapStyle = NSLineCapStyleRound;
  [p.knobInd setStroke];
  [ind stroke];
  CGFloat top = y + 38, trackH = h - 70;
  FillR(p.meterBg, x + 5.5, top, 4, trackH);  // meter
  FillR(p.meter, x + 5.5, top + trackH * (1 - level), 4, trackH * level);
  FillR(MixColors(p.strip, p.text, 0.3), x + w - 9.2, top, 1.6, trackH);  // fader groove
  CGFloat capY = top + trackH * (1 - level) - 3;
  FillRound(InkOn(p.strip, 0.9), x + w - 13.5, capY, 10.2, 6, 1.5);
  FillR(p.strip, x + w - 13.5 + 1.5, capY + 2.6, 7.2, 0.8);
  FillRound(MixColors(p.strip, p.text, 0.12), x + 3.5, y + h - 14, w - 7, 10, 2);  // name plate
  FillRound(InkOn(p.strip, 0.7), x + 7, y + h - 10.2, w - 14, 2.6, 1.3);
}

@interface WindowMockView : NSView
@property (nonatomic, strong) T4LMockPalette *palette;
@property (nonatomic, copy) NSString *themeName;
@end

@implementation WindowMockView

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityImageRole; }
- (NSString *)accessibilityLabel {
  return [NSString stringWithFormat:@"Preview of the %@ theme on a Logic Pro window", self.themeName ?: @"selected"];
}

- (void)setPalette:(T4LMockPalette *)palette {
  _palette = palette;
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  T4LMockPalette *p = self.palette;
  const CGFloat W = 320, H = 200;
  NSRect b = self.bounds;
  CGFloat s = MIN(NSWidth(b) / W, NSHeight(b) / H);
  if (s <= 0) return;
  NSGraphicsContext *gc = [NSGraphicsContext currentContext];
  [gc saveGraphicsState];
  NSAffineTransform *tf = [NSAffineTransform transform];
  [tf translateXBy:(NSWidth(b) - W * s) / 2 yBy:(NSHeight(b) - H * s) / 2];
  [tf scaleBy:s];
  [tf concat];
  NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, W, H) xRadius:7 yRadius:7];
  [clip addClip];
  if (!p) {
    FillR(NSColor.quaternaryLabelColor, 0, 0, W, H);
    [gc restoreGraphicsState];
    return;
  }

  FillR(p.window, 0, 0, W, H);

  // Toolbar: window dots, transport glyphs, LCD, right-hand pills.
  const CGFloat tb = 24;
  FillR(p.toolbar, 0, 0, W, tb);
  FillR(p.divider, 0, tb - 1, W, 1);
  for (int i = 0; i < 3; i++) FillCircle([p.textDim colorWithAlphaComponent:0.4], 10 + i * 9, 12, 3);
  FillTri(p.glyph, NSMakePoint(63, 12), NSMakePoint(68.5, 8.5), NSMakePoint(68.5, 15.5));
  FillTri(p.glyph, NSMakePoint(68, 12), NSMakePoint(73.5, 8.5), NSMakePoint(73.5, 15.5));
  FillTri(p.accent, NSMakePoint(83, 7.5), NSMakePoint(83, 16.5), NSMakePoint(91.5, 12));
  FillCircle([p.glyph colorWithAlphaComponent:0.6], 102, 12, 3.4);
  FillRound(p.lcdBg, 116, 4, 104, 16, 3.5);
  StrokeRound([p.divider colorWithAlphaComponent:0.9], 116, 4, 104, 16, 3.5, 0.8);
  for (int i = 0; i < 6; i++) {
    CGFloat x = 123 + i * 7.2 + (i >= 2 ? 3 : 0) + (i >= 4 ? 3 : 0);
    FillRound(p.lcdText, x, 8, 4.4, 8, 1);
  }
  FillRound(p.lcdLabel, 183, 8.5, 26, 2.4, 1.2);
  FillRound([p.lcdLabel colorWithAlphaComponent:0.65], 183, 13.2, 17, 2.4, 1.2);
  for (int i = 0; i < 3; i++) {
    StrokeRound([p.glyph colorWithAlphaComponent:0.4], 236 + i * 26, 7, 22, 10, 3, 0.8);
    FillRound([p.glyph colorWithAlphaComponent:0.55], 241 + i * 26, 10.7, 12, 2.6, 1.3);
  }

  // Track headers, ruler, lanes.
  const CGFloat headW = 70, arrEnd = 258, laneH = 36, lanesTop = 36, lanes = 4;
  FillR(p.panel, 0, tb, headW, lanesTop - tb);
  FillRound([p.textDim colorWithAlphaComponent:0.5], 8, tb + 4.6, 22, 2.6, 1.3);
  FillR(p.ruler, headW, tb, arrEnd - headW, lanesTop - tb);
  FillR(p.divider, headW, lanesTop - 1, arrEnd - headW, 1);
  for (int i = 0; headW + i * 10 < arrEnd; i++) {
    CGFloat x = headW + i * 10 + 4;
    BOOL major = i % 4 == 0;
    FillR([p.textDim colorWithAlphaComponent:major ? 0.75 : 0.45], x, lanesTop - (major ? 7.5 : 4.5), 0.8, major ? 6 : 3);
    if (major) FillRound([p.textDim colorWithAlphaComponent:0.75], x + 2.5, tb + 3, 5, 2.4, 1.2);
  }
  FillR([p.accent colorWithAlphaComponent:0.55], 108, tb, 82, 3);  // cycle range

  FillR(p.emptyBelow, 0, lanesTop + lanes * laneH, arrEnd, H - lanesTop - lanes * laneH);
  for (int i = 0; i < lanes; i++) {
    CGFloat y = lanesTop + i * laneH;
    BOOL sel = i == 0;
    FillR(sel ? p.headerSel : p.header, 0, y, headW, laneH);
    FillR(sel ? MixColors(p.workspace, p.headerSel, 0.28) : p.workspace, headW, y, arrEnd - headW, laneH);
    FillR(p.divider, 0, y + laneH - 1, arrEnd, 1);
    FillR(p.regions[i % p.regions.count], 0, y + 1, 3, laneH - 2);
    FillRound([p.text colorWithAlphaComponent:0.22], 9, y + 8, 14, 14, 3.2);
    FillRound([p.text colorWithAlphaComponent:0.6], 13, y + 12, 6, 6, 1.5);
    FillRound([p.text colorWithAlphaComponent:0.85], 29, y + 9, 30, 3.6, 1.8);
    FillRound([p.textDim colorWithAlphaComponent:0.6], 29, y + 16.5, 19, 2.8, 1.4);
    FillRound([p.textDim colorWithAlphaComponent:0.35], 29, y + 23, 8, 6.5, 1.8);
    FillRound([p.textDim colorWithAlphaComponent:0.35], 40, y + 23, 8, 6.5, 1.8);
  }
  FillR(p.divider, headW - 1, tb, 1, lanes * laneH + lanesTop - tb);
  for (CGFloat x = headW + 40; x < arrEnd; x += 40)
    FillR([p.divider colorWithAlphaComponent:0.35], x, lanesTop, 1, lanes * laneH);

  const struct { int lane; CGFloat x0, x1; BOOL midi; } regs[] = {
    {0, 76, 150, NO}, {0, 154, 236, NO}, {1, 76, 198, YES}, {2, 108, 176, NO}, {2, 180, 250, NO},
    {3, 76, 128, YES}, {3, 134, 224, YES},
  };
  for (int i = 0; i < 7; i++)
    DrawMockRegion(p, p.regions[i], regs[i].x0, lanesTop + regs[i].lane * laneH + 3, regs[i].x1, laneH - 6, regs[i].midi, i + 1);

  // Playhead.
  FillR(p.accent, 127.2, tb, 1.6, lanesTop + lanes * laneH - tb);
  FillTri(p.accent, NSMakePoint(122.5, tb), NSMakePoint(133.5, tb), NSMakePoint(128, tb + 7.5));

  // Mixer column with two strips.
  FillR(p.mixerArea, arrEnd, tb, W - arrEnd, H - tb);
  FillR(p.divider, arrEnd, tb, 1, H - tb);
  DrawMockStrip(p, arrEnd + 3, tb + 3, 28, H - tb - 6, YES, 0.62);
  DrawMockStrip(p, arrEnd + 3 + 28 + 2, tb + 3, 28, H - tb - 6, NO, 0.4);

  [gc restoreGraphicsState];

  // Hairline frame (drawn outside the scaled space so it stays crisp).
  NSRect frame = NSInsetRect(NSMakeRect((NSWidth(b) - W * s) / 2, (NSHeight(b) - H * s) / 2, W * s, H * s), 0.5, 0.5);
  NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:frame xRadius:7 * s yRadius:7 * s];
  outline.lineWidth = 1;
  [[NSColor.labelColor colorWithAlphaComponent:0.22] setStroke];
  [outline stroke];
}

@end

#pragma mark - Scroll + layout containers

@interface FlippedDocView : NSView
@property (copy) CGFloat (^layoutBlock)(NSSize size);  // lays out subviews for the given size, returns needed height
@property (nonatomic) BOOL autoHeight;                  // resize own height to the returned value (scroll documents)
- (void)relayout;
@end

@implementation FlippedDocView {
  BOOL _inLayout;
}

- (BOOL)isFlipped { return YES; }

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self relayout];
}

- (void)relayout {
  if (_inLayout || !self.layoutBlock) return;
  _inLayout = YES;
  CGFloat h = self.layoutBlock(self.bounds.size);
  if (self.autoHeight && fabs(h - NSHeight(self.frame)) > 0.5)
    [super setFrameSize:NSMakeSize(NSWidth(self.frame), h)];
  _inLayout = NO;
}

@end

// Keeps the scroll document exactly as wide as the visible area; the document sets its own height.
@interface ThemeScrollView : NSScrollView
- (void)syncDocumentWidth;
@end

@implementation ThemeScrollView

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self syncDocumentWidth];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self syncDocumentWidth];
}

- (void)syncDocumentWidth {
  NSView *doc = self.documentView;
  if (!doc) return;
  CGFloat w = NSWidth(self.contentView.bounds);
  if (w < 240) w = 240;
  NSRect f = doc.frame;
  if (fabs(f.size.width - w) < 0.5) return;
  f.size.width = w;
  doc.frame = f;
}

@end

#pragma mark - Preset card

@interface T4LCheckBadge : NSView
@end

@implementation T4LCheckBadge
- (BOOL)isAccessibilityElement { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSRect b = self.bounds;
  // Accent-colored disc with a white ring; the check takes whichever ink reads best on that accent (yellow accents get a dark check).
  NSColor *accent = [NSColor.controlAccentColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: NSColor.systemBlueColor;
  [[NSColor whiteColor] setFill];
  [[NSBezierPath bezierPathWithOvalInRect:b] fill];
  [accent setFill];
  [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(b, 1.6, 1.6)] fill];
  NSBezierPath *check = [NSBezierPath bezierPath];
  CGFloat w = NSWidth(b), h = NSHeight(b);
  [check moveToPoint:NSMakePoint(w * 0.29, h * 0.5)];
  [check lineToPoint:NSMakePoint(w * 0.44, h * 0.34)];
  [check lineToPoint:NSMakePoint(w * 0.72, h * 0.66)];
  check.lineWidth = 2;
  check.lineCapStyle = NSLineCapStyleRound;
  check.lineJoinStyle = NSLineJoinStyleRound;
  [ReadableInk(accent) setStroke];
  [check stroke];
}
@end

@interface PresetCard : NSView
@property (copy) NSString *slug;
@property (copy) void (^onSelect)(NSString *slug);
@property (nonatomic) BOOL selected;
@property (nonatomic) BOOL customized;
@property (nonatomic, readonly) WindowMockView *mock;
+ (CGFloat)heightForWidth:(CGFloat)width;
- (instancetype)initWithPreset:(NSDictionary *)preset palette:(T4LMockPalette *)palette;
@end

@implementation PresetCard {
  NSTextField *_title;
  NSTextField *_tagline;
  NSTextField *_tag;
  T4LCheckBadge *_badge;
  NSString *_presetTitle;
  NSString *_presetTagline;
  BOOL _hover;
}

static const CGFloat kCardPad = 8;

+ (CGFloat)heightForWidth:(CGFloat)width {
  CGFloat mockH = round((width - 2 * kCardPad) * 200.0 / 320.0);
  return kCardPad + mockH + 9 + 17 + 2 + 30 + kCardPad;
}

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithPreset:(NSDictionary *)preset palette:(T4LMockPalette *)palette {
  self = [super initWithFrame:NSMakeRect(0, 0, 220, [PresetCard heightForWidth:220])];
  if (!self) return nil;
  _slug = [preset[@"slug"] copy];
  _presetTitle = [preset[@"title"] copy];
  _presetTagline = [preset[@"tagline"] copy];

  _mock = [[WindowMockView alloc] initWithFrame:NSZeroRect];
  _mock.palette = palette;
  _mock.themeName = _presetTitle;
  [_mock setAccessibilityElement:NO];

  _title = Label(_presetTitle, [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSColor.labelColor);
  _tagline = WrapLabel(_presetTagline, [NSFont systemFontOfSize:11], SecondaryText());
  _tagline.maximumNumberOfLines = 2;
  [_tagline.cell setTruncatesLastVisibleLine:YES];
  _tag = Label(@"Customized", [NSFont systemFontOfSize:10 weight:NSFontWeightMedium], NSColor.labelColor);
  _tag.alignment = NSTextAlignmentCenter;
  _tag.hidden = YES;
  _badge = [[T4LCheckBadge alloc] initWithFrame:NSMakeRect(0, 0, 22, 22)];
  _badge.hidden = YES;
  for (NSView *v in @[ _title, _tagline, _tag ]) [v setAccessibilityElement:NO];

  for (NSView *v in @[ _mock, _title, _tagline, _tag, _badge ]) [self addSubview:v];

  NSTrackingArea *area = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                      options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
                                                        owner:self
                                                     userInfo:nil];
  [self addTrackingArea:area];
  [self layoutContents];
  return self;
}

- (void)layoutContents {
  CGFloat w = NSWidth(self.bounds);
  CGFloat mockW = w - 2 * kCardPad, mockH = round(mockW * 200.0 / 320.0);
  _mock.frame = NSMakeRect(kCardPad, kCardPad, mockW, mockH);
  _badge.frame = NSMakeRect(kCardPad + mockW - 28, kCardPad + 6, 22, 22);
  CGFloat ty = kCardPad + mockH + 9;
  CGFloat tagW = 0;
  if (!_tag.hidden) tagW = ceil([_tag.attributedStringValue size].width) + 16;
  _title.frame = NSMakeRect(kCardPad + 2, ty, MAX(20, w - 2 * kCardPad - 4 - tagW - 4), 17);
  _tag.frame = NSMakeRect(w - kCardPad - 2 - tagW, ty + 1, tagW, 15);
  _tagline.frame = NSMakeRect(kCardPad + 2, ty + 19, w - 2 * kCardPad - 4, 30);
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self layoutContents];
}

- (void)setSelected:(BOOL)selected {
  if (_selected == selected) return;
  _selected = selected;
  _badge.hidden = !selected;
  [self setNeedsDisplay:YES];
}

- (void)setCustomized:(BOOL)customized {
  if (_customized == customized) return;
  _customized = customized;
  _tag.hidden = !customized;
  [self layoutContents];
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:10 yRadius:10];
  NSColor *fill = _selected ? [NSColor.controlAccentColor colorWithAlphaComponent:0.13]
                            : [NSColor.labelColor colorWithAlphaComponent:(_hover ? 0.09 : 0.045)];
  [fill setFill];
  [p fill];
  p.lineWidth = _selected ? 2.0 : 1.0;
  [(_selected ? NSColor.controlAccentColor : [NSColor.labelColor colorWithAlphaComponent:0.15]) setStroke];
  [p stroke];
  if (!_tag.hidden) {  // "Customized" pill: tinted background, normal label ink on top (reads on any accent in Light and Dark)
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.22] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:_tag.frame xRadius:7.5 yRadius:7.5] fill];
  }
}

- (void)mouseEntered:(NSEvent *)event { (void)event; _hover = YES; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)event { (void)event; _hover = NO; [self setNeedsDisplay:YES]; }

- (void)mouseDown:(NSEvent *)event {
  (void)event;
  if (self.onSelect) self.onSelect(self.slug);
}

- (void)resetCursorRects {
  [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityRadioButtonRole; }
- (NSString *)accessibilityLabel {
  return [NSString stringWithFormat:@"%@. %@%@", _presetTitle, _presetTagline, _customized ? @" Customized." : @""];
}
- (id)accessibilityValue { return @(_selected); }
- (BOOL)accessibilityPerformPress {
  if (self.onSelect) self.onSelect(self.slug);
  return YES;
}

@end

#pragma mark - Presets list (grouped by category)

@interface PresetsListView : FlippedDocView
@property (strong) NSTextField *currentLabel;
@property (strong) NSButton *customizeButton;
@property (strong) NSMutableArray<NSDictionary *> *groups;  // { header: NSTextField, cards: [PresetCard] }
- (CGFloat)layoutForWidth:(CGFloat)width;
@end

@implementation PresetsListView

- (BOOL)isFlipped { return YES; }

- (CGFloat)layoutForWidth:(CGFloat)width {
  const CGFloat inset = 16, gap = 12, minCard = 176;
  CGFloat inner = MAX(180, width - 2 * inset);
  NSInteger cols = MAX(1, MIN(4, (NSInteger)floor((inner + gap) / (minCard + gap))));
  CGFloat cardW = floor((inner - (cols - 1) * gap) / cols);
  CGFloat cardH = [PresetCard heightForWidth:cardW];
  CGFloat y = 10;

  CGFloat btnW = [self.customizeButton fittingSize].width;
  self.customizeButton.frame = NSMakeRect(width - inset - btnW, y - 2, btnW, 24);
  self.currentLabel.frame = NSMakeRect(inset, y, MAX(40, inner - btnW - 8), 20);
  y += 30;

  for (NSDictionary *g in self.groups) {
    NSTextField *hdr = g[@"header"];
    hdr.frame = NSMakeRect(inset + 2, y, inner, 14);
    y += 20;
    NSArray<PresetCard *> *cards = g[@"cards"];
    for (NSUInteger i = 0; i < cards.count; i++) {
      NSInteger col = (NSInteger)(i % cols), row = (NSInteger)(i / cols);
      cards[i].frame = NSMakeRect(inset + col * (cardW + gap), y + row * (cardH + gap), cardW, cardH);
    }
    NSUInteger rows = (cards.count + cols - 1) / cols;
    y += rows * (cardH + gap) + 6;
  }
  return y + 8;
}

@end

#pragma mark - Color rows (label + well + hex field)

@protocol T4LColorRowOwner <NSObject>
- (void)colorRow:(T4LColorRow *)row didChangeHex:(NSString *)hex;
- (void)colorRow:(T4LColorRow *)row rejectedInput:(NSString *)text;
@end

// Shows alpha-free colors only: theme colors here are opaque.
@interface T4LColorWell : NSColorWell
@end
@implementation T4LColorWell
- (void)activate:(BOOL)exclusive {
  [NSColorPanel sharedColorPanel].showsAlpha = NO;
  [super activate:exclusive];
}
@end

@interface T4LColorRow : NSView <NSTextFieldDelegate>
@property (copy) NSString *roleId;
@property (weak) id<T4LColorRowOwner> owner;
@property (nonatomic, readonly) NSColorWell *well;
@property (nonatomic, readonly) NSTextField *hexField;
@property (nonatomic) BOOL modified;
- (instancetype)initWithRole:(NSString *)rid label:(NSString *)label owner:(id<T4LColorRowOwner>)owner;
- (void)showHex:(NSString *)hex isSet:(BOOL)isSet modified:(BOOL)modified;
@end

@implementation T4LColorRow {
  NSTextField *_label;
  NSString *_shownHex;
}

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithRole:(NSString *)rid label:(NSString *)label owner:(id<T4LColorRowOwner>)owner {
  self = [super initWithFrame:NSMakeRect(0, 0, 300, 28)];
  if (!self) return nil;
  _roleId = [rid copy];
  _owner = owner;
  _label = Label(label, [NSFont systemFontOfSize:13], NSColor.labelColor);
  _label.toolTip = label;

  _well = [[T4LColorWell alloc] initWithFrame:NSMakeRect(0, 0, 44, 24)];
  _well.target = self;
  _well.action = @selector(wellChanged:);
  _well.accessibilityLabel = [label stringByAppendingString:@" color"];

  _hexField = [NSTextField textFieldWithString:@""];
  _hexField.font = MonoFont(12);
  _hexField.placeholderString = @"not set";
  _hexField.delegate = self;
  _hexField.target = self;
  _hexField.action = @selector(hexCommitted:);
  [_hexField.cell setSendsActionOnEndEditing:YES];
  _hexField.accessibilityLabel = [label stringByAppendingString:@" hex value"];

  for (NSView *v in @[ _label, _well, _hexField ]) [self addSubview:v];
  [self layoutRow];
  return self;
}

- (void)layoutRow {
  CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
  const CGFloat hexW = 76, wellW = 44, gap = 8, dotW = 14;
  _hexField.frame = NSMakeRect(w - hexW, (h - 22) / 2, hexW, 22);
  _well.frame = NSMakeRect(NSMinX(_hexField.frame) - gap - wellW, (h - 24) / 2, wellW, 24);
  _label.frame = NSMakeRect(2, (h - 17) / 2, MAX(20, NSMinX(_well.frame) - dotW - 4 - 2), 17);
  [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self layoutRow];
}

- (void)setModified:(BOOL)modified {
  if (_modified == modified) return;
  _modified = modified;
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  if (!_modified) return;
  [NSColor.controlAccentColor setFill];
  [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMinX(_well.frame) - 13, (NSHeight(self.bounds) - 6) / 2, 6, 6)] fill];
}

- (void)showHex:(NSString *)hex isSet:(BOOL)isSet modified:(BOOL)modified {
  self.modified = modified;
  _shownHex = isSet ? hex : nil;
  if (_well.active) [_well deactivate];  // an active well would echo the change back as if the user made it
  _well.color = ColorFromHex(hex);
  if (![_hexField currentEditor]) _hexField.stringValue = isSet ? hex : @"";
  _well.toolTip = modified ? @"Changed from the preset" : nil;
}

- (void)wellChanged:(id)sender {
  (void)sender;
  NSString *hex = HexFromColor(_well.color);
  _shownHex = hex;
  _hexField.stringValue = hex;
  [self.owner colorRow:self didChangeHex:hex];
}

- (void)controlTextDidChange:(NSNotification *)note {
  (void)note;
  NSString *raw = [_hexField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if ([raw hasPrefix:@"#"]) raw = [raw substringFromIndex:1];
  if (raw.length != 6) return;  // live-apply only complete values
  NSString *hex = NormalizeHex(raw);
  if (!hex || [hex isEqualToString:_shownHex]) return;
  _shownHex = hex;
  _well.color = ColorFromHex(hex);
  [self.owner colorRow:self didChangeHex:hex];
}

- (void)hexCommitted:(id)sender {
  (void)sender;
  NSString *text = _hexField.stringValue;
  NSString *hex = NormalizeHex(text);
  if (!hex) {
    if ([text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length > 0) {
      NSBeep();
      [self.owner colorRow:self rejectedInput:text];
    }
    _hexField.stringValue = _shownHex ?: @"";
    return;
  }
  _hexField.stringValue = hex;
  if ([hex isEqualToString:_shownHex]) return;
  _shownHex = hex;
  _well.color = ColorFromHex(hex);
  [self.owner colorRow:self didChangeHex:hex];
}

@end

#pragma mark - Small status dot

@interface T4LDotView : NSView
@property (nonatomic, strong) NSColor *color;
@end
@implementation T4LDotView
- (BOOL)isFlipped { return YES; }
- (BOOL)isAccessibilityElement { return NO; }
- (NSSize)intrinsicContentSize { return NSMakeSize(10, 15); }  // sits level with the first line of 12pt text
- (void)setColor:(NSColor *)color { _color = color; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  [(_color ?: SecondaryText()) setFill];
  [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(1, 3.5, 8, 8)] fill];
}
@end

#pragma mark - Primary button (accent fill, ink chosen for contrast)

// The system accent can be any color (yellow, graphite, ...) and AppKit's tinted-button title color does not always read on it,
// and goes grey when the window is inactive. This button draws its own capsule so the title always has at least 4.5:1.
@interface T4LPrimaryButton : NSButton
@end

@implementation T4LPrimaryButton
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.bordered = NO;
  self.bezelStyle = NSBezelStyleRounded;
  [self setButtonType:NSButtonTypeMomentaryPushIn];
  self.focusRingType = NSFocusRingTypeDefault;
  return self;
}

- (NSSize)intrinsicContentSize {
  NSDictionary *attrs = @{NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]};
  return NSMakeSize(ceil([self.title sizeWithAttributes:attrs].width) + 40, 36);
}

- (void)setEnabled:(BOOL)enabled { [super setEnabled:enabled]; [self setNeedsDisplay:YES]; }
- (void)setTitle:(NSString *)title { [super setTitle:title]; [self invalidateIntrinsicContentSize]; [self setNeedsDisplay:YES]; }

- (NSBezierPath *)capsule {
  NSRect r = NSInsetRect(self.bounds, 1, 1);
  return [NSBezierPath bezierPathWithRoundedRect:r xRadius:NSHeight(r) / 2 yRadius:NSHeight(r) / 2];
}

- (void)drawFocusRingMask { [[self capsule] fill]; }
- (NSRect)focusRingMaskBounds { return self.bounds; }

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  BOOL highlighted = [(NSButtonCell *)self.cell isHighlighted];
  NSColor *accent = [NSColor.controlAccentColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: NSColor.systemBlueColor;
  NSColor *fill, *ink;
  if (self.enabled) {
    fill = highlighted ? MixColors(accent, ReadableInk(accent), 0.22) : accent;
    ink = ReadableInk(fill);
  } else {
    fill = [NSColor.labelColor colorWithAlphaComponent:0.10];
    ink = [NSColor.labelColor colorWithAlphaComponent:0.5];
  }
  [fill setFill];
  [[self capsule] fill];
  NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
  ps.alignment = NSTextAlignmentCenter;
  NSDictionary *attrs = @{NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold],
                          NSForegroundColorAttributeName: ink, NSParagraphStyleAttributeName: ps};
  NSSize sz = [self.title sizeWithAttributes:attrs];
  [self.title drawInRect:NSMakeRect(0, round((NSHeight(self.bounds) - sz.height) / 2), NSWidth(self.bounds), sz.height) withAttributes:attrs];
}
@end

#pragma mark - App delegate

@interface Delegate : NSObject <NSApplicationDelegate, NSTabViewDelegate, NSMenuItemValidation, T4LColorRowOwner>
@property (strong) NSWindow *win;
@property (strong) NSTabView *tabs;
// theme state
@property (strong) T4LThemeState *state;
@property (copy) NSString *loadedSlug;
@property (strong) NSMutableDictionary<NSString *, NSDictionary *> *presetThemes;   // slug -> bundled theme
@property (strong) NSMutableDictionary<NSString *, NSDictionary *> *customStore;    // slug -> persisted customizations
@property (strong) T4LThemeState *referenceState;                                    // fallback values for roles a theme lacks
// presets tab
@property (strong) PresetsListView *presetsList;
@property (strong) NSMutableArray<PresetCard *> *presetCards;
// customize tab
@property (strong) FlippedDocView *customizeRoot;
@property (strong) FlippedDocView *customizeDoc;
@property (strong) WindowMockView *previewMock;
@property (strong) NSTextField *themeTitleLabel;
@property (strong) NSTextField *themeSubLabel;
@property (strong) NSButton *resetButton;
@property (strong) NSButton *exportButton;
@property (strong) NSButton *importButton;
@property (strong) NSButton *autoCheckbox;
@property (strong) NSMutableDictionary<NSString *, T4LColorRow *> *rows;
@property (strong) NSMutableArray<NSScrollView *> *scrollViews;
// launch area
@property (strong) NSTextField *status;
@property (strong) NSTextField *logicLabel;
@property (strong) T4LDotView *logicDot;
@property (strong) NSTextField *projectLabel;
@property (strong) NSButton *openProjectButton;
@property (strong) NSButton *clearProjectButton;
@property (strong) NSButton *launchButton;
@property (strong) NSButton *plainLaunchButton;
@property (copy) NSString *projectPath;
@property (strong) NSDictionary *logicInfo;
@property (nonatomic) BOOL launching;
- (void)loadPresetSlug:(NSString *)slug announce:(BOOL)announce;
@end

@implementation Delegate

#pragma mark Theme loading

- (NSDictionary *)loadBundledThemeNamed:(NSString *)slug {
  NSString *dir = ThemesBundleDir();
  if (!dir || slug.length == 0 || [slug containsString:@"/"] || [slug containsString:@".."]) return nil;
  NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", slug]];
  NSData *d = [NSData dataWithContentsOfFile:path];
  if (!d) return nil;
  id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  return [j isKindOfClass:[NSDictionary class]] && [j[@"colors"] isKindOfClass:[NSDictionary class]] ? j : nil;
}

- (NSDictionary *)themeOnDisk {
  NSData *data = [NSData dataWithContentsOfFile:[SupportDir() stringByAppendingPathComponent:@"theme.json"]];
  id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  return [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
}

- (NSString *)displayName {
  NSDictionary *meta = PresetMeta(self.loadedSlug);
  if (meta) return meta[@"title"];
  NSString *n = self.state.base[@"name"];
  return [n isKindOfClass:[NSString class]] && n.length ? n : @"Imported theme";
}

- (BOOL)slugIsImported { return [self.loadedSlug isEqualToString:kImportedSlug]; }

#pragma mark Persistence

- (void)scheduleSave {
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushSave) object:nil];
  [self performSelector:@selector(flushSave) withObject:nil afterDelay:0.4];
}

- (void)flushSave {
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushSave) object:nil];
  if (!self.loadedSlug || !self.state) return;
  NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
  if (self.state.changeCount > 0) self.customStore[self.loadedSlug] = [self.state persistable];
  else [self.customStore removeObjectForKey:self.loadedSlug];
  [ud setObject:[self.customStore copy] forKey:kCustomizationsKey];
  [ud setObject:self.loadedSlug forKey:kLastPresetSlugKey];
  if ([self slugIsImported]) {
    NSDictionary *safe = PlistSafeCopy(self.state.base, 0);
    if (safe) [ud setObject:safe forKey:kImportedThemeKey];
  }
}

- (void)loadStoredState {
  self.presetThemes = [NSMutableDictionary dictionary];
  for (NSDictionary *p in BundledPresets()) {
    NSDictionary *t = [self loadBundledThemeNamed:p[@"slug"]];
    if (t) self.presetThemes[p[@"slug"]] = t;
  }
  self.customStore = [NSMutableDictionary dictionary];
  NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kCustomizationsKey];
  for (id k in stored)
    if ([k isKindOfClass:[NSString class]] && [stored[k] isKindOfClass:[NSDictionary class]]) self.customStore[k] = stored[k];
  NSDictionary *refTheme = self.presetThemes[@"midnight"] ?: self.presetThemes.allValues.firstObject ?: @{};
  self.referenceState = [[T4LThemeState alloc] initWithBase:refTheme];
  NSString *path = [[NSUserDefaults standardUserDefaults] stringForKey:kProjectPathKey];
  self.projectPath = ValidProjectURL(path) ? path : nil;
}

#pragma mark Selecting / activating themes

- (void)activateBase:(NSDictionary *)base slug:(NSString *)slug {
  [self flushSave];
  self.loadedSlug = slug;
  self.state = [[T4LThemeState alloc] initWithBase:base];
  [self.state loadPersisted:self.customStore[slug]];
  [[NSUserDefaults standardUserDefaults] setObject:slug forKey:kLastPresetSlugKey];
  if ([slug isEqualToString:kImportedSlug]) [self flushSave];
  for (T4LColorRow *row in self.rows.allValues) [row.well deactivate];
  [self refreshAllUI];
}

- (void)loadPresetSlug:(NSString *)slug announce:(BOOL)announce {
  NSDictionary *theme = self.presetThemes[slug];
  if (!theme) {
    [self setStatus:[NSString stringWithFormat:@"Preset not found: %@", slug] isError:YES];
    return;
  }
  [self activateBase:theme slug:slug];
  if (announce) {
    NSUInteger n = self.state.changeCount;
    NSString *extra = n ? [NSString stringWithFormat:@" with your %lu saved change%@", (unsigned long)n, n == 1 ? @"" : @"s"] : @"";
    [self setStatus:[NSString stringWithFormat:@"Loaded “%@”%@. Press Apply & Launch when ready.", [self displayName], extra] isError:NO];
  }
}

- (void)selectPresetAtOffset:(NSInteger)offset {
  NSArray<NSDictionary *> *presets = BundledPresets();
  NSInteger idx = -1;
  for (NSUInteger i = 0; i < presets.count; i++)
    if ([presets[i][@"slug"] isEqualToString:self.loadedSlug]) idx = (NSInteger)i;
  NSInteger next = idx < 0 ? (offset > 0 ? 0 : (NSInteger)presets.count - 1)
                           : ((idx + offset) % (NSInteger)presets.count + (NSInteger)presets.count) % (NSInteger)presets.count;
  [self loadPresetSlug:presets[next][@"slug"] announce:YES];
}

- (void)nextPreset:(id)sender { (void)sender; [self selectPresetAtOffset:1]; }
- (void)previousPreset:(id)sender { (void)sender; [self selectPresetAtOffset:-1]; }

- (void)restoreInitialSelection {
  NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
  NSString *saved = [ud stringForKey:kLastPresetSlugKey];
  if (saved.length) {
    if ([saved isEqualToString:kImportedSlug]) {
      NSDictionary *imported = SanitizeImportedTheme([ud dictionaryForKey:kImportedThemeKey], NULL);
      if (imported) { [self activateBase:imported slug:kImportedSlug]; return; }
    } else if (self.presetThemes[saved]) {
      [self activateBase:self.presetThemes[saved] slug:saved];
      return;
    }
  }
  // First run: follow whatever theme Logic was last launched with, when it is one we recognise.
  NSDictionary *disk = SanitizeImportedTheme([self themeOnDisk], NULL);
  if (disk) {
    NSString *name = disk[@"name"];
    if ([name hasSuffix:@" (customized)"]) name = [name substringToIndex:name.length - 13];
    for (NSDictionary *p in BundledPresets()) {
      if ([p[@"title"] caseInsensitiveCompare:name] == NSOrderedSame && self.presetThemes[p[@"slug"]]) {
        [self activateBase:self.presetThemes[p[@"slug"]] slug:p[@"slug"]];
        [self setStatus:[NSString stringWithFormat:@"Showing “%@”, the theme Logic was last launched with.", p[@"title"]] isError:NO];
        return;
      }
    }
    [self activateBase:disk slug:kImportedSlug];
    [self setStatus:@"Restored your last applied theme." isError:NO];
    return;
  }
  NSString *first = self.presetThemes[@"midnight"] ? @"midnight" : (self.presetThemes.allKeys.firstObject ?: @"midnight");
  if (self.presetThemes[first]) [self loadPresetSlug:first announce:NO];
}

#pragma mark Refreshing the UI from state

- (T4LMockPalette *)paletteForPresetSlug:(NSString *)slug {
  if ([slug isEqualToString:self.loadedSlug] && self.state) return PaletteFromTheme([self.state mergedTheme]);
  NSDictionary *theme = self.presetThemes[slug];
  if (!theme) {
    NSString *accent = PresetMeta(slug)[@"accent"] ?: @"#808080";
    return PaletteFromTheme(@{@"colors": @{kAccentRoleID: accent}});
  }
  T4LThemeState *st = [[T4LThemeState alloc] initWithBase:theme];
  [st loadPersisted:self.customStore[slug]];
  return PaletteFromTheme([st mergedTheme]);
}

- (NSString *)fallbackHexForRole:(NSString *)rid {
  return [self.referenceState baseHexForRole:rid] ?: @"#808080";
}

- (void)refreshRowsExcept:(T4LColorRow *)skip {
  NSUInteger regionCount = self.state.regionCount;
  for (NSString *rid in self.rows) {
    T4LColorRow *row = self.rows[rid];
    NSInteger ri = RoleRegionIndex(rid);
    row.hidden = ri >= 0 && (NSUInteger)ri >= regionCount;
    BOOL modified = [self.state roleIsModified:rid];
    if (row == skip) { row.modified = modified; continue; }
    NSString *eff = [self.state effectiveHexForRole:rid];
    [row showHex:eff ?: [self fallbackHexForRole:rid] isSet:eff != nil modified:modified];
  }
}

- (void)refreshSummary {
  NSUInteger n = self.state.changeCount;
  BOOL imported = [self slugIsImported];
  self.themeTitleLabel.stringValue = [self displayName];
  NSString *kind = imported ? @"Imported theme" : @"Preset";
  self.themeSubLabel.stringValue = n == 0 ? [NSString stringWithFormat:@"%@ · no changes yet", kind]
                                          : [NSString stringWithFormat:@"%@ · %lu change%@", kind, (unsigned long)n, n == 1 ? @"" : @"s"];
  self.resetButton.title = imported ? @"Reset to import" : @"Reset to preset";
  self.resetButton.enabled = n > 0;
  self.autoCheckbox.state = self.state.autoEnabled ? NSControlStateValueOn : NSControlStateValueOff;
  [self.customizeRoot relayout];
}

- (void)refreshPreview {
  NSDictionary *merged = [self.state mergedTheme];
  self.previewMock.palette = PaletteFromTheme(merged);
  self.previewMock.themeName = [self displayName];
  PresetCard *current = nil;
  for (PresetCard *c in self.presetCards) if ([c.slug isEqualToString:self.loadedSlug]) current = c;
  if (current) current.mock.palette = self.previewMock.palette;
}

- (void)updatePresetSelectionUI {
  for (PresetCard *card in self.presetCards) {
    BOOL isCurrent = [card.slug isEqualToString:self.loadedSlug];
    card.selected = isCurrent;
    card.customized = isCurrent ? self.state.changeCount > 0 : [self.customStore[card.slug][@"overrides"] count] > 0 || self.customStore[card.slug][@"auto"] != nil;
  }
  NSUInteger n = self.state.changeCount;
  NSString *name = [self displayName];
  NSString *text = n ? [NSString stringWithFormat:@"%@ — %lu change%@", name, (unsigned long)n, n == 1 ? @"" : @"s"] : name;
  NSString *prefix = [self slugIsImported] ? @"Imported: " : @"Using ";
  NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:prefix
      attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:13], NSForegroundColorAttributeName: SecondaryText()}];
  [as appendAttributedString:[[NSAttributedString alloc] initWithString:text
      attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.labelColor}]];
  self.presetsList.currentLabel.attributedStringValue = as;
  self.presetsList.currentLabel.toolTip = text;
}

- (void)refreshAllUI {
  [self refreshRowsExcept:nil];
  [self refreshPreview];
  [self updatePresetSelectionUI];
  [self refreshSummary];
  [self.customizeDoc relayout];
}

#pragma mark Edits from the Customize tab

- (void)colorRow:(T4LColorRow *)row didChangeHex:(NSString *)hex {
  [self.state setHex:hex forRole:row.roleId];
  [self refreshRowsExcept:row];
  [self refreshPreview];
  [self updatePresetSelectionUI];
  [self refreshSummary];
  [self scheduleSave];
  [self setStatus:[NSString stringWithFormat:@"Customized “%@”. Press Apply & Launch to use it in Logic.", [self displayName]] isError:NO];
}

- (void)colorRow:(T4LColorRow *)row rejectedInput:(NSString *)text {
  (void)row;
  [self setStatus:[NSString stringWithFormat:@"“%@” isn’t a valid color. Use a hex value like #1a1d2e.", text] isError:YES];
}

- (void)toggleAuto:(id)sender {
  BOOL on = [sender isKindOfClass:[NSButton class]] ? ((NSButton *)sender).state == NSControlStateValueOn : !self.state.autoEnabled;
  self.state.autoOverride = on == self.state.baseAutoEnabled ? nil : @(on);
  [self refreshAllUI];
  [self scheduleSave];
  [self setStatus:on ? @"Auto-recolor is on: colors the theme doesn’t name are remapped to match."
                     : @"Auto-recolor is off: only the colors the theme names are changed; everything else stays stock."
            isError:NO];
}

- (void)resetToPreset:(id)sender {
  (void)sender;
  if (self.state.changeCount == 0) return;
  [self.state resetAll];
  [self refreshAllUI];
  [self flushSave];
  [self setStatus:[NSString stringWithFormat:@"Reset to “%@”.", [self displayName]] isError:NO];
}

#pragma mark Import / export

- (BOOL)exportThemeToURL:(NSURL *)url error:(NSString **)outError {
  if (![url isFileURL]) {
    if (outError) *outError = @"Choose a location on this Mac.";
    return NO;
  }
  NSMutableDictionary *out = [[self mergedThemeForLaunch] mutableCopy];
  out[@"_note"] = @"Exported from Theme4Logic. Import it from the Customize tab.";
  NSError *err = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:out
                                                 options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes)
                                                   error:&err];
  if (!data || ![data writeToURL:url options:NSDataWritingAtomic error:&err]) {
    if (outError) *outError = err.localizedDescription ?: @"Could not write the file.";
    return NO;
  }
  return YES;
}

- (BOOL)importThemeFromURL:(NSURL *)url error:(NSString **)outError {
  NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil];
  if ([attrs[NSFileSize] unsignedLongLongValue] > 4 * 1024 * 1024) {
    if (outError) *outError = @"That file is too large to be a theme.";
    return NO;
  }
  NSData *data = [NSData dataWithContentsOfURL:url options:0 error:nil];
  id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (!parsed) {
    if (outError) *outError = @"The file isn’t valid JSON.";
    return NO;
  }
  NSString *reason = nil;
  NSDictionary *theme = SanitizeImportedTheme(parsed, &reason);
  if (!theme) {
    if (outError) *outError = reason ?: @"The file isn’t a Theme4Logic theme.";
    return NO;
  }
  [self flushSave];                                 // keep whatever was being edited
  [self.customStore removeObjectForKey:kImportedSlug];
  self.loadedSlug = nil;                            // so activateBase does not write the old state back under "custom"
  [self activateBase:theme slug:kImportedSlug];
  return YES;
}

- (void)exportTheme:(id)sender {
  (void)sender;
  NSSavePanel *panel = [NSSavePanel savePanel];
  panel.title = @"Export Theme";
  panel.prompt = @"Export";
  panel.canCreateDirectories = YES;
  NSString *base = [[self displayName] stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  panel.allowedFileTypes = @[ @"json" ];
#pragma clang diagnostic pop
  panel.nameFieldStringValue = [base stringByAppendingString:(self.state.changeCount ? @" (customized).json" : @".json")];
  __weak Delegate *weakSelf = self;
  [panel beginSheetModalForWindow:self.win completionHandler:^(NSModalResponse result) {
    if (result != NSModalResponseOK || !panel.URL) return;
    NSURL *url = panel.URL;
    if (![url.pathExtension.lowercaseString isEqualToString:@"json"]) url = [url URLByAppendingPathExtension:@"json"];
    NSString *err = nil;
    if ([weakSelf exportThemeToURL:url error:&err])
      [weakSelf setStatus:[NSString stringWithFormat:@"Exported “%@” to %@.", [weakSelf displayName], url.lastPathComponent] isError:NO];
    else
      [weakSelf setStatus:[NSString stringWithFormat:@"Export failed: %@", err] isError:YES];
  }];
}

- (void)importTheme:(id)sender {
  (void)sender;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.title = @"Import Theme";
  panel.prompt = @"Import";
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  panel.allowedFileTypes = @[ @"json" ];
#pragma clang diagnostic pop
  __weak Delegate *weakSelf = self;
  [panel beginSheetModalForWindow:self.win completionHandler:^(NSModalResponse result) {
    if (result != NSModalResponseOK || !panel.URL) return;
    NSString *err = nil;
    if ([weakSelf importThemeFromURL:panel.URL error:&err])
      [weakSelf setStatus:[NSString stringWithFormat:@"Imported “%@”. Press Apply & Launch when ready.", [weakSelf displayName]] isError:NO];
    else
      [weakSelf setStatus:[NSString stringWithFormat:@"Import failed: %@", err] isError:YES];
  }];
}

#pragma mark Status + Logic area

- (void)setStatus:(NSString *)text isError:(BOOL)isError {
  self.status.stringValue = text ?: @"";
  self.status.textColor = isError ? ErrorText() : SecondaryText();
}

- (void)updateLaunchControls {
  BOOL found = [self.logicInfo[@"found"] boolValue], supported = [self.logicInfo[@"supported"] boolValue];
  self.launchButton.enabled = supported && !self.launching;
  self.plainLaunchButton.enabled = found && !self.launching;
  self.openProjectButton.enabled = !self.launching;
  self.clearProjectButton.enabled = !self.launching;
}

- (void)refreshLogicStatus {
  NSDictionary *info = DetectLogicSupport();
  self.logicInfo = info;
  BOOL found = [info[@"found"] boolValue], supported = [info[@"supported"] boolValue];
  NSString *msg = info[@"message"];
  if (found && LogicIsRunning())
    msg = [msg stringByAppendingString:supported ? @" Running now; Apply restarts it." : @" Running now."];
  self.logicLabel.stringValue = msg;
  NSInteger level = [info[@"level"] integerValue];
  self.logicDot.color = level == 0 ? NSColor.systemGreenColor : (level == 1 ? NSColor.systemOrangeColor : NSColor.systemRedColor);
  [self updateLaunchControls];
}

- (void)refreshProjectRow {
  NSURL *url = ValidProjectURL(self.projectPath);
  if (!url) self.projectPath = nil;
  self.projectLabel.stringValue = url ? url.lastPathComponent : @"None (optional)";
  self.projectLabel.textColor = url ? NSColor.labelColor : SecondaryText();
  self.projectLabel.toolTip = url ? url.path : @"Choose a Logic project to open automatically after launch";
  self.clearProjectButton.hidden = url == nil;
}

- (void)chooseProject:(id)sender {
  (void)sender;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.title = @"Open Logic Project";
  panel.prompt = @"Choose";
  panel.message = @"Pick a Logic project to open when Theme4Logic launches Logic Pro.";
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = YES;
  panel.allowsMultipleSelection = NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  panel.allowedFileTypes = @[ @"logicx" ];
#pragma clang diagnostic pop
  __weak Delegate *weakSelf = self;
  [panel beginSheetModalForWindow:self.win completionHandler:^(NSModalResponse result) {
    if (result != NSModalResponseOK || !panel.URL) return;
    Delegate *strongSelf = weakSelf;
    if (!ValidProjectURL(panel.URL.path)) {
      [strongSelf setStatus:@"That isn’t a Logic project (.logicx)." isError:YES];
      return;
    }
    strongSelf.projectPath = panel.URL.path;
    [[NSUserDefaults standardUserDefaults] setObject:strongSelf.projectPath forKey:kProjectPathKey];
    [strongSelf refreshProjectRow];
    [strongSelf setStatus:[NSString stringWithFormat:@"“%@” will open in Logic after launch.", panel.URL.lastPathComponent] isError:NO];
  }];
}

- (void)clearProject:(id)sender {
  (void)sender;
  self.projectPath = nil;
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:kProjectPathKey];
  [self refreshProjectRow];
  [self setStatus:@"Logic will start without opening a project." isError:NO];
}

#pragma mark View construction

- (NSScrollView *)makeScrollView:(NSView *)document {
  ThemeScrollView *scroll = [[ThemeScrollView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
  scroll.hasVerticalScroller = YES;
  scroll.autohidesScrollers = YES;
  scroll.drawsBackground = NO;
  scroll.borderType = NSNoBorder;
  scroll.documentView = document;
  scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self.scrollViews addObject:scroll];
  [scroll syncDocumentWidth];
  return scroll;
}

- (void)syncAllScrollWidths {
  for (NSScrollView *s in self.scrollViews)
    if ([s isKindOfClass:[ThemeScrollView class]]) [(ThemeScrollView *)s syncDocumentWidth];
}

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)tabViewItem {
  (void)tabViewItem;
  [self syncAllScrollWidths];
  NSInteger idx = [tabView indexOfTabViewItem:tabView.selectedTabViewItem];
  if (idx != NSNotFound) [[NSUserDefaults standardUserDefaults] setInteger:idx forKey:kLastTabKey];
}

- (NSView *)buildPresetsTab {
  PresetsListView *list = [[PresetsListView alloc] initWithFrame:NSMakeRect(0, 0, 560, 100)];
  list.autoHeight = YES;
  self.presetsList = list;
  self.presetCards = [NSMutableArray array];

  list.currentLabel = Label(@"", [NSFont systemFontOfSize:13], NSColor.labelColor);
  list.customizeButton = [NSButton buttonWithTitle:@"Customize…" target:self action:@selector(showCustomizeTab:)];
  list.customizeButton.controlSize = NSControlSizeSmall;
  list.customizeButton.bezelStyle = NSBezelStyleRounded;
  list.customizeButton.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  list.customizeButton.toolTip = @"Fine-tune this theme’s colors";
  [list addSubview:list.currentLabel];
  [list addSubview:list.customizeButton];

  NSMutableArray<NSString *> *order = [NSMutableArray array];
  NSMutableDictionary<NSString *, NSMutableArray<PresetCard *> *> *byCategory = [NSMutableDictionary dictionary];
  __weak Delegate *weakSelf = self;
  for (NSDictionary *p in BundledPresets()) {
    NSString *cat = p[@"category"];
    if (!byCategory[cat]) { byCategory[cat] = [NSMutableArray array]; [order addObject:cat]; }
    PresetCard *card = [[PresetCard alloc] initWithPreset:p palette:[self paletteForPresetSlug:p[@"slug"]]];
    card.onSelect = ^(NSString *slug) { [weakSelf loadPresetSlug:slug announce:YES]; };
    [byCategory[cat] addObject:card];
    [self.presetCards addObject:card];
  }
  list.groups = [NSMutableArray array];
  for (NSString *cat in order) {
    NSTextField *hdr = SectionHeaderLabel(cat);
    [list addSubview:hdr];
    for (PresetCard *c in byCategory[cat]) [list addSubview:c];
    [list.groups addObject:@{@"header": hdr, @"cards": byCategory[cat]}];
  }
  __weak PresetsListView *weakList = list;
  list.layoutBlock = ^CGFloat(NSSize size) { return [weakList layoutForWidth:size.width]; };
  return list;
}

- (NSView *)buildCustomizeTab {
  FlippedDocView *root = [[FlippedDocView alloc] initWithFrame:NSMakeRect(0, 0, 560, 500)];
  self.customizeRoot = root;

  self.previewMock = [[WindowMockView alloc] initWithFrame:NSZeroRect];
  self.themeTitleLabel = Label(@"", [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold], NSColor.labelColor);
  self.themeSubLabel = Label(@"", [NSFont systemFontOfSize:12], SecondaryText());
  self.resetButton = [NSButton buttonWithTitle:@"Reset to preset" target:self action:@selector(resetToPreset:)];
  self.exportButton = [NSButton buttonWithTitle:@"Export theme…" target:self action:@selector(exportTheme:)];
  self.importButton = [NSButton buttonWithTitle:@"Import theme…" target:self action:@selector(importTheme:)];
  self.autoCheckbox = [NSButton checkboxWithTitle:@"Auto-recolor everything else" target:self action:@selector(toggleAuto:)];
  self.autoCheckbox.toolTip = @"Remaps every color the theme doesn’t name (for example in dialogs and plug-in windows) to the theme’s palette, so nothing stays stock.";
  NSTextField *autoHelp = WrapLabel(@"Remaps colors the theme doesn’t name.",
                                    [NSFont systemFontOfSize:11], SecondaryText());
  for (NSButton *b in @[ self.resetButton, self.exportButton, self.importButton ]) {
    b.bezelStyle = NSBezelStyleRounded;
    b.controlSize = NSControlSizeSmall;
    b.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  }
  self.autoCheckbox.font = [NSFont systemFontOfSize:12];
  self.exportButton.toolTip = @"Save this theme as a .json file you can share or import later";
  self.importButton.toolTip = @"Load a theme .json file (same format as the built-in presets)";

  // Scrolling list of color rows.
  self.rows = [NSMutableDictionary dictionary];
  FlippedDocView *doc = [[FlippedDocView alloc] initWithFrame:NSMakeRect(0, 0, 560, 100)];
  doc.autoHeight = YES;
  self.customizeDoc = doc;
  NSMutableArray<NSDictionary *> *layoutItems = [NSMutableArray array];  // { kind: header|row, view, line?, regions? }
  for (NSDictionary *sec in RoleSections()) {
    NSTextField *hdr = SectionHeaderLabel(sec[@"name"]);
    NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 100, 1)];
    line.boxType = NSBoxSeparator;
    [doc addSubview:hdr];
    [doc addSubview:line];
    [layoutItems addObject:@{@"kind": @"header", @"view": hdr, @"line": line}];
    BOOL regions = [sec[@"isRegions"] boolValue];
    for (NSDictionary *r in sec[@"roles"]) {
      T4LColorRow *row = [[T4LColorRow alloc] initWithRole:r[@"id"] label:r[@"label"] owner:self];
      self.rows[r[@"id"]] = row;
      [doc addSubview:row];
      [layoutItems addObject:@{@"kind": regions ? @"region" : @"row", @"view": row}];
    }
  }
  doc.layoutBlock = ^CGFloat(NSSize size) {
    const CGFloat inset = 16, rowH = 30, gap = 18;
    CGFloat w = size.width, inner = MAX(180, w - 2 * inset);
    CGFloat y = 8;
    NSInteger regionCols = inner >= 600 ? 3 : (inner >= 430 ? 2 : 1);
    CGFloat colW = floor((inner - (regionCols - 1) * 16) / regionCols);
    NSInteger regionIndex = 0;
    BOOL inRegionRun = NO;
    for (NSDictionary *item in layoutItems) {
      NSView *v = item[@"view"];
      NSString *kind = item[@"kind"];
      if (![kind isEqualToString:@"region"] && inRegionRun) {  // close a partly filled line of regions
        if (regionIndex % regionCols != 0) y += rowH;
        inRegionRun = NO;
      }
      if ([kind isEqualToString:@"header"]) {
        if (y > 8) y += gap - 6;
        v.frame = NSMakeRect(inset + 2, y, inner, 14);
        NSView *line = item[@"line"];
        line.frame = NSMakeRect(inset, y + 18, inner, 1);
        y += 24;
        regionIndex = 0;
      } else if ([kind isEqualToString:@"row"]) {
        v.frame = NSMakeRect(inset, y, inner, rowH);
        y += rowH;
      } else if (!v.hidden) {
        NSInteger col = regionIndex % regionCols;
        v.frame = NSMakeRect(inset + col * (colW + 16), y, colW, rowH);
        regionIndex++;
        inRegionRun = YES;
        if (col == regionCols - 1) y += rowH;
      }
    }
    if (inRegionRun && regionIndex % regionCols != 0) y += rowH;
    return y + 16;
  };
  ThemeScrollView *scroll = (ThemeScrollView *)[self makeScrollView:doc];
  scroll.autoresizingMask = NSViewNotSizable;
  NSBox *rule = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 100, 1)];
  rule.boxType = NSBoxSeparator;

  for (NSView *v in @[ self.previewMock, self.themeTitleLabel, self.themeSubLabel, self.resetButton, self.exportButton,
                       self.importButton, self.autoCheckbox, autoHelp, rule, scroll ])
    [root addSubview:v];

  __weak Delegate *weakSelf = self;
  root.layoutBlock = ^CGFloat(NSSize size) {
    Delegate *s = weakSelf;
    if (!s) return 0;
    const CGFloat pad = 12, gap = 16;
    CGFloat w = size.width, h = size.height;
    CGFloat ph = MIN(150.0, MAX(100.0, h * 0.3)), pw = round(ph * 1.6);
    CGFloat maxPw = round((w - 2 * pad - gap) * 0.5);
    if (pw > maxPw) { pw = maxPw; ph = round(pw / 1.6); }
    s.previewMock.frame = NSMakeRect(pad, pad, pw, ph);
    CGFloat rx = pad + pw + gap, rw = MAX(120, w - rx - pad), y = pad;
    s.themeTitleLabel.frame = NSMakeRect(rx, y, rw, 20);
    y += 21;
    s.themeSubLabel.frame = NSMakeRect(rx, y, rw, 16);
    y += 24;
    CGFloat rb = [s.resetButton fittingSize].width, eb = [s.exportButton fittingSize].width, ib = [s.importButton fittingSize].width;
    s.resetButton.frame = NSMakeRect(rx, y, MIN(rw, rb), 22);
    y += 27;
    if (eb + ib + 8 <= rw) {
      s.exportButton.frame = NSMakeRect(rx, y, eb, 22);
      s.importButton.frame = NSMakeRect(rx + eb + 8, y, ib, 22);
      y += 27;
    } else {
      s.exportButton.frame = NSMakeRect(rx, y, MIN(rw, eb), 22);
      y += 26;
      s.importButton.frame = NSMakeRect(rx, y, MIN(rw, ib), 22);
      y += 27;
    }
    s.autoCheckbox.frame = NSMakeRect(rx, y, rw, 18);
    y += 19;
    autoHelp.frame = NSMakeRect(rx + 18, y, MAX(60, rw - 18), WrappedHeight(autoHelp, MAX(60, rw - 18)));
    y = MAX(pad + ph, NSMaxY(autoHelp.frame)) + 10;
    rule.frame = NSMakeRect(0, y, w, 1);
    y += 1;
    scroll.frame = NSMakeRect(0, y, w, MAX(0, h - y));
    return h;
  };
  return root;
}

- (NSView *)buildAboutTab {
  FlippedDocView *doc = [[FlippedDocView alloc] initWithFrame:NSMakeRect(0, 0, 560, 100)];
  doc.autoHeight = YES;
  NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
  NSFont *body = [NSFont systemFontOfSize:12];
  void (^add)(NSView *, CGFloat) = ^(NSView *v, CGFloat gapBefore) {
    [doc addSubview:v];
    [items addObject:@{@"view": v, @"gap": @(gapBefore)}];
  };
  add(WrapLabel(@"Recolor Logic Pro without touching it.", [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor), 0);
  add(WrapLabel(@"Theme4Logic restyles the Logic Pro interface each time you start Logic from this app. A small color engine is loaded "
                @"into Logic as it launches and swaps colors in memory. Logic Pro is never modified: it is not edited on disk, not "
                @"re-signed, and it opens with its normal look when you start it any other way.", body, NSColor.labelColor), 6);

  add(SectionHeaderLabel(@"How it works"), 16);
  for (NSString *s in @[
    @"1. Pick a preset on the Presets tab, or fine-tune it on Customize.",
    @"2. Press Apply & Launch Logic Pro. Theme4Logic saves your theme and starts Logic with the engine.",
    @"3. Theme4Logic checks that the engine loaded and tells you if it didn’t.",
    @"4. To switch themes, choose another one and launch again. Logic restarts each time.",
  ]) add(WrapLabel(s, body, NSColor.labelColor), 4);

  add(SectionHeaderLabel(@"Safety"), 16);
  add(WrapLabel(@"The engine only activates for Logic versions this build has verified. On any other version it disables itself, and the "
                @"launch area tells you why. “Launch Logic without theme” always starts Logic with its stock look.", body, NSColor.labelColor), 4);

  add(SectionHeaderLabel(@"Where files live"), 16);
  add(WrapLabel(@"~/Library/Application Support/Theme4Logic/ holds your current theme (theme.json), the color engine (colorize.dylib) and "
                @"its safety manifests (hook-manifests). Your per-preset customizations are kept in this app’s preferences.",
                body, NSColor.labelColor), 4);
  NSButton *folder = [NSButton buttonWithTitle:@"Show Folder in Finder" target:self action:@selector(openSupportFolder:)];
  folder.bezelStyle = NSBezelStyleRounded;
  folder.controlSize = NSControlSizeSmall;
  add(folder, 8);

  add(SectionHeaderLabel(@"Uninstall"), 16);
  add(WrapLabel(@"Quit Logic, delete Theme4Logic, then delete the Application Support folder above. Nothing else is installed, and "
                @"Logic Pro needs no repair.", body, NSColor.labelColor), 4);

  add(SectionHeaderLabel(@"License"), 16);
  add(WrapLabel(@"Free and open source (MIT).", body, NSColor.labelColor), 4);
  NSButton *repo = [NSButton buttonWithTitle:kRepoURLString target:self action:@selector(openRepo:)];
  repo.bordered = NO;
  repo.attributedTitle = [[NSAttributedString alloc] initWithString:kRepoURLString attributes:@{
    NSFontAttributeName: body, NSForegroundColorAttributeName: NSColor.linkColor,
    NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)}];
  repo.alignment = NSTextAlignmentLeft;
  repo.accessibilityLabel = @"Open the Theme4Logic project page";
  add(repo, 4);

  NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"1.0";
  add(WrapLabel([NSString stringWithFormat:@"Theme4Logic %@", version], [NSFont systemFontOfSize:11], SecondaryText()), 16);

  doc.layoutBlock = ^CGFloat(NSSize size) {
    const CGFloat inset = 16;
    CGFloat inner = MAX(180, size.width - 2 * inset), y = 14;
    for (NSDictionary *item in items) {
      NSView *v = item[@"view"];
      y += [item[@"gap"] doubleValue];
      CGFloat h;
      if ([v isKindOfClass:[NSTextField class]]) h = WrappedHeight((NSTextField *)v, inner);
      else if ([v isKindOfClass:[NSButton class]]) h = [(NSButton *)v isBordered] ? 22 : 18;
      else h = 18;
      CGFloat w = inner;
      if ([v isKindOfClass:[NSButton class]] && [(NSButton *)v isBordered]) w = MIN(inner, [(NSButton *)v fittingSize].width);
      else if ([v isKindOfClass:[NSButton class]]) w = MIN(inner, [(NSButton *)v attributedTitle].size.width + 8);
      v.frame = NSMakeRect(inset, y, w, h);
      y += h;
    }
    return y + 18;
  };
  return doc;
}

#pragma mark Menus

- (NSMenuItem *)addItemTo:(NSMenu *)menu title:(NSString *)title action:(SEL)action key:(NSString *)key
                modifiers:(NSEventModifierFlags)mods target:(id)target {
  NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:key];
  item.keyEquivalentModifierMask = mods;
  item.target = target;
  return item;
}

- (void)buildMenu {
  NSMenu *mainMenu = [[NSMenu alloc] init];
  const NSEventModifierFlags cmd = NSEventModifierFlagCommand, shift = NSEventModifierFlagShift, opt = NSEventModifierFlagOption;

  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Theme4Logic"];
  [self addItemTo:appMenu title:@"About Theme4Logic" action:@selector(showAbout:) key:@"" modifiers:0 target:self];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [self addItemTo:appMenu title:@"Show Theme Folder in Finder" action:@selector(openSupportFolder:) key:@"o" modifiers:cmd | shift target:self];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [self addItemTo:appMenu title:@"Hide Theme4Logic" action:@selector(hide:) key:@"h" modifiers:cmd target:NSApp];
  [self addItemTo:appMenu title:@"Hide Others" action:@selector(hideOtherApplications:) key:@"h" modifiers:cmd | opt target:NSApp];
  [self addItemTo:appMenu title:@"Show All" action:@selector(unhideAllApplications:) key:@"" modifiers:0 target:NSApp];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [self addItemTo:appMenu title:@"Quit Theme4Logic" action:@selector(terminate:) key:@"q" modifiers:cmd target:NSApp];
  NSMenuItem *appItem = [[NSMenuItem alloc] init];
  appItem.submenu = appMenu;
  [mainMenu addItem:appItem];

  NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
  [self addItemTo:fileMenu title:@"Open Logic Project…" action:@selector(chooseProject:) key:@"o" modifiers:cmd target:self];
  [self addItemTo:fileMenu title:@"Don’t Open a Project" action:@selector(clearProject:) key:@"" modifiers:0 target:self];
  [fileMenu addItem:[NSMenuItem separatorItem]];
  [self addItemTo:fileMenu title:@"Import Theme…" action:@selector(importTheme:) key:@"i" modifiers:cmd | shift target:self];
  [self addItemTo:fileMenu title:@"Export Theme…" action:@selector(exportTheme:) key:@"e" modifiers:cmd | shift target:self];
  [fileMenu addItem:[NSMenuItem separatorItem]];
  [self addItemTo:fileMenu title:@"Close Window" action:@selector(performClose:) key:@"w" modifiers:cmd target:nil];
  NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
  fileItem.submenu = fileMenu;
  [mainMenu addItem:fileItem];

  NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
  [self addItemTo:editMenu title:@"Undo" action:@selector(undo:) key:@"z" modifiers:cmd target:nil];
  [self addItemTo:editMenu title:@"Redo" action:@selector(redo:) key:@"z" modifiers:cmd | shift target:nil];
  [editMenu addItem:[NSMenuItem separatorItem]];
  [self addItemTo:editMenu title:@"Cut" action:@selector(cut:) key:@"x" modifiers:cmd target:nil];
  [self addItemTo:editMenu title:@"Copy" action:@selector(copy:) key:@"c" modifiers:cmd target:nil];
  [self addItemTo:editMenu title:@"Paste" action:@selector(paste:) key:@"v" modifiers:cmd target:nil];
  [self addItemTo:editMenu title:@"Select All" action:@selector(selectAll:) key:@"a" modifiers:cmd target:nil];
  NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
  editItem.submenu = editMenu;
  [mainMenu addItem:editItem];

  NSMenu *themeMenu = [[NSMenu alloc] initWithTitle:@"Theme"];
  [self addItemTo:themeMenu title:@"Apply & Launch Logic Pro" action:@selector(applyAndLaunch:) key:@"l" modifiers:cmd target:self];
  [self addItemTo:themeMenu title:@"Launch Logic Without Theme" action:@selector(launchWithoutTheme:) key:@"l" modifiers:cmd | opt target:self];
  [themeMenu addItem:[NSMenuItem separatorItem]];
  [self addItemTo:themeMenu title:@"Next Preset" action:@selector(nextPreset:) key:@"]" modifiers:cmd target:self];
  [self addItemTo:themeMenu title:@"Previous Preset" action:@selector(previousPreset:) key:@"[" modifiers:cmd target:self];
  [themeMenu addItem:[NSMenuItem separatorItem]];
  [self addItemTo:themeMenu title:@"Reset to Preset" action:@selector(resetToPreset:) key:@"r" modifiers:cmd target:self];
  [self addItemTo:themeMenu title:@"Auto-Recolor Everything Else" action:@selector(toggleAuto:) key:@"a" modifiers:cmd | opt target:self];
  NSMenuItem *themeItem = [[NSMenuItem alloc] initWithTitle:@"Theme" action:nil keyEquivalent:@""];
  themeItem.submenu = themeMenu;
  [mainMenu addItem:themeItem];

  NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
  [self addItemTo:viewMenu title:@"Presets" action:@selector(showPresetsTab:) key:@"1" modifiers:cmd target:self];
  [self addItemTo:viewMenu title:@"Customize" action:@selector(showCustomizeTab:) key:@"2" modifiers:cmd target:self];
  [self addItemTo:viewMenu title:@"About" action:@selector(showAboutTab:) key:@"3" modifiers:cmd target:self];
  NSMenuItem *viewItem = [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
  viewItem.submenu = viewMenu;
  [mainMenu addItem:viewItem];

  NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
  [self addItemTo:windowMenu title:@"Minimize" action:@selector(performMiniaturize:) key:@"m" modifiers:cmd target:nil];
  [self addItemTo:windowMenu title:@"Zoom" action:@selector(performZoom:) key:@"" modifiers:0 target:nil];
  [windowMenu addItem:[NSMenuItem separatorItem]];
  [self addItemTo:windowMenu title:@"Bring All to Front" action:@selector(arrangeInFront:) key:@"" modifiers:0 target:NSApp];
  NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
  windowItem.submenu = windowMenu;
  [mainMenu addItem:windowItem];
  [NSApp setWindowsMenu:windowMenu];

  NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
  [self addItemTo:helpMenu title:@"Theme4Logic Project Page" action:@selector(openRepo:) key:@"" modifiers:0 target:self];
  NSMenuItem *helpItem = [[NSMenuItem alloc] initWithTitle:@"Help" action:nil keyEquivalent:@""];
  helpItem.submenu = helpMenu;
  [mainMenu addItem:helpItem];
  [NSApp setHelpMenu:helpMenu];

  [NSApp setMainMenu:mainMenu];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
  SEL a = item.action;
  if (a == @selector(applyAndLaunch:)) return [self.logicInfo[@"supported"] boolValue] && !self.launching;
  if (a == @selector(launchWithoutTheme:)) return [self.logicInfo[@"found"] boolValue] && !self.launching;
  if (a == @selector(resetToPreset:)) return self.state.changeCount > 0;
  if (a == @selector(toggleAuto:)) {
    item.state = self.state.autoEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    return YES;
  }
  if (a == @selector(clearProject:)) return self.projectPath != nil;
  return YES;
}

- (void)selectTabIndex:(NSInteger)idx {
  if (idx >= 0 && idx < self.tabs.numberOfTabViewItems) [self.tabs selectTabViewItemAtIndex:idx];
}
- (void)showPresetsTab:(id)sender { (void)sender; [self selectTabIndex:0]; }
- (void)showCustomizeTab:(id)sender { (void)sender; [self selectTabIndex:1]; }
- (void)showAboutTab:(id)sender { (void)sender; [self selectTabIndex:2]; }

#pragma mark Launch

- (void)applicationDidFinishLaunching:(NSNotification *)n {
  (void)n;
  self.scrollViews = [NSMutableArray array];
  [self buildMenu];
  [self loadStoredState];
  [self buildWindow];
  [self restoreInitialSelection];
  if (!self.state) {  // no bundled themes at all (broken bundle): keep the UI alive with an empty theme
    self.loadedSlug = @"midnight";
    self.state = [[T4LThemeState alloc] initWithBase:@{}];
    [self refreshAllUI];
    [self setStatus:@"Theme files are missing from the app bundle. Rebuild Theme4Logic (run app/build_app.sh)." isError:YES];
  }
  [self refreshLogicStatus];
  [self refreshProjectRow];

  __weak Delegate *weakSelf = self;
  [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification
                                                    object:nil
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(__unused NSNotification *note) {
    [weakSelf refreshLogicStatus];
    [weakSelf refreshProjectRow];
  }];
  NSNotificationCenter *wsc = [[NSWorkspace sharedWorkspace] notificationCenter];
  for (NSNotificationName name in @[ NSWorkspaceDidLaunchApplicationNotification, NSWorkspaceDidTerminateApplicationNotification ]) {
    [wsc addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
      NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
      if ([app.bundleIdentifier isEqualToString:kLogicBundleID]) [weakSelf refreshLogicStatus];
    }];
  }
  if (@available(macOS 14.0, *)) [NSApp activate];
  else [NSApp activateIgnoringOtherApps:YES];
}

- (void)buildWindow {
  NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"Theme4Logic-icon-512" ofType:@"png"];
  NSImage *appIconImage = iconPath ? [[NSImage alloc] initWithContentsOfFile:iconPath]
                                   : [[NSWorkspace sharedWorkspace] iconForFile:[[NSBundle mainBundle] bundlePath]];
  NSImageView *appIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
  appIcon.image = appIconImage;
  appIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
  appIcon.translatesAutoresizingMaskIntoConstraints = NO;
  appIcon.accessibilityLabel = @"Theme4Logic logo";

  NSMutableAttributedString *wordmark = [[NSMutableAttributedString alloc] initWithString:@"Theme4Logic"];
  [wordmark addAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:26 weight:NSFontWeightBold],
                            NSForegroundColorAttributeName: NSColor.labelColor} range:NSMakeRange(0, wordmark.length)];
  [wordmark addAttribute:NSForegroundColorAttributeName
                   value:[NSColor colorWithSRGBRed:0.48 green:0.39 blue:0.90 alpha:1.0]
                   range:NSMakeRange(5, 1)];
  NSTextField *title = [NSTextField labelWithAttributedString:wordmark];
  NSTextField *subtitle = Label(@"Free color themes for Logic Pro", [NSFont systemFontOfSize:12], SecondaryText());

  NSStackView *titles = [NSStackView stackViewWithViews:@[ title, subtitle ]];
  titles.orientation = NSUserInterfaceLayoutOrientationVertical;
  titles.alignment = NSLayoutAttributeLeading;
  titles.spacing = 0;
  NSStackView *brand = [NSStackView stackViewWithViews:@[ appIcon, titles ]];
  brand.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  brand.alignment = NSLayoutAttributeCenterY;
  brand.spacing = 12;
  brand.translatesAutoresizingMaskIntoConstraints = NO;

  self.tabs = [[NSTabView alloc] initWithFrame:NSZeroRect];
  self.tabs.tabViewType = NSTopTabsBezelBorder;
  self.tabs.delegate = self;
  self.tabs.translatesAutoresizingMaskIntoConstraints = NO;
  [self.tabs setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
  [self.tabs setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];

  NSTabViewItem *presetsTab = [[NSTabViewItem alloc] init];
  presetsTab.label = @"Presets";
  presetsTab.view = [self makeScrollView:[self buildPresetsTab]];
  NSTabViewItem *customTab = [[NSTabViewItem alloc] init];
  customTab.label = @"Customize";
  customTab.view = [self buildCustomizeTab];
  NSTabViewItem *aboutTab = [[NSTabViewItem alloc] init];
  aboutTab.label = @"About";
  aboutTab.view = [self makeScrollView:[self buildAboutTab]];
  [self.tabs addTabViewItem:presetsTab];
  [self.tabs addTabViewItem:customTab];
  [self.tabs addTabViewItem:aboutTab];

  NSStackView *launch = [self buildLaunchArea];

  self.win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 780)
                                         styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
  self.win.title = @"Theme4Logic";
  self.win.contentMinSize = NSMakeSize(540, 680);
  self.win.releasedWhenClosed = NO;

  NSView *content = self.win.contentView;
  [content addSubview:brand];
  [content addSubview:self.tabs];
  [content addSubview:launch];

  const CGFloat m = 20;
  [NSLayoutConstraint activateConstraints:@[
    [brand.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
    [brand.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:m],
    [brand.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-m],
    [appIcon.widthAnchor constraintEqualToConstant:46],
    [appIcon.heightAnchor constraintEqualToConstant:46],

    [self.tabs.topAnchor constraintEqualToAnchor:brand.bottomAnchor constant:12],
    [self.tabs.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:m],
    [self.tabs.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-m],
    [self.tabs.bottomAnchor constraintEqualToAnchor:launch.topAnchor constant:-12],

    [launch.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:m],
    [launch.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-m],
    [launch.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
  ]];

  NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
  if (screen) {
    NSRect f = self.win.frame, vis = screen.visibleFrame;
    if (NSHeight(f) > NSHeight(vis)) {
      f.size.height = NSHeight(vis);
      [self.win setFrame:f display:NO];
    }
  }
  if (![self.win setFrameUsingName:@"Theme4LogicMainWindow"]) [self.win center];
  self.win.frameAutosaveName = @"Theme4LogicMainWindow";
  [self.win makeKeyAndOrderFront:nil];

  NSInteger savedTab = [[NSUserDefaults standardUserDefaults] integerForKey:kLastTabKey];
  [self selectTabIndex:savedTab];
  [self syncAllScrollWidths];
  [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResizeNotification
                                                    object:self.win
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(__unused NSNotification *note) {
    [self syncAllScrollWidths];
  }];
}

- (NSStackView *)buildLaunchArea {
  NSBox *rule = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 100, 1)];
  rule.boxType = NSBoxSeparator;
  rule.translatesAutoresizingMaskIntoConstraints = NO;

  self.logicDot = [[T4LDotView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
  self.logicDot.translatesAutoresizingMaskIntoConstraints = NO;
  self.logicLabel = WrapLabel(@"Checking for Logic Pro…", [NSFont systemFontOfSize:12], NSColor.labelColor);
  self.logicLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [self.logicLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  [self.logicLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView *logicRow = [NSStackView stackViewWithViews:@[ self.logicDot, self.logicLabel ]];
  logicRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  logicRow.alignment = NSLayoutAttributeTop;
  logicRow.spacing = 8;
  logicRow.translatesAutoresizingMaskIntoConstraints = NO;

  NSTextField *projectCaption = Label(@"Project", [NSFont systemFontOfSize:12], SecondaryText());
  [projectCaption setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
  self.projectLabel = Label(@"None (optional)", [NSFont systemFontOfSize:12], SecondaryText());
  self.projectLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
  [self.projectLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  [self.projectLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  self.clearProjectButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:@"Don’t open a project"]
                                               target:self action:@selector(clearProject:)];
  self.clearProjectButton.bordered = NO;
  self.clearProjectButton.contentTintColor = SecondaryText();
  self.clearProjectButton.toolTip = @"Don’t open a project";
  self.openProjectButton = [NSButton buttonWithTitle:@"Open project…" target:self action:@selector(chooseProject:)];
  self.openProjectButton.bezelStyle = NSBezelStyleRounded;
  self.openProjectButton.controlSize = NSControlSizeSmall;
  self.openProjectButton.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  self.openProjectButton.toolTip = @"Choose a Logic project to open as soon as Logic starts (optional)";
  NSStackView *projectRow = [NSStackView stackViewWithViews:@[ projectCaption, self.projectLabel, self.clearProjectButton, self.openProjectButton ]];
  projectRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  projectRow.alignment = NSLayoutAttributeCenterY;
  projectRow.spacing = 8;
  projectRow.translatesAutoresizingMaskIntoConstraints = NO;

  // Primary look without a Return key equivalent: no accidental launches from a hex field's Return.
  self.launchButton = [[T4LPrimaryButton alloc] initWithFrame:NSMakeRect(0, 0, 220, 36)];
  self.launchButton.title = @"Apply & Launch Logic Pro";
  self.launchButton.target = self;
  self.launchButton.action = @selector(applyAndLaunch:);
  self.launchButton.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
  self.launchButton.translatesAutoresizingMaskIntoConstraints = NO;
  [self.launchButton setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  self.plainLaunchButton = [NSButton buttonWithTitle:@"Launch Logic without theme" target:self action:@selector(launchWithoutTheme:)];
  self.plainLaunchButton.bezelStyle = NSBezelStyleRounded;
  self.plainLaunchButton.controlSize = NSControlSizeLarge;
  self.plainLaunchButton.toolTip = @"Start Logic Pro normally, with no theme and no engine";
  self.plainLaunchButton.translatesAutoresizingMaskIntoConstraints = NO;
  [self.plainLaunchButton setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView *buttonRow = [NSStackView stackViewWithViews:@[ self.launchButton, self.plainLaunchButton ]];
  buttonRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  buttonRow.alignment = NSLayoutAttributeCenterY;
  buttonRow.spacing = 8;
  buttonRow.translatesAutoresizingMaskIntoConstraints = NO;

  self.status = WrapLabel(@"Choose a preset, then apply when you’re ready.", [NSFont systemFontOfSize:11], SecondaryText());
  self.status.translatesAutoresizingMaskIntoConstraints = NO;
  self.status.maximumNumberOfLines = 3;

  NSStackView *stack = [NSStackView stackViewWithViews:@[ rule, logicRow, projectRow, buttonRow, self.status ]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 8;
  [stack setCustomSpacing:10 afterView:rule];
  [stack setCustomSpacing:12 afterView:projectRow];
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  for (NSView *v in @[ rule, logicRow, projectRow, buttonRow, self.status ])
    [v.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
  [self.launchButton.heightAnchor constraintEqualToConstant:36].active = YES;
  [self.plainLaunchButton.heightAnchor constraintEqualToConstant:36].active = YES;
  return stack;
}

#pragma mark Misc actions

- (void)openSupportFolder:(id)sender {
  (void)sender;
  [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:SupportDir()]];
}

- (void)openRepo:(id)sender {
  (void)sender;
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:kRepoURLString]];
}

- (void)showAbout:(id)sender {
  (void)sender;
  NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"1.0";
  [NSApp orderFrontStandardAboutPanelWithOptions:@{
    NSAboutPanelOptionApplicationName : @"Theme4Logic",
    NSAboutPanelOptionApplicationVersion : version,
    NSAboutPanelOptionVersion : [NSBundle mainBundle].infoDictionary[@"CFBundleVersion"] ?: @"1",
    NSAboutPanelOptionCredits : [[NSAttributedString alloc] initWithString:
      [NSString stringWithFormat:@"Free color themes for Logic Pro. Logic is never modified.\nFree and open source (MIT).\n%@", kRepoURLString]
      attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11], NSForegroundColorAttributeName: NSColor.labelColor}],
  }];
}

#pragma mark Theme for launch

- (NSDictionary *)mergedThemeForLaunch {
  NSMutableDictionary *theme = [[self.state mergedTheme] mutableCopy] ?: [NSMutableDictionary dictionary];
  if (![theme[@"colors"] isKindOfClass:[NSDictionary class]]) theme[@"colors"] = @{};
  if (![theme[@"mixer"] isKindOfClass:[NSDictionary class]]) theme[@"mixer"] = @{};
  if (![theme[@"auto"] isKindOfClass:[NSDictionary class]]) theme[@"auto"] = @{@"enabled": @YES};
  if (![theme[@"region_palette"] isKindOfClass:[NSArray class]]) theme[@"region_palette"] = @[];
  if (![theme[@"region_palette_hues"] isKindOfClass:[NSArray class]]) theme[@"region_palette_hues"] = @[];
  if (![theme[@"name"] isKindOfClass:[NSString class]] || ![theme[@"name"] length]) theme[@"name"] = @"Custom";
  theme[@"author"] = @"Theme4Logic";
  return TidyNumbers(theme);
}

- (BOOL)stageDylib:(NSString **)outPath error:(NSString **)outError {
  NSString *src = [[NSBundle mainBundle] pathForResource:@"colorize" ofType:@"dylib"];
  if (!src) {
    if (outError) *outError = @"Theme engine missing from app bundle. Rebuild Theme4Logic (run app/build_app.sh).";
    return NO;
  }
  NSString *manifestSrc = [[NSBundle mainBundle] pathForResource:@"hook-manifests" ofType:nil];
  if (!manifestSrc) {
    if (outError) *outError = @"Hook safety manifests missing from app bundle. Rebuild Theme4Logic.";
    return NO;
  }
  NSString *staged = [SupportDir() stringByAppendingPathComponent:@"colorize.dylib"];
  NSString *manifestDst = HookManifestDir();
  NSString *tmpDylib = [SupportDir() stringByAppendingPathComponent:
    [NSString stringWithFormat:@"colorize.dylib.%@.tmp", [NSUUID UUID].UUIDString]];
  NSString *tmpManifest = [SupportDir() stringByAppendingPathComponent:
    [NSString stringWithFormat:@"hook-manifests.%@.tmp", [NSUUID UUID].UUIDString]];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *err = nil;
  if (![fm copyItemAtPath:src toPath:tmpDylib error:&err]) {
    if (outError) *outError = err.localizedDescription ?: @"Could not stage theme engine.";
    return NO;
  }
  if (![fm copyItemAtPath:manifestSrc toPath:tmpManifest error:&err]) {
    [fm removeItemAtPath:tmpDylib error:nil];
    if (outError) *outError = err.localizedDescription ?: @"Could not stage hook safety manifests.";
    return NO;
  }
  if (!ReplacePreparedItem(tmpDylib, staged, &err)) {
    [fm removeItemAtPath:tmpDylib error:nil];
    [fm removeItemAtPath:tmpManifest error:nil];
    if (outError) *outError = err.localizedDescription ?: @"Could not activate theme engine.";
    return NO;
  }
  if (!ReplacePreparedItem(tmpManifest, manifestDst, &err)) {
    [fm removeItemAtPath:tmpManifest error:nil];
    if (outError) *outError = err.localizedDescription ?: @"Could not activate hook safety manifests.";
    return NO;
  }
  if (outPath) *outPath = staged;
  return YES;
}

- (BOOL)writeTheme:(NSDictionary *)theme error:(NSString **)outError {
  NSError *err = nil;
  NSData *jd = [NSJSONSerialization dataWithJSONObject:theme options:NSJSONWritingPrettyPrinted error:&err];
  if (!jd) {
    if (outError) *outError = err.localizedDescription ?: @"Could not serialize theme.";
    return NO;
  }
  NSString *path = [SupportDir() stringByAppendingPathComponent:@"theme.json"];
  if (![jd writeToFile:path options:NSDataWritingAtomic error:&err]) {
    if (outError) *outError = err.localizedDescription ?: @"Could not write theme.json.";
    return NO;
  }
  return YES;
}

- (BOOL)confirmLogicRelaunchThemed:(BOOL)themed {
  if (!LogicIsRunning()) return YES;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Quit Logic Pro?";
  alert.informativeText = themed
    ? @"Logic must restart to apply your theme. Save your project first — unsaved changes will be lost."
    : @"Logic must restart to open without the theme. Save your project first — unsaved changes will be lost.";
  alert.alertStyle = NSAlertStyleWarning;
  [alert addButtonWithTitle:themed ? @"I Saved, Quit & Apply" : @"I Saved, Quit & Relaunch"];
  [alert addButtonWithTitle:@"Cancel"];
  return [alert runModal] == NSAlertFirstButtonReturn;
}

- (void)clearActivationMarkers {
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm removeItemAtPath:ActivationStatusPath() error:nil];
  [fm removeItemAtPath:LegacyActivationMarkerPath() error:nil];
}

- (NSDictionary *)activationStatusNewerThan:(NSDate *)startedAt processIdentifier:(pid_t)pid token:(NSString *)token {
  if (pid <= 0) return nil;
  NSString *path = ActivationStatusPath();
  NSFileManager *fm = [NSFileManager defaultManager];
  NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
  NSDate *modified = attrs[NSFileModificationDate];
  if (![modified isKindOfClass:[NSDate class]] || [modified compare:startedAt] == NSOrderedAscending)
    return nil;

  NSData *data = [NSData dataWithContentsOfFile:path];
  if (!data) return nil;
  NSDictionary *status = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![status isKindOfClass:[NSDictionary class]]) return nil;

  NSNumber *statusPid = status[@"pid"];
  if (!statusPid || statusPid.intValue != pid) return nil;
  NSString *statusToken = status[@"token"];
  if (![statusToken isKindOfClass:[NSString class]] || ![statusToken isEqualToString:token]) return nil;
  NSString *disabledReason = status[@"disabledReason"];
  if ([disabledReason isKindOfClass:[NSString class]] && disabledReason.length > 0) return status;
  NSNumber *colors = status[@"colors"];
  if (![colors isKindOfClass:[NSNumber class]] || colors.unsignedIntegerValue == 0) return nil;
  NSNumber *ok = status[@"ok"];
  if (![ok isKindOfClass:[NSNumber class]] || !ok.boolValue) return nil;
  NSArray *installedHooks = status[@"installedAppKitHooks"];
  NSArray *expectedHooks = status[@"expectedAppKitHooks"];
  if (![installedHooks isKindOfClass:[NSArray class]]) return nil;
  if (![expectedHooks isKindOfClass:[NSArray class]] || expectedHooks.count == 0) return nil;
  NSSet *installed = [NSSet setWithArray:installedHooks];
  for (NSString *hook in expectedHooks) {
    if (![installed containsObject:hook]) return nil;
  }
  return status;
}

- (void)endLaunch {
  self.launching = NO;
  [self updateLaunchControls];
  [self refreshLogicStatus];
}

- (void)finishLaunchWithError:(NSString *)message {
  [self endLaunch];
  [self setStatus:message isError:YES];
}

- (void)waitForActivationForApp:(NSRunningApplication *)app
                      themeName:(NSString *)themeName
                         token:(NSString *)token
                      startedAt:(NSDate *)startedAt
                       deadline:(NSDate *)deadline {
  if (!app) {
    [self finishLaunchWithError:@"Logic Pro launch did not return a running app to verify."];
    return;
  }
  NSDictionary *status = [self activationStatusNewerThan:startedAt processIdentifier:app.processIdentifier token:token];
  if (status) {
    NSString *disabledReason = status[@"disabledReason"];
    if ([disabledReason isKindOfClass:[NSString class]] && disabledReason.length > 0) {
      NSNumber *ok = status[@"ok"];
      NSNumber *hooksAllowed = status[@"hooksAllowed"];
      NSString *state = status[@"state"];
      NSString *logicVersion = status[@"logicVersion"];
      NSString *hookManifest = status[@"hookManifest"];
      if (![state isEqualToString:@"disabled"] || ![ok isKindOfClass:[NSNumber class]] || ok.boolValue ||
          ![hooksAllowed isKindOfClass:[NSNumber class]] || hooksAllowed.boolValue ||
          ![logicVersion isKindOfClass:[NSString class]] || ![hookManifest isKindOfClass:[NSString class]]) {
        [self finishLaunchWithError:@"Theme4Logic received an invalid hook safety status from Logic."];
        return;
      }
      [self finishLaunchWithError:[NSString stringWithFormat:@"Theme4Logic disabled itself for safety: %@", disabledReason]];
      return;
    }
    [self endLaunch];
    [self setStatus:[NSString stringWithFormat:@"Logic Pro launched and Theme4Logic engine loaded for “%@” ✓", themeName] isError:NO];
    return;
  }

  if ([[NSDate date] compare:deadline] != NSOrderedAscending) {
    [self finishLaunchWithError:@"Logic Pro launched, but Theme4Logic could not confirm the theme engine loaded. Quit Logic and try again."];
    return;
  }

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self waitForActivationForApp:app themeName:themeName token:token startedAt:startedAt deadline:deadline];
  });
}

// themeName == nil means a plain launch (no engine): there is nothing to verify afterwards.
- (void)launchLogicURL:(NSURL *)logic
         configuration:(NSWorkspaceOpenConfiguration *)cfg
            projectURL:(NSURL *)project
             themeName:(NSString *)themeName
                 token:(NSString *)token {
  if (themeName) [self clearActivationMarkers];
  NSDate *startedAt = [NSDate date];
  void (^completion)(NSRunningApplication *, NSError *) = ^(NSRunningApplication *app, NSError *err) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self refreshLogicStatus];
      if (err) {
        [self finishLaunchWithError:[NSString stringWithFormat:@"Launch failed: %@", err.localizedDescription]];
        return;
      }
      if (!app) {
        [self finishLaunchWithError:@"Logic Pro launch did not return a running app to verify."];
        return;
      }
      if (!themeName) {
        [self endLaunch];
        [self setStatus:project ? [NSString stringWithFormat:@"Opened Logic Pro without a theme, with “%@”.", project.lastPathComponent]
                                : @"Opened Logic Pro without a theme." isError:NO];
        return;
      }
      [self setStatus:@"Logic Pro launched; confirming Theme4Logic engine loaded…" isError:NO];
      NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
      [self waitForActivationForApp:app themeName:themeName token:token startedAt:startedAt deadline:deadline];
    });
  };
  if (project) {
    [[NSWorkspace sharedWorkspace] openURLs:@[ project ] withApplicationAtURL:logic configuration:cfg completionHandler:completion];
  } else {
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:logic configuration:cfg completionHandler:completion];
  }
}

- (void)waitForLogicExitThenLaunchURL:(NSURL *)logic
                        configuration:(NSWorkspaceOpenConfiguration *)cfg
                           projectURL:(NSURL *)project
                            themeName:(NSString *)themeName
                                token:(NSString *)token
                             deadline:(NSDate *)deadline {
  if (!LogicIsRunning()) {
    [self setStatus:themeName ? @"Launching Logic Pro with your theme…" : @"Launching Logic Pro…" isError:NO];
    [self launchLogicURL:logic configuration:cfg projectURL:project themeName:themeName token:token];
    return;
  }

  if ([[NSDate date] compare:deadline] != NSOrderedAscending) {
    [self finishLaunchWithError:@"Logic Pro did not quit. Save and close Logic, then try again."];
    return;
  }

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self waitForLogicExitThenLaunchURL:logic configuration:cfg projectURL:project themeName:themeName token:token deadline:deadline];
  });
}

// The remembered project, if any. A project that has gone missing is forgotten with a message instead of launching blind.
- (BOOL)resolveProjectURL:(NSURL **)outURL {
  *outURL = nil;
  if (!self.projectPath) return YES;
  NSURL *url = ValidProjectURL(self.projectPath);
  if (!url) {
    NSString *name = self.projectPath.lastPathComponent;
    [self clearProject:nil];
    [self setStatus:[NSString stringWithFormat:@"The project “%@” can’t be found any more, so it was cleared. Choose it again or launch without a project.", name] isError:YES];
    return NO;
  }
  *outURL = url;
  return YES;
}

- (void)applyAndLaunch:(id)sender {
  (void)sender;
  if (self.launching) return;
  NSURL *logic = LogicAppURL();
  if (!logic) {
    [self setStatus:@"Install Logic Pro in /Applications, then try again." isError:YES];
    return;
  }
  [self refreshLogicStatus];
  if (![self.logicInfo[@"supported"] boolValue]) {
    [self setStatus:self.logicInfo[@"message"] ?: @"This Logic Pro version is not supported by this build of Theme4Logic." isError:YES];
    return;
  }
  NSURL *project = nil;
  if (![self resolveProjectURL:&project]) return;
  if (![self confirmLogicRelaunchThemed:YES]) {
    [self setStatus:@"Cancelled — Logic was not restarted." isError:NO];
    return;
  }

  NSDictionary *theme = [self mergedThemeForLaunch];
  NSString *errMsg = nil;
  NSString *dylib = nil;
  if (![self stageDylib:&dylib error:&errMsg]) {
    [self setStatus:errMsg isError:YES];
    return;
  }
  if (![self writeTheme:theme error:&errMsg]) {
    [self setStatus:errMsg isError:YES];
    return;
  }

  [self flushSave];

  for (NSRunningApplication *a in RunningLogicApps())
    [a terminate];

  NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
  NSString *themeName = theme[@"name"] ?: @"Theme";
  NSString *launchToken = [NSUUID UUID].UUIDString;
  cfg.environment = @{
    @"DYLD_INSERT_LIBRARIES" : dylib,
    @"THEME4LOGIC_LAUNCH_TOKEN" : launchToken,
    @"THEME4LOGIC_THEME_NAME" : themeName,
    @"THEME4LOGIC_HOOK_MANIFEST_DIR" : HookManifestDir()
  };
  cfg.createsNewApplicationInstance = YES;
  cfg.activates = YES;

  self.launching = YES;
  [self updateLaunchControls];
  [self setStatus:@"Waiting for Logic Pro to quit…" isError:NO];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45.0];
  [self waitForLogicExitThenLaunchURL:logic configuration:cfg projectURL:project themeName:themeName token:launchToken deadline:deadline];
}

// Plain launch: no engine, no environment, theme.json untouched.
- (void)launchWithoutTheme:(id)sender {
  (void)sender;
  if (self.launching) return;
  NSURL *logic = LogicAppURL();
  if (!logic) {
    [self setStatus:@"Install Logic Pro in /Applications, then try again." isError:YES];
    return;
  }
  NSURL *project = nil;
  if (![self resolveProjectURL:&project]) return;
  if (![self confirmLogicRelaunchThemed:NO]) {
    [self setStatus:@"Cancelled — Logic was not restarted." isError:NO];
    return;
  }
  for (NSRunningApplication *a in RunningLogicApps())
    [a terminate];

  NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
  cfg.createsNewApplicationInstance = NO;
  cfg.activates = YES;
  self.launching = YES;
  [self updateLaunchControls];
  [self setStatus:LogicIsRunning() ? @"Waiting for Logic Pro to quit…" : @"Launching Logic Pro…" isError:NO];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45.0];
  [self waitForLogicExitThenLaunchURL:logic configuration:cfg projectURL:project themeName:nil token:nil deadline:deadline];
}

- (void)applicationWillTerminate:(NSNotification *)n {
  (void)n;
  [self flushSave];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)s {
  (void)s;
  return YES;
}

@end

int main(int argc, const char *argv[]) {
  (void)argc;
  (void)argv;
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    Delegate *d = [Delegate new];
    app.delegate = d;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app run];
  }
  return 0;
}
