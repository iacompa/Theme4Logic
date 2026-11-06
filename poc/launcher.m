// launcher.m — launches Logic Pro with our dylib injected, WITHOUT re-signing Logic.
//
// Uses NSWorkspace.openApplication(at:configuration:) with an environment that
// sets DYLD_INSERT_LIBRARIES. This is a proper LaunchServices launch (so Logic
// gets a real foreground session — unlike a raw shell exec, which self-exits),
// and because we never touch Logic's bundle there is no "damaged" gate to trip.
//
// Logic must be signed flags=0x0 (no Hardened Runtime / Library Validation) for
// dyld to honor the env var — verified true for MAS Logic 12.2.
//
// Usage:  ./launch_logic_injected /abs/path/to/colorize.dylib [project.logicx ...]
// Build:  see build.sh

#import <AppKit/AppKit.h>

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) {
      fprintf(stderr, "usage: %s /abs/path/to/dylib\n", argv[0]);
      return 2;
    }
    NSString *dylib = [NSString stringWithUTF8String:argv[1]];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dylib]) {
      fprintf(stderr, "dylib not found: %s\n", dylib.UTF8String);
      return 2;
    }
    // DYLD_INSERT_LIBRARIES is mangled if the path contains non-ASCII bytes
    // (e.g. an emoji in the project folder). Stage the dylib at a clean ASCII
    // path under Application Support and inject THAT. A plain copy preserves the
    // embedded ad-hoc signature, so no re-sign is needed.
    NSString *support = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Theme4Logic"];
    [fm createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *staged = [support stringByAppendingPathComponent:[dylib lastPathComponent]];
    NSString *manifestDir = [support stringByAppendingPathComponent:@"hook-manifests"];
    NSString *source = dylib.stringByStandardizingPath;
    staged = staged.stringByStandardizingPath;
    if (![source isEqualToString:staged]) {
      NSString *temporary = [support stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.%@.tmp", staged.lastPathComponent, NSUUID.UUID.UUIDString]];
      NSError *cpErr = nil;
      if (![fm copyItemAtPath:source toPath:temporary error:&cpErr]) {
        fprintf(stderr, "could not prepare dylib: %s\n", cpErr.localizedDescription.UTF8String);
        return 2;
      }

      BOOL activated = NO;
      if ([fm fileExistsAtPath:staged]) {
        activated = [fm replaceItemAtURL:[NSURL fileURLWithPath:staged]
                         withItemAtURL:[NSURL fileURLWithPath:temporary]
                        backupItemName:nil
                               options:0
                      resultingItemURL:nil
                                 error:&cpErr];
      } else {
        activated = [fm moveItemAtPath:temporary toPath:staged error:&cpErr];
      }
      if (!activated) {
        [fm removeItemAtPath:temporary error:nil];
        fprintf(stderr, "could not activate dylib: %s\n", cpErr.localizedDescription.UTF8String);
        return 2;
      }
    }

    NSString *manifestSource = NSProcessInfo.processInfo.environment[@"THEME4LOGIC_HOOK_MANIFEST_SOURCE_DIR"];
    BOOL isDirectory = NO;
    if (manifestSource.length == 0 || ![fm fileExistsAtPath:manifestSource isDirectory:&isDirectory] || !isDirectory) {
      manifestSource = [[source stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"hook-manifests"];
      isDirectory = NO;
    }
    if (![fm fileExistsAtPath:manifestSource isDirectory:&isDirectory] || !isDirectory) {
      NSString *executableDir = [[[NSString stringWithUTF8String:argv[0]] stringByStandardizingPath] stringByDeletingLastPathComponent];
      manifestSource = [executableDir stringByAppendingPathComponent:@"hook-manifests"];
      isDirectory = NO;
    }
    manifestSource = manifestSource.stringByStandardizingPath;
    manifestDir = manifestDir.stringByStandardizingPath;
    if ([fm fileExistsAtPath:manifestSource isDirectory:&isDirectory] && isDirectory && ![manifestSource isEqualToString:manifestDir]) {
      NSString *temporaryManifests = [support stringByAppendingPathComponent:
        [NSString stringWithFormat:@"hook-manifests.%@.tmp", NSUUID.UUID.UUIDString]];
      NSError *manifestError = nil;
      if (![fm copyItemAtPath:manifestSource toPath:temporaryManifests error:&manifestError]) {
        fprintf(stderr, "could not prepare hook manifests: %s\n", manifestError.localizedDescription.UTF8String);
        return 2;
      }
      BOOL activated = NO;
      if ([fm fileExistsAtPath:manifestDir]) {
        activated = [fm replaceItemAtURL:[NSURL fileURLWithPath:manifestDir]
                         withItemAtURL:[NSURL fileURLWithPath:temporaryManifests]
                        backupItemName:nil
                               options:0
                      resultingItemURL:nil
                                 error:&manifestError];
      } else {
        activated = [fm moveItemAtPath:temporaryManifests toPath:manifestDir error:&manifestError];
      }
      if (!activated) {
        [fm removeItemAtPath:temporaryManifests error:nil];
        fprintf(stderr, "could not activate hook manifests: %s\n", manifestError.localizedDescription.UTF8String);
        return 2;
      }
    } else if (![fm fileExistsAtPath:manifestDir isDirectory:&isDirectory] || !isDirectory) {
      fprintf(stderr, "hook manifest directory not found beside the dylib or launcher\n");
      return 2;
    }
    dylib = staged;
    fprintf(stderr, "injecting: %s\n", dylib.UTF8String);
    NSURL *logic = [NSURL fileURLWithPath:@"/Applications/Logic Pro.app"];

    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    NSMutableDictionary<NSString *, NSString *> *environment = [@{
      @"DYLD_INSERT_LIBRARIES": dylib,
      @"THEME4LOGIC_HOOK_MANIFEST_DIR": manifestDir
    } mutableCopy];
    NSString *launchToken = NSProcessInfo.processInfo.environment[@"THEME4LOGIC_LAUNCH_TOKEN"];
    if (launchToken.length > 0) environment[@"THEME4LOGIC_LAUNCH_TOKEN"] = launchToken;
    NSString *themeName = NSProcessInfo.processInfo.environment[@"THEME4LOGIC_THEME_NAME"];
    if (themeName.length > 0) environment[@"THEME4LOGIC_THEME_NAME"] = themeName;
    NSString *debug = NSProcessInfo.processInfo.environment[@"THEME4LOGIC_DEBUG"];
    if (debug.length > 0) environment[@"THEME4LOGIC_DEBUG"] = debug;
    cfg.environment = environment;
    cfg.createsNewApplicationInstance = YES;
    cfg.activates = YES;

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block int rc = 0;
    NSMutableArray<NSURL *> *documents = [NSMutableArray array];
    for (int i = 2; i < argc; i++) {
      NSString *doc = [NSString stringWithUTF8String:argv[i]];
      if ([fm fileExistsAtPath:doc]) [documents addObject:[NSURL fileURLWithPath:doc]];
      else fprintf(stderr, "ignoring missing project: %s\n", argv[i]);
    }
    void (^done)(NSRunningApplication *, NSError *) = ^(NSRunningApplication *app, NSError *err) {
      if (err || !app || app.terminated) {
        NSString *message = err.localizedDescription ?: @"Logic Pro launch did not return a running app";
        fprintf(stderr, "launch error: %s\n", message.UTF8String);
        rc = 1;
      } else {
        fprintf(stderr, "launched Logic pid %d with injection\n", app.processIdentifier);
      }
      dispatch_semaphore_signal(sema);
    };
    if (documents.count) {
      [[NSWorkspace sharedWorkspace] openURLs:documents withApplicationAtURL:logic configuration:cfg completionHandler:done];
    } else {
      [[NSWorkspace sharedWorkspace] openApplicationAtURL:logic configuration:cfg completionHandler:done];
    }
    long waitResult = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    if (waitResult != 0) {
      fprintf(stderr, "launch error: Logic Pro did not respond within 20 seconds\n");
      return 1;
    }
    return rc;
  }
}
