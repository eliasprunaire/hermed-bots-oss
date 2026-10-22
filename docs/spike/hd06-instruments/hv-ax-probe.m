// build : clang -dynamiclib -fobjc-arc -arch arm64 -framework AppKit -Wno-deprecated-declarations -o hv-ax-probe.dylib hv-ax-probe.m && codesign -s - -f hv-ax-probe.dylib
// usage : lancé par perf2.py (DYLD_INSERT_LIBRARIES=$PWD/hv-ax-probe.dylib HV_PROBE_OUT=<fichier>)
// sonde de perf de HD-06, repli sans XCUITest : DYLD_INSERT_LIBRARIES charge ce code dans l'app ; un minuteur de 5 ms lit l'arbre NSAccessibility
// et écrit dans $HV_PROBE_OUT l'heure (secondes epoch) où hd.status.version expose une valeur autre que « … »
#import <AppKit/AppKit.h>
#import <dlfcn.h>

static NSString *versionValue(id element, int depth) {
    if (depth > 40) return nil;
    NSString *identifier = [element respondsToSelector:@selector(accessibilityIdentifier)] ? [element accessibilityIdentifier] : nil;
    if ([identifier isEqualToString:@"hd.status.version"]) {
        id value = [element respondsToSelector:@selector(accessibilityValue)] ? [element accessibilityValue] : nil;
        return [value isKindOfClass:NSString.class] ? value : nil;
    }
    NSArray *children = [element respondsToSelector:@selector(accessibilityChildren)] ? [element accessibilityChildren] : nil;
    for (id child in children) {
        NSString *found = versionValue(child, depth + 1);
        if (found) return found;
    }
    return nil;
}

__attribute__((constructor)) static void hv_probe_init(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        [NSApp accessibilitySetValue:@YES forAttribute:@"AXEnhancedUserInterface"];
        [NSTimer scheduledTimerWithTimeInterval:0.005 repeats:YES block:^(NSTimer *timer) {
            for (NSWindow *window in NSApp.windows) {
                NSString *value = versionValue(window, 0);
                if (value.length && ![value isEqualToString:@"…"]) {
                    NSString *line = [NSString stringWithFormat:@"%.6f\t%@\n", [[NSDate date] timeIntervalSince1970], value];
                    [line writeToFile:[NSString stringWithUTF8String:getenv("HV_PROBE_OUT") ?: "/tmp/hv-probe.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    [timer invalidate];
                    return;
                }
            }
        }];
    }];
}
