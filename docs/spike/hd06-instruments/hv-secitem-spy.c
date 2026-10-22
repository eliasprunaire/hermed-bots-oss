// build : clang -dynamiclib -arch arm64 -framework Security -framework CoreFoundation -o hv-secitem-spy.dylib hv-secitem-spy.c && codesign -s - -f hv-secitem-spy.dylib
// usage : DYLD_INSERT_LIBRARIES=$PWD/hv-secitem-spy.dylib HV_SPY_LOG=<fichier> HermedBots (build Debug ad hoc, sans hardened runtime)
// espion de la lane 3 : DYLD_INSERT_LIBRARIES intercepte les appels au Trousseau et au moteur de confiance, les écrit dans $HV_SPY_LOG avec l'image appelante
#include <Security/Security.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *r; const void *o; } interpose_##original \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original };

static void note(const char *function, void *caller) {
    Dl_info info;
    const char *image = (dladdr(caller, &info) && info.dli_fname) ? info.dli_fname : "?";
    char line[1200];
    int n = snprintf(line, sizeof line, "SPY %s depuis %s\n", function, image);
    const char *path = getenv("HV_SPY_LOG");
    int fd = open(path ? path : "/tmp/hv-spy.log", O_WRONLY | O_APPEND | O_CREAT, 0600);
    if (fd >= 0) { write(fd, line, n); close(fd); }
}

static OSStatus spy_SecItemCopyMatching(CFDictionaryRef q, CFTypeRef *r) { note("SecItemCopyMatching", __builtin_return_address(0)); return SecItemCopyMatching(q, r); }
static OSStatus spy_SecItemAdd(CFDictionaryRef q, CFTypeRef *r) { note("SecItemAdd", __builtin_return_address(0)); return SecItemAdd(q, r); }
static OSStatus spy_SecItemUpdate(CFDictionaryRef q, CFDictionaryRef u) { note("SecItemUpdate", __builtin_return_address(0)); return SecItemUpdate(q, u); }
static OSStatus spy_SecItemDelete(CFDictionaryRef q) { note("SecItemDelete", __builtin_return_address(0)); return SecItemDelete(q); }
static bool spy_SecTrustEvaluateWithError(SecTrustRef t, CFErrorRef *e) { note("SecTrustEvaluateWithError", __builtin_return_address(0)); return SecTrustEvaluateWithError(t, e); }

INTERPOSE(spy_SecItemCopyMatching, SecItemCopyMatching)
INTERPOSE(spy_SecItemAdd, SecItemAdd)
INTERPOSE(spy_SecItemUpdate, SecItemUpdate)
INTERPOSE(spy_SecItemDelete, SecItemDelete)
INTERPOSE(spy_SecTrustEvaluateWithError, SecTrustEvaluateWithError)
