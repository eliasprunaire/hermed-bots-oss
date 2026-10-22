// build : clang -dynamiclib -fobjc-arc -arch arm64 -framework AppKit -Wno-deprecated-declarations -o hv-ax-dump.dylib hv-ax-dump.m && codesign -s - -f hv-ax-dump.dylib
// usage : DYLD_INSERT_LIBRARIES=$PWD/hv-ax-dump.dylib HV_AX_OUT=<fichier> HV_TEST_MODE=1 HV_API_URL=http://127.0.0.1:18642 HermedBots
// lane 6 et 10, repli sans TCC : DYLD_INSERT_LIBRARIES charge ce code dans l'app, qui lit son propre arbre NSAccessibility 3 s après le lancement
// et l'écrit dans $HV_AX_OUT (une ligne par élément : profondeur, rôle, AXIdentifier, AXLabel, AXValue)
#import <AppKit/AppKit.h>
#import <dlfcn.h>

static NSMutableString *out;

static void walk(id element, int depth) {
    if (depth > 40) return;
    NSString *identifier = [element respondsToSelector:@selector(accessibilityIdentifier)] ? [element accessibilityIdentifier] : nil;
    NSString *role = [element respondsToSelector:@selector(accessibilityRole)] ? [element accessibilityRole] : nil;
    NSString *label = [element respondsToSelector:@selector(accessibilityLabel)] ? [element accessibilityLabel] : nil;
    id value = [element respondsToSelector:@selector(accessibilityValue)] ? [element accessibilityValue] : nil;
    [out appendFormat:@"%d\t%@\t%@\t%@\t%@\n", depth, role ?: @"-", identifier.length ? identifier : @"-", label ?: @"-", value ?: @"-"];
    NSArray *children = [element respondsToSelector:@selector(accessibilityChildren)] ? [element accessibilityChildren] : nil;
    for (id child in children) walk(child, depth + 1);
}

__attribute__((constructor)) static void hv_ax_init(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        // SwiftUI ne construit son arbre d'accessibilité que si l'app se sait observée : on le déclare comme le ferait un client AX
        void (*enable)(int) = dlsym(RTLD_DEFAULT, "_AXSSetApplicationAccessibilityEnabled");
        if (enable) enable(1);
        [NSApp accessibilitySetValue:@YES forAttribute:@"AXEnhancedUserInterface"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            out = [NSMutableString string];
            [out appendFormat:@"_AXSSetApplicationAccessibilityEnabled %@\n", enable ? @"trouvée" : @"absente"];
            for (NSWindow *window in NSApp.windows) {
                [out appendFormat:@"WINDOW\t%@\n", window.title];
                walk(window, 0);
            }
            [out writeToFile:[NSString stringWithUTF8String:getenv("HV_AX_OUT") ?: "/tmp/hv-ax.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        });
    }];
}
