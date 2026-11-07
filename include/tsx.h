// language: C, file: include/tsx.h, target: arm64-apple-ios15.0+, system-only deps
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifndef NS_FORMAT_ARGUMENT
#define NS_FORMAT_ARGUMENT(A)
#endif

#define TSX_HASH_LEN     20
#define TSX_PAGE_SIZE    0x1000
#define TSX_TC_HDR       16
#define TSX_TC_CAPACITY  ((TSX_PAGE_SIZE - TSX_TC_HDR) / TSX_HASH_LEN)

#define TSX_MARKER       ".tsx_active"
#define TSX_TRUSTED_ENV  "TSX_TRUSTED"

enum {
    TSX_OK = 0,
    TSX_ENOEXP   = 1,   // no provider registered
    TSX_EPROBE   = 2,   // 0-day failed to come up
    TSX_EKREAD   = 3,
    TSX_EKWRITE  = 4,
    TSX_ENOSYM   = 5,   // kallsyms miss: trust_cache_list / kernel_task
    TSX_EOFF     = 6,   // koff table does not match this build
    TSX_ENOTROOT = 7,
    TSX_EMACHO   = 8,   // no CodeDirectory in target
    TSX_ENOSLOT  = 9,   // every trust cache page is full
    TSX_EEXTRACT = 10,
    TSX_EINSTALL = 11,
    TSX_EIO      = 12,
};

const char *tsx_strerror(int rc);

// Offsets ship inside the exploit provider: every kexp already carries
// its build's task/proc/cred layout, wrong numbers are caught by the
// read-verify step in tsx_root_self before anything is written.
typedef struct {
    uint32_t task_tasks;     // task_t  -> queue_chain_t (tasks list link)
    uint32_t task_bsd_info;  // task_t  -> proc_t
    uint32_t proc_p_pid;     // proc_t  -> p_pid
    uint32_t proc_p_ucred;   // proc_t  -> kauth_cred_t
    uint32_t ucred_uid;      // cred    -> cr_uid
    uint32_t ucred_gid;      // cred    -> cr_gid
} tsx_koff_t;

typedef struct {
    const char *name;
    bool     (*probe)(void);                    // quick environment check
    int      (*start)(void);                    // fire the 0-day, primitive up
    bool     (*kread)(uint64_t kaddr, void *dst, size_t n);
    // must service write-protected targets (PPL / __DATA_CONST) itself or
    // return false; trust cache pages are not always plain writable
    bool     (*kwrite)(uint64_t kaddr, const void *src, size_t n);
    uint64_t (*kallsyms)(const char *name);     // address OF the symbol, 0 = miss
    const tsx_koff_t *koff;
} tsx_kexp_t;

// Linker slot: override in your exploit translation unit.
const tsx_kexp_t *tsx_provider(void);

void tsx_kexp_register(const tsx_kexp_t *kexp);
const tsx_kexp_t *tsx_kexp_active(void);
int tsx_kexp_boot(void);   // register -> probe -> start -> kread sanity check

int tsx_root_self(void);
int tsx_cdhash_file(const char *path, uint8_t out[TSX_HASH_LEN]);
int tsx_tc_inject(const uint8_t cdhash[TSX_HASH_LEN]);
int tsx_tc_dump(void);
int tsx_inject_bundle(const char *bundle_path);

int tsx_zip_extract(const char *zip_path, const char *out_dir);
int tsx_install_package(const char *package_dir, bool force);
int tsx_refresh_registered(void);

// src/inject.m — copy dylib into App.app/Frameworks, append LC_LOAD_DYLIB
// into mach-o slack, re-trust patched cdhash. returns 0 / VTINJ_* negative.
enum {
    VTINJ_OK        = 0,
    VTINJ_NOAPP     = -1,
    VTINJ_FORMAT    = -2,
    VTINJ_SLACK     = -3,
    VTINJ_IO        = -4,
    VTINJ_TRUST     = -5,
};
int vts_inject_dylib(const char *app_path, const char *dylib_path);
