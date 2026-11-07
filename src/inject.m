// language: Objective-C, file: src/inject.m, load-command dylib injection
// copies hook dylib into App.app/Frameworks, appends LC_LOAD_DYLIB into
// mach-o slack space, then re-trusts the patched cdhash.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>

#include "tsx.h"

enum {
    VTInjectOK          = 0,
    VTInjectErrNoApp    = -1,   // bundle missing / no executable
    VTInjectErrFormat   = -2,   // not a thin/fat 64-bit mach-o
    VTInjectErrSlack    = -3,   // no room for another load command
    VTInjectErrIO       = -4,   // copy / write / chmod failure
    VTInjectErrTrust    = -5,   // patched binary could not be re-trusted
};

static NSString *MainExecPath(NSString *appPath) {
    NSString *infoPlist = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlist];
    NSString *exec = info[@"CFBundleExecutable"];
    if (exec.length == 0) return nil;
    NSString *full = [appPath stringByAppendingPathComponent:exec];
    return [[NSFileManager defaultManager] fileExistsAtPath:full] ? full : nil;
}

// offset of first section data after the load commands = slack boundary
static size_t FirstSectionOffset(const struct mach_header_64 *mh) {
    const uint8_t *cursor = (const uint8_t *)mh + sizeof(struct mach_header_64);
    size_t best = SIZE_MAX;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            const struct section_64 *sec =
                (const struct section_64 *)(seg + 1);
            for (uint32_t s = 0; s < seg->nsects; s++) {
                if (sec[s].size == 0) continue;
                if (sec[s].offset == 0) continue;
                if (sec[s].offset < best) best = sec[s].offset;
            }
        }
        cursor += lc->cmdsize;
    }
    return best;
}

// 1 = already present, 0 = patched in, negative = error
static int PatchSlice(struct mach_header_64 *mh, size_t avail, const char *dylibPath) {
    if (mh->magic != MH_MAGIC_64) return VTInjectErrFormat;
    if (mh->filetype != MH_EXECUTE) return VTInjectErrFormat;

    size_t pathLen = strlen(dylibPath) + 1;
    size_t pad = (8 - (pathLen % 8)) % 8;          // dylib_command wants 8-byte align
    size_t need = sizeof(struct dylib_command) + pathLen + pad;
    if (need > 0x1000) return VTInjectErrFormat;

    uint8_t *base = (uint8_t *)mh;
    struct load_command *cmds =
        (struct load_command *)(base + sizeof(struct mach_header_64));

    // walk: detect duplicate, find end of load command area
    uint8_t *cursor = (uint8_t *)cmds;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        struct load_command *lc = (struct load_command *)cursor;
        if (lc->cmdsize < sizeof(struct load_command)) return VTInjectErrFormat;
        if (lc->cmd == LC_LOAD_DYLIB) {
            struct dylib_command *dy = (struct dylib_command *)lc;
            const char *path = (const char *)dy + dy->dylib.name.offset;
            if (strncmp(path, dylibPath, pathLen) == 0) return 1;
        }
        cursor += lc->cmdsize;
    }

    size_t loadEnd = (size_t)(cursor - base);
    size_t slackEnd = FirstSectionOffset(mh);
    if (slackEnd == SIZE_MAX || slackEnd > avail) slackEnd = avail;
    if (loadEnd + need > slackEnd) return VTInjectErrSlack;

    struct dylib_command *dy = (struct dylib_command *)cursor;
    memset(dy, 0, need);
    dy->cmd = LC_LOAD_DYLIB;
    dy->cmdsize = (uint32_t)need;
    dy->dylib.name.offset = (uint32_t)sizeof(struct dylib_command);
    dy->dylib.timestamp = 0;
    dy->dylib.current_version = 0;
    dy->dylib.compatibility_version = 0;
    memcpy((uint8_t *)dy + dy->dylib.name.offset, dylibPath, pathLen);

    mh->ncmds += 1;
    mh->sizeofcmds += (uint32_t)need;
    return 0;
}

// returns VTInject* code; *didPatch = 1 when the binary changed
static int PatchFile(const char *execPath, const char *dylibPath, int *didPatch) {
    NSString *p = [NSString stringWithUTF8String:execPath];
    NSMutableData *data = [NSMutableData dataWithContentsOfFile:p];
    if (data.length < sizeof(struct mach_header_64)) return VTInjectErrIO;
    *didPatch = 0;

    uint8_t *bytes = data.mutableBytes;
    uint32_t magic = *(uint32_t *)bytes;

    int rc = VTInjectErrFormat;
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        struct fat_header *fat = (struct fat_header *)bytes;
        uint32_t nfat = (magic == FAT_CIGAM) ? __builtin_bswap32(fat->nfat_arch)
                                             : fat->nfat_arch;
        if (nfat > 64) return VTInjectErrFormat;
        for (uint32_t i = 0; i < nfat; i++) {
            struct fat_arch *arch = (struct fat_arch *)(fat + 1) + i;
            uint32_t off = (magic == FAT_CIGAM) ? __builtin_bswap32(arch->offset)
                                                : arch->offset;
            uint32_t sz  = (magic == FAT_CIGAM) ? __builtin_bswap32(arch->size)
                                                : arch->size;
            if (off > data.length || sz > data.length - off) return VTInjectErrFormat;
            if (sz < sizeof(struct mach_header_64)) continue;
            int slice = PatchSlice((struct mach_header_64 *)(bytes + off),
                                   sz, dylibPath);
            if (slice < 0) return slice;
            if (slice == 0) *didPatch = 1;
            rc = 0;
        }
        if (rc != 0) return rc;
    } else if (magic == MH_MAGIC_64) {
        rc = PatchSlice((struct mach_header_64 *)bytes, data.length, dylibPath);
        if (rc < 0) return rc;
        if (rc == 0) *didPatch = 1;
        rc = 0;
    } else {
        return VTInjectErrFormat;
    }

    if (*didPatch) {
        if (![data writeToFile:p atomically:YES]) return VTInjectErrIO;
        chmod(execPath, 0755);
    }
    return rc;
}

static int RetrustExec(const char *execPath) {
    uint8_t hash[TSX_HASH_LEN];
    int rc = tsx_cdhash_file(execPath, hash);
    if (rc != TSX_OK) return VTInjectErrTrust;
    rc = tsx_tc_inject(hash);
    if (rc != TSX_OK) return VTInjectErrTrust;
    return VTInjectOK;
}

// app_path: Vertex.app directory; dylib_path: source hook dylib on disk
int vts_inject_dylib(const char *app_path, const char *dylib_path) {
    if (!app_path || !dylib_path) return VTInjectErrNoApp;

    @autoreleasepool {
        NSString *app = [NSString stringWithUTF8String:app_path];
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:app isDirectory:&isDir] || !isDir)
            return VTInjectErrNoApp;

        NSString *exec = MainExecPath(app);
        if (!exec) return VTInjectErrNoApp;

        NSString *fwDir = [app stringByAppendingPathComponent:@"Frameworks"];
        if (![fm createDirectoryAtPath:fwDir
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:nil])
            return VTInjectErrIO;

        NSString *dst = [fwDir stringByAppendingPathComponent:@"vertexhook.dylib"];
        if (![fm fileExistsAtPath:dst]) {
            if (![fm copyItemAtPath:[NSString stringWithUTF8String:dylib_path]
                             toPath:dst
                              error:nil])
                return VTInjectErrIO;
        }
        chmod(dst.fileSystemRepresentation, 0755);

        char realExec[PATH_MAX], realDst[PATH_MAX];
        if (!realpath(exec.fileSystemRepresentation, realExec)) return VTInjectErrIO;
        if (!realpath(dst.fileSystemRepresentation, realDst)) return VTInjectErrIO;

        int didPatch = 0;
        int rc = PatchFile(realExec, realDst, &didPatch);
        if (rc != VTInjectOK) return rc;
        if (!didPatch) return VTInjectOK;    // already hooked

        rc = RetrustExec(realExec);
        if (rc != VTInjectOK) return rc;
        return VTInjectOK;
    }
}
