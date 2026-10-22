// build : clang -dynamiclib -arch arm64 -o hv-oslog-spy.dylib hv-oslog-spy.c && codesign -s - -f hv-oslog-spy.dylib
// usage : DYLD_INSERT_LIBRARIES=$PWD/hv-oslog-spy.dylib HV_SPY_LOG=<fichier> HermedBots (build Debug ad hoc, sans hardened runtime)
// espion de la lane 3 : intercepte _os_log_impl, et quand le format contient « System Keychain Always », écrit la pile d'appel dans $HV_SPY_LOG
#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <os/log.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void _os_log_impl(void *dso, os_log_t log, os_log_type_t type, const char *format, uint8_t *buf, uint32_t size);

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *r; const void *o; } interpose_##original \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original };

static void spy_os_log_impl(void *dso, os_log_t log, os_log_type_t type, const char *format, uint8_t *buf, uint32_t size) {
    if (format && strstr(format, "System Keychain Always")) {
        const char *path = getenv("HV_SPY_LOG");
        int fd = open(path ? path : "/tmp/hv-spy.log", O_WRONLY | O_APPEND | O_CREAT, 0600);
        if (fd >= 0) {
            dprintf(fd, "OSLOG %s\n", format);
            void *frames[40];
            int n = backtrace(frames, 40);
            backtrace_symbols_fd(frames, n, fd);
            close(fd);
        }
    }
    _os_log_impl(dso, log, type, format, buf, size);
}
INTERPOSE(spy_os_log_impl, _os_log_impl)
