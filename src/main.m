// language: Objective-C, file: src/main.m, CLI driver
#import <Foundation/Foundation.h>
#import "ui.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <unistd.h>
#include <limits.h>
#include <dirent.h>
#include <sys/stat.h>

#include "tsx.h"
#include "vstore.h"
#include "tsx_system.h"

// ---- provider slot -------------------------------------------------------
// your exploit translation unit overrides this with a pointer to its
// tsx_kexp_t; add the file to vertex_FILES in the Makefile
__attribute__((weak)) const tsx_kexp_t *tsx_provider(void) { return NULL; }

static void usage(void) {
    fprintf(stderr,
        "vertex - kernel-exploit installer + VertexStore for iOS 27\n"
        "\n"
        "usage:\n"
        "  vertex store search <term> [cc] [limit]   App Store catalog search\n"
        "  vertex store top <free|paid|grossing> [cc] [limit]\n"
        "  vertex store info <trackId|bundleId> [cc] full metadata row\n"
        "  vertex get <trackId|bundleId> [cc] [--force]\n"
        "      resolve via App Store API, download, trust, install\n"
        "  vertex fetch <ipa-url> [--force]          install from a direct url\n"
        "  vertex install <ipa> [--force]            install a local ipa\n"
        "  vertex inject <bundleId|.app>             add StoreKit hook dylib\n"
        "  vertex list                               user apps on device\n"
        "  vertex uninstall <bundleId>               remove an app\n"
        "  vertex launch <bundleId>                  open an app\n"
        "  vertex probe                              boot exploit, dump cache\n"
        "  vertex refresh                            re-trust + re-register\n"
        "\n"
        "VERTEX_MIRROR: ';' list of url templates for get\n"
        "  ({id} {bundle} {slug} placeholders)\n");
}

static int boot(void) {
    const tsx_kexp_t *p = tsx_provider();
    if (p) tsx_kexp_register(p);
    int rc = tsx_kexp_boot();
    if (rc != TSX_OK) {
        fprintf(stderr, "boot: %s\n", tsx_strerror(rc));
        return rc;
    }
    return TSX_OK;
}

// first run: put our own cdhash in the trust cache and re-exec so amfi
// grants this binary its entitlements from then on
static int bootstrap(char *argv0) {
    if (getenv(TSX_TRUSTED_ENV)) return TSX_OK;
    if (!argv0) return TSX_OK;

    char self[PATH_MAX];
    if (!realpath(argv0, self)) return TSX_OK;

    uint8_t hash[TSX_HASH_LEN];
    int rc = tsx_cdhash_file(self, hash);
    if (rc != TSX_OK) {
        fprintf(stderr, "bootstrap: cdhash: %s\n", tsx_strerror(rc));
        return rc;
    }
    rc = tsx_tc_inject(hash);
    if (rc != TSX_OK) {
        fprintf(stderr, "bootstrap: inject: %s\n", tsx_strerror(rc));
        return rc;
    }

    setenv(TSX_TRUSTED_ENV, "1", 1);
    char *newargv[] = {argv0, NULL};
    execv(self, newargv);
    fprintf(stderr, "bootstrap: re-exec failed: %s\n", strerror(errno));
    return TSX_EIO;
}

static int cmd_install(char *ipa_path, bool force) {
    char tmp[] = "/var/tmp/vertex.XXXXXX";
    if (!mkdtemp(tmp)) {
        perror("mkdtemp");
        return TSX_EIO;
    }

    int rc = tsx_zip_extract(ipa_path, tmp);
    if (rc != TSX_OK) {
        fprintf(stderr, "extract: %s\n", tsx_strerror(rc));
        goto out;
    }

    rc = tsx_install_package(tmp, force);
    if (rc != TSX_OK)
        fprintf(stderr, "install: %s\n", tsx_strerror(rc));

out:
    ;
    // extraction tree only, nothing else lives under the mkdtemp dir
    [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:tmp] error:nil];
    return rc;
}

static int cmd_refresh(void) {
    int n = tsx_refresh_registered();
    if (n < 0) {
        fprintf(stderr, "refresh: %s\n", tsx_strerror(-n));
        return -n;
    }
    printf("refreshed %d app(s)\n", n);
    return TSX_OK;
}

static BOOL allDigits(const char *s) {
    if (!s || !*s) return NO;
    for (; *s; s++) if (!isdigit((unsigned char)*s)) return NO;
    return YES;
}

static void printItems(NSArray<VTSItem *> *items) {
    for (VTSItem *it in items)
        printf("%s\n", it.row.UTF8String);
    printf("-- %lu result(s)\n", (unsigned long)items.count);
}

// store search|top|info — network only, no exploit boot required
static int cmd_store(int argc, char *argv[]) {
    if (argc < 4) { usage(); return 2; }
    NSString *sub = [NSString stringWithUTF8String:argv[2]];
    NSError *err = nil;
    NSString *cc = argc > 4 ? [NSString stringWithUTF8String:argv[4]] : @"us";

    if ([sub isEqualToString:@"search"]) {
        NSString *term = [NSString stringWithUTF8String:argv[3]];
        NSInteger limit = argc > 5 ? atoi(argv[5]) : 25;
        NSArray<VTSItem *> *items =
            [VTSAppStore search:term country:cc limit:limit error:&err];
        if (!items) {
            fprintf(stderr, "search: %s\n",
                    err.localizedDescription.UTF8String ?: "failed");
            return TSX_EEXTRACT;
        }
        printItems(items);
        return TSX_OK;
    }

    if ([sub isEqualToString:@"top"]) {
        NSString *kind = [NSString stringWithUTF8String:argv[3]];
        NSInteger limit = argc > 5 ? atoi(argv[5]) : 25;
        NSArray<VTSItem *> *items =
            [VTSAppStore chart:kind country:cc limit:limit error:&err];
        if (!items) {
            fprintf(stderr, "top: %s\n",
                    err.localizedDescription.UTF8String ?: "failed");
            return TSX_EEXTRACT;
        }
        printItems(items);
        return TSX_OK;
    }

    if ([sub isEqualToString:@"info"]) {
        NSString *key = [NSString stringWithUTF8String:argv[3]];
        NSArray<VTSItem *> *items;
        if (allDigits(argv[3])) {
            items = [VTSAppStore lookupIds:@[ @(atoll(argv[3])) ]
                                   country:cc
                                     error:&err];
        } else {
            items = [VTSAppStore lookupBundle:key country:cc error:&err];
        }
        if (!items) {
            fprintf(stderr, "info: %s\n",
                    err.localizedDescription.UTF8String ?: "not found");
            return TSX_EEXTRACT;
        }
        VTSItem *it = items.firstObject;
        printf("name    : %s\n", it.name.UTF8String);
        printf("seller  : %s\n", it.seller.UTF8String);
        printf("bundle  : %s\n", it.bundleId.UTF8String);
        printf("id      : %lld\n", (long long)it.trackId);
        printf("price   : %s\n", it.priceLabel.UTF8String);
        printf("genre   : %s\n", it.genre.UTF8String ?: "-");
        printf("rating  : %.1f (%lld ratings)\n",
               it.rating, (long long)it.ratingCount);
        printf("size    : %lld bytes\n", (long long)it.sizeBytes);
        printf("version : %s\n", it.version.UTF8String ?: "-");
        printf("min-os  : %s\n", it.minOS.UTF8String ?: "-");
        printf("store   : %s\n", it.storeUrl.UTF8String ?: "-");
        printf("art     : %s\n", it.artwork.UTF8String ?: "-");
        return TSX_OK;
    }

    usage();
    return 2;
}

// get <trackId|bundleId> [cc] [--force] — API resolve, then acquire
static int cmd_get(int argc, char *argv[]) {
    if (argc < 3) { usage(); return 2; }
    NSString *cc = @"us";
    BOOL force = NO;
    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--force") == 0) force = YES;
        else cc = [NSString stringWithUTF8String:argv[i]];
    }

    NSError *err = nil;
    NSArray<VTSItem *> *items;
    if (allDigits(argv[2])) {
        items = [VTSAppStore lookupIds:@[ @(atoll(argv[2])) ]
                               country:cc
                                 error:&err];
    } else {
        items = [VTSAppStore lookupBundle:[NSString stringWithUTF8String:argv[2]]
                                  country:cc
                                    error:&err];
    }
    if (!items) {
        fprintf(stderr, "get: %s\n",
                err.localizedDescription.UTF8String ?: "not found");
        return TSX_EEXTRACT;
    }

    VTSItem *item = items.firstObject;
    printf("%s\n", item.row.UTF8String);

    int rc = vts_acquire_item(item, force, &err);
    if (rc != TSX_OK) {
        fprintf(stderr, "get: %s\n",
                err.localizedDescription.UTF8String ?: tsx_strerror(rc));
        return rc;
    }
    printf("installed %s\n", item.name.UTF8String);
    return TSX_OK;
}

static int cmd_fetch(int argc, char *argv[]) {
    if (argc < 3) { usage(); return 2; }
    BOOL force = NO;
    for (int i = 3; i < argc; i++)
        if (strcmp(argv[i], "--force") == 0) force = YES;

    NSError *err = nil;
    int rc = vts_acquire_url(argv[2], force, &err);
    if (rc != TSX_OK) {
        fprintf(stderr, "fetch: %s\n",
                err.localizedDescription.UTF8String ?: tsx_strerror(rc));
        return rc;
    }
    printf("installed from %s\n", argv[2]);
    return TSX_OK;
}

// hook dylib ships next to the tool; staged path covers the package install
static NSString *FindHook(NSString *argv0) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *cands = [NSMutableArray array];

    if (argv0.length > 0) {
        char rp[PATH_MAX];
        NSString *base = argv0;
        if (realpath(argv0.fileSystemRepresentation, rp))
            base = [NSString stringWithUTF8String:rp];
        NSString *dir = [base stringByDeletingLastPathComponent];
        [cands addObject:[dir stringByAppendingPathComponent:@"vertexhook.dylib"]];
        [cands addObject:[dir stringByAppendingPathComponent:@"libvertexhook.dylib"]];
    }
    [cands addObject:@"/Library/Vertex/vertexhook.dylib"];
    [cands addObject:@"/Library/Vertex/libvertexhook.dylib"];
    [cands addObject:@"vertexhook.dylib"];
    [cands addObject:@"libvertexhook.dylib"];

    for (NSString *p in cands)
        if ([fm fileExistsAtPath:p]) return p;
    return nil;
}

static int cmd_inject(const char *target, NSString *argv0) {
    if (!target) { usage(); return 2; }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *t = [NSString stringWithUTF8String:target];
    NSString *appPath = nil;

    BOOL isDir = NO;
    if ([t.pathExtension isEqualToString:@"app"] &&
        [fm fileExistsAtPath:t isDirectory:&isDir] && isDir) {
        appPath = t;
    } else {
        LSApplicationProxy *proxy =
            [LSApplicationProxy applicationProxyForIdentifier:t];
        appPath = proxy.bundleURL.path;
    }
    if (!appPath) {
        fprintf(stderr, "inject: app not found: %s\n", target);
        return TSX_EINSTALL;
    }

    NSString *hook = FindHook(argv0);
    if (!hook) {
        fprintf(stderr, "inject: vertexhook.dylib not found next to tool\n");
        return TSX_EEXTRACT;
    }

    int rc = vts_inject_dylib(appPath.fileSystemRepresentation,
                              hook.fileSystemRepresentation);
    switch (rc) {
        case VTINJ_OK:
            printf("hooked %s\n", target);
            return TSX_OK;
        case VTINJ_SLACK:
            fprintf(stderr, "inject: no slack space for load command\n");
            return TSX_EINSTALL;
        case VTINJ_TRUST:
            fprintf(stderr, "inject: patched binary could not be re-trusted\n");
            return TSX_ENOTROOT;
        case VTINJ_FORMAT:
            fprintf(stderr, "inject: unsupported mach-o\n");
            return TSX_EMACHO;
        default:
            fprintf(stderr, "inject: io failure\n");
            return TSX_EIO;
    }
}

static int cmd_list(void) {
    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    NSArray<LSApplicationProxy *> *apps = ws.allInstalledApplications;
    if (!apps) {
        fprintf(stderr, "list: workspace unavailable\n");
        return TSX_EINSTALL;
    }
    int n = 0;
    for (LSApplicationProxy *p in apps) {
        if (![p.bundleURL.path hasPrefix:@"/private/var/containers"]) continue;
        printf("%-42s %s\n",
               p.bundleIdentifier.UTF8String ?: "?",
               (p.localizedName ?: p.bundleIdentifier).UTF8String ?: "?");
        n++;
    }
    printf("-- %d user app(s)\n", n);
    return TSX_OK;
}

static int cmd_uninstall(const char *bid) {
    if (!bid) { usage(); return 2; }
    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    NSString *id = [NSString stringWithUTF8String:bid];
    if (![ws applicationIsInstalled:id]) {
        fprintf(stderr, "uninstall: not installed: %s\n", bid);
        return TSX_EINSTALL;
    }
    if (![ws uninstallApplication:id withOptions:nil]) {
        fprintf(stderr, "uninstall: workspace refused %s\n", bid);
        return TSX_EINSTALL;
    }
    printf("uninstalled %s\n", bid);
    return TSX_OK;
}

static int cmd_launch(const char *bid) {
    if (!bid) { usage(); return 2; }
    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    if (![ws openApplicationWithBundleID:[NSString stringWithUTF8String:bid]]) {
        fprintf(stderr, "launch: refused %s\n", bid);
        return TSX_EINSTALL;
    }
    return TSX_OK;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            return UIApplicationMain(argc, argv, nil, NSStringFromClass([VertexAppDelegate class]));
        }

        // --- network / read-only paths: no exploit boot ---
        if (strcmp(argv[1], "store") == 0)
            return cmd_store(argc, argv);
        if (strcmp(argv[1], "list") == 0)
            return cmd_list();
        if (strcmp(argv[1], "launch") == 0) {
            if (argc < 3) { usage(); return 2; }
            return cmd_launch(argv[2]);
        }

        // --- privileged paths: live primitive first ---
        int rc = boot();
        if (rc != TSX_OK) return rc;

        rc = bootstrap(argv[0]);
        if (rc != TSX_OK) return rc;

        // privileged work happens with a live primitive, never before
        rc = tsx_root_self();
        if (rc != TSX_OK) {
            fprintf(stderr, "root: %s\n", tsx_strerror(rc));
            return rc;
        }

        if (strcmp(argv[1], "probe") == 0) {
            printf("uid=%d kernel exploit live\n", getuid());
            rc = tsx_tc_dump();
            if (rc != TSX_OK) fprintf(stderr, "dump: %s\n", tsx_strerror(rc));
            return rc;
        }

        if (strcmp(argv[1], "install") == 0) {
            if (argc < 3) { usage(); return 2; }
            BOOL force = argc > 3 && strcmp(argv[3], "--force") == 0;
            return cmd_install(argv[2], force);
        }

        if (strcmp(argv[1], "get") == 0)
            return cmd_get(argc, argv);

        if (strcmp(argv[1], "fetch") == 0)
            return cmd_fetch(argc, argv);

        if (strcmp(argv[1], "inject") == 0) {
            if (argc < 3) { usage(); return 2; }
            return cmd_inject(argv[2],
                              [NSString stringWithUTF8String:argv[0]]);
        }

        if (strcmp(argv[1], "uninstall") == 0) {
            if (argc < 3) { usage(); return 2; }
            return cmd_uninstall(argv[2]);
        }

        if (strcmp(argv[1], "refresh") == 0)
            return cmd_refresh();

        usage();
        return 2;
    }
}
