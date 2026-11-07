// language: C, file: src/trustcache.c, cdhash extract + trust cache injection
#include "tsx.h"
#include "tsx_system.h"

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <CommonCrypto/CommonDigest.h>

#define KR(a, p, n) tsx_kexp_active()->kread((a), (p), (n))
#define KW(a, p, n) tsx_kexp_active()->kwrite((a), (p), (n))

static inline bool kptr(uint64_t a) {
    return (a >> 48) == 0xffff;
}

static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint64_t be64(const uint8_t *p) {
    return ((uint64_t)be32(p) << 32) | be32(p + 4);
}

static uint64_t le64(const uint8_t *p) {
    return (uint64_t)le32(p) | ((uint64_t)le32(p + 4) << 32);
}

// returns pointer to the arm64 slice inside the mapped file, sets *slice_len
static const uint8_t *pick_slice(const uint8_t *base, size_t len, size_t *slice_len) {
    if (len < 32) return NULL;
    uint32_t magic = le32(base);

    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        // standard fat stores fields big-endian: bytes CA FE BA BE read as
        // little-endian yield FAT_CIGAM, so that branch needs be32 readers
        bool standard = (magic == FAT_CIGAM);
        uint32_t (*r32)(const uint8_t *) = standard ? be32 : le32;
        uint32_t narch = r32(base + 4);
        size_t hdr = 8 + (size_t)narch * 20;
        if (narch == 0 || narch > 64 || hdr > len) return NULL;
        for (uint32_t i = 0; i < narch; i++) {
            const uint8_t *arch = base + 8 + i * 20;
            uint32_t cputype = r32(arch);
            uint64_t off = r32(arch + 8);
            uint64_t sz = r32(arch + 12);
            if (cputype == TSX_CPU_TYPE_ARM64 && off + sz <= len && sz >= 32) {
                *slice_len = (size_t)sz;
                return base + off;
            }
        }
        return NULL;
    }
    if (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64) {
        bool standard = (magic == FAT_CIGAM_64);
        uint32_t (*r32)(const uint8_t *) = standard ? be32 : le32;
        uint64_t (*r64)(const uint8_t *) = standard ? be64 : le64;
        uint32_t narch = r32(base + 4);
        size_t hdr = 8 + (size_t)narch * 32;
        if (narch == 0 || narch > 64 || hdr > len) return NULL;
        for (uint32_t i = 0; i < narch; i++) {
            const uint8_t *arch = base + 8 + i * 32;
            uint32_t cputype = r32(arch);
            uint64_t off = r64(arch + 8);
            uint64_t sz = r64(arch + 16);
            if (cputype == TSX_CPU_TYPE_ARM64 && off + sz <= len && sz >= 32) {
                *slice_len = (size_t)sz;
                return base + off;
            }
        }
        return NULL;
    }
    if (magic == TSX_MH_MAGIC_64) {
        *slice_len = len;
        return base;
    }
    return NULL;
}

// cdhash = SHA-256(CodeDirectory blob), truncated to 20 bytes
static int cdhash_from_image(const uint8_t *slice, size_t slice_len,
                             uint8_t out[TSX_HASH_LEN]) {
    if (slice_len < 32) return TSX_EMACHO;
    uint32_t ncmds = le32(slice + 16);
    size_t off = 32;
    if (ncmds > 512) return TSX_EMACHO;

    const uint8_t *sig = NULL;
    size_t sig_len = 0;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (off + 8 > slice_len) return TSX_EMACHO;
        uint32_t cmd = le32(slice + off);
        uint32_t cmdsize = le32(slice + off + 4);
        if (cmdsize < 8 || off + cmdsize > slice_len) return TSX_EMACHO;
        if (cmd == TSX_LC_CODE_SIGNATURE) {
            if (cmdsize < 16) return TSX_EMACHO;
            uint32_t dataoff = le32(slice + off + 8);
            uint32_t datasize = le32(slice + off + 12);
            if ((uint64_t)dataoff + datasize > slice_len || datasize < 8)
                return TSX_EMACHO;
            sig = slice + dataoff;
            sig_len = datasize;
            break;
        }
        off += cmdsize;
    }
    if (!sig) return TSX_EMACHO;

    const uint8_t *cd = NULL;
    size_t cd_len = 0;
    uint32_t magic = le32(sig);

    if (magic == TSX_CS_EMBEDDED_SIGNATURE) {
        if (sig_len < 12) return TSX_EMACHO;
        uint32_t count = le32(sig + 8);
        if (count == 0 || count > 128 || 12 + (size_t)count * 8 > sig_len)
            return TSX_EMACHO;
        for (uint32_t i = 0; i < count; i++) {
            uint32_t type = le32(sig + 12 + i * 8);
            uint32_t coff = le32(sig + 12 + i * 8 + 4);
            if (type == TSX_CSSLOT_CODEDIRECTORY) {
                if ((uint64_t)coff + 8 > sig_len) return TSX_EMACHO;
                cd = sig + coff;
                cd_len = sig_len - coff;
                break;
            }
        }
    } else if (magic == TSX_CS_CODEDIRECTORY) {
        cd = sig;
        cd_len = sig_len;
    }
    if (!cd) return TSX_EMACHO;

    uint32_t blob_len = le32(cd + 4);
    if (blob_len < 44 || (size_t)blob_len > cd_len) return TSX_EMACHO;

    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(cd, blob_len, digest);
    memcpy(out, digest, TSX_HASH_LEN);
    return TSX_OK;
}

int tsx_cdhash_file(const char *path, uint8_t out[TSX_HASH_LEN]) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return TSX_EIO;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 32) {
        close(fd);
        return TSX_EIO;
    }
    void *map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return TSX_EIO;

    size_t slice_len = 0;
    const uint8_t *slice =
        pick_slice(map, (size_t)st.st_size, &slice_len);
    int rc = TSX_EMACHO;
    if (slice) rc = cdhash_from_image(slice, slice_len, out);
    munmap(map, (size_t)st.st_size);
    return rc;
}

static bool tc_header(uint64_t addr, uint32_t *num_out) {
    uint64_t ver = 0;
    uint32_t num = 0;
    if (!KR(addr, &ver, 8)) return false;
    if ((uint32_t)ver != 1 && (uint32_t)ver != 2) return false;
    if (!KR(addr + 8, &num, 4)) return false;
    if (num > TSX_TC_CAPACITY) return false;
    if (num_out) *num_out = num;
    return true;
}

static int tc_first(uint64_t *out) {
    uint64_t sym = tsx_kexp_active()->kallsyms("trust_cache_list");
    if (!sym) return TSX_ENOSYM;

    uint32_t n;
    if (tc_header(sym, &n)) { *out = sym; return TSX_OK; }

    uint64_t a = 0;
    if (!KR(sym, &a, 8) || !kptr(a)) return TSX_ENOSYM;
    if (tc_header(a, &n)) { *out = a; return TSX_OK; }

    uint64_t b = 0;
    if (!KR(a, &b, 8) || !kptr(b)) return TSX_ENOSYM;
    if (tc_header(b, &n)) { *out = b; return TSX_OK; }
    return TSX_ENOSYM;
}

// list topology is build-specific: probe the plausible link field offsets
// and accept the first one that lands on another valid trust cache page
static int tc_next(uint64_t cur, uint64_t *out) {
    static const uint32_t cand[] = {16, 24, 8, 0, TSX_PAGE_SIZE - 8, TSX_PAGE_SIZE - 16};
    for (size_t i = 0; i < sizeof(cand) / sizeof(cand[0]); i++) {
        uint64_t n = 0;
        if (!KR(cur + cand[i], &n, 8)) continue;
        if (n == cur || !kptr(n)) continue;
        if (tc_header(n, NULL)) { *out = n; return TSX_OK; }
    }
    return TSX_ENOSYM;
}

int tsx_tc_inject(const uint8_t cdhash[TSX_HASH_LEN]) {
    if (!tsx_kexp_active()) return TSX_ENOEXP;

    uint64_t first = 0;
    int rc = tc_first(&first);
    if (rc != TSX_OK) return rc;

    uint64_t seen[64];
    size_t nseen = 0;
    uint64_t cur = first;

    for (int depth = 0; depth < 64; depth++) {
        if (nseen < 64) seen[nseen++] = cur;

        uint32_t num = 0;
        if (!tc_header(cur, &num)) return TSX_EKREAD;

        uint8_t slot[TSX_HASH_LEN];
        for (uint32_t i = 0; i < num; i++) {
            if (!KR(cur + TSX_TC_HDR + (uint64_t)i * TSX_HASH_LEN, slot,
                   TSX_HASH_LEN))
                return TSX_EKREAD;
            if (memcmp(slot, cdhash, TSX_HASH_LEN) == 0)
                return TSX_OK;  // already trusted
        }

        if (num < TSX_TC_CAPACITY) {
            uint64_t slot_addr = cur + TSX_TC_HDR + (uint64_t)num * TSX_HASH_LEN;
            // hash lands before num increments, a racing amfi lookup never
            // sees an uninitialized slot
            if (!KW(slot_addr, cdhash, TSX_HASH_LEN)) return TSX_EKWRITE;
            uint32_t new_num = num + 1;
            if (!KW(cur + 8, &new_num, 4)) return TSX_EKWRITE;
            uint32_t check = 0;
            if (!KR(cur + 8, &check, 4) || check != new_num)
                return TSX_EKWRITE;
            return TSX_OK;
        }

        uint64_t next = 0;
        if (tc_next(cur, &next) != TSX_OK) return TSX_ENOSLOT;
        for (size_t i = 0; i < nseen; i++)
            if (seen[i] == next) return TSX_ENOSLOT;
        cur = next;
    }
    return TSX_ENOSLOT;
}

int tsx_tc_dump(void) {
    if (!tsx_kexp_active()) return TSX_ENOEXP;
    uint64_t sym = tsx_kexp_active()->kallsyms("trust_cache_list");
    printf("trust_cache_list = 0x%llx\n", (unsigned long long)sym);
    if (!sym) return TSX_ENOSYM;

    uint64_t first = 0;
    int rc = tc_first(&first);
    if (rc != TSX_OK) return rc;

    uint64_t cur = first;
    uint64_t seen[64];
    size_t nseen = 0;
    for (int depth = 0; depth < 64; depth++) {
        if (nseen < 64) seen[nseen++] = cur;
        uint32_t num = 0;
        if (!tc_header(cur, &num)) return TSX_EKREAD;
        printf("  cache[%d] @ 0x%llx  %u/%d hashes\n", depth,
               (unsigned long long)cur, num, TSX_TC_CAPACITY);
        uint64_t next = 0;
        if (tc_next(cur, &next) != TSX_OK) break;
        bool loop = false;
        for (size_t i = 0; i < nseen; i++)
            if (seen[i] == next) loop = true;
        if (loop) break;
        cur = next;
    }
    return TSX_OK;
}

static bool file_is_macho(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    uint32_t magic = 0;
    ssize_t r = read(fd, &magic, 4);
    close(fd);
    if (r != 4) return false;
    return magic == FAT_MAGIC || magic == FAT_CIGAM ||
           magic == TSX_MH_MAGIC_64 || magic == 0xcffaedfeu;
}

// every executable inside a bundle needs its own cdhash trusted, amfi
// validates each Mach-O independently
int tsx_inject_bundle(const char *bundle_path) {
    DIR *d = opendir(bundle_path);
    if (!d) return -TSX_EIO;

    int injected = 0, first_err = TSX_OK;
    char path[4096];
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (ent->d_name[0] == '.') continue;
        int n = snprintf(path, sizeof(path), "%s/%s", bundle_path, ent->d_name);
        if (n <= 0 || (size_t)n >= sizeof(path)) continue;

        if (ent->d_type == DT_DIR) {
            int sub = tsx_inject_bundle(path);
            if (sub < 0) {
                if (first_err == TSX_OK) first_err = -sub;
            } else {
                injected += sub;
            }
        } else if (ent->d_type == DT_REG || ent->d_type == DT_UNKNOWN) {
            if (!file_is_macho(path)) continue;
            uint8_t hash[TSX_HASH_LEN];
            int rc = tsx_cdhash_file(path, hash);
            if (rc != TSX_OK) continue;
            rc = tsx_tc_inject(hash);
            if (rc == TSX_OK) injected++;
            else if (first_err == TSX_OK) first_err = rc;
        }
    }
    closedir(d);
    if (first_err != TSX_OK) return -first_err;
    return injected;
}
