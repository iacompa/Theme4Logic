// inject_probe.m — Theme4Logic injection proof-of-concept + recon tool.
//
// Loaded into Logic Pro at launch via DYLD_INSERT_LIBRARIES (see launcher.m).
// It does TWO things, both READ-ONLY (it never modifies Logic):
//   1. Proves injection works   -> os_log "[Theme4Logic] dylib constructor ran"
//   2. Maps Logic's own color/draw methods (our independent hook map)
//      -> ~/Library/Application Support/Theme4Logic/probe-<version>.txt
//
// Build: see build.sh. Safe: wrapped in @try/@catch, never crashes Logic.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <unistd.h>

static void dump_hook_map(void) {
  @autoreleasepool {
    @try {
      NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
      NSString *exe = [[NSBundle mainBundle] executablePath] ?: @"?";
      NSMutableString *out = [NSMutableString string];
      [out appendFormat:@"Theme4Logic injection probe\nLogic version: %@\nexecutable: %@\npid: %d\n\n",
                        ver, exe, getpid()];

      // Is the Assets.car named-color lookup we plan to hook present on NSColor?
      Class nscolor = objc_getClass("NSColor");
      BOOL hasCatalog = nscolor && [nscolor respondsToSelector:@selector(colorWithCatalogName:colorName:)];
      [out appendFormat:@"NSColor colorWithCatalogName:colorName: present = %@\n\n", hasCatalog ? @"YES" : @"no"];

      unsigned int count = 0;
      Class *classes = objc_copyClassList(&count);
      [out appendFormat:@"total ObjC classes loaded: %u\n\n== MA*/mixer color & draw selectors (our hook candidates) ==\n", count];
      for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *cn = class_getName(cls);
        if (!cn) continue;
        NSString *name = [NSString stringWithUTF8String:cn];
        BOOL interesting = [name hasPrefix:@"MA"] || [name containsString:@"Mixer"] ||
                           [name containsString:@"Strip"] || [name containsString:@"Fader"] ||
                           [name containsString:@"Knob"] || [name containsString:@"Channel"];
        if (!interesting) continue;
        unsigned int mc = 0;
        Method *methods = class_copyMethodList(cls, &mc);
        NSMutableArray *hits = [NSMutableArray array];
        for (unsigned int j = 0; j < mc; j++) {
          NSString *sel = NSStringFromSelector(method_getName(methods[j]));
          NSString *low = sel.lowercaseString;
          if ([low containsString:@"color"] || [low containsString:@"draw"] ||
              [low containsString:@"fill"]  || [low containsString:@"background"]) {
            [hits addObject:sel];
          }
        }
        if (methods) free(methods);
        if (hits.count) {
          [out appendFormat:@"\n%@:\n    %@\n", name, [hits componentsJoinedByString:@"\n    "]];
        }
      }
      if (classes) free(classes);

      NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Theme4Logic"];
      [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
      NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"probe-%@.txt", ver]];
      [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
      os_log(OS_LOG_DEFAULT, "[Theme4Logic] probe injected into Logic %{public}@ pid %d -> wrote %{public}@",
             ver, getpid(), path);
    } @catch (NSException *e) {
      os_log_error(OS_LOG_DEFAULT, "[Theme4Logic] probe exception: %{public}@", e.reason);
    }
  }
}

__attribute__((constructor))
static void probe_init(void) {
  os_log(OS_LOG_DEFAULT, "[Theme4Logic] dylib constructor ran in pid %d", getpid());
  // Defer enumeration so Logic's frameworks/classes are registered first.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{ dump_hook_map(); });
}
