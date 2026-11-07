// language: C, file: src/zip.c, IPA extraction, zlib raw inflate only
#include "tsx.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include <zlib.h>

#define SIG_EOCD64      0x06064b50u
#define SIG_EOCD64LOC   0x07064b50u
#define SIG_EOCD        0x06054b50u
#define SIG_CENTRAL     0x02014b50u
#define SIG_LOCAL       0x04034b50u

#define MAX_ENTRIES     (1u << 20)

static uint16_t r16(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}
static uint32_t r32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t r64(const uint8_t *p) {
    return (uint64_t)r32(p) | ((uint64_t)r32(p + 4) << 32);
}

static int mkdirs(const char *path) {
    char buf[4096];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(buf)) return -1;
    memcpy(buf, path, len + 1);
    for (char *p = buf + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        if (mkdir(buf, 0755) != 0 && errno != EEXIST) return -1;
        *p = '/';
    }
    if (mkdir(buf, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

static bool path_safe(const char *name) {
    if (name[0] == '/' || name[0] == '\\') return false;
    const char *p = name;
    while (*p) {
        if (p[0] == '.' && p[1] == '.' && (p[2] == '/' || p[2] == '\0'))
            return false;
        p++;
    }
    return true;
}

static int inflate_raw(const uint8_t *src, size_t src_len, uint8_t *dst,
                       size_t dst_len) {
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    // negative windowBits = raw deflate stream, zip no-zlib-header
    if (inflateInit2(&zs, -15) != Z_OK) return -1;
    zs.next_in = (Bytef *)src;
    zs.avail_in = (uInt)src_len;
    zs.next_out = dst;
    zs.avail_out = (uInt)dst_len;
    int ret = inflate(&zs, Z_FINISH);
    size_t produced = dst_len - zs.avail_out;
    inflateEnd(&zs);
    if (ret != Z_STREAM_END || produced != dst_len) return -1;
    return 0;
}

struct entry {
    uint16_t flags;
    uint16_t method;
    uint32_t crc;
    uint64_t csize;
    uint64_t usize;
    uint64_t lho;
    const uint8_t *name;
    uint16_t namelen;
};

static int extract_entry(const uint8_t *zip, size_t zip_len,
                         const struct entry *e, const char *out_dir) {
    if (e->flags & 1) return -1;  // encrypted
    if (e->namelen == 0 || e->namelen > 1024) return -1;

    char name[1025];
    memcpy(name, e->name, e->namelen);
    name[e->namelen] = '\0';
    if (strstr(name, "..") != NULL) return -1;
    if (!path_safe(name)) return -1;

    char out[4096];
    int n = snprintf(out, sizeof(out), "%s/%s", out_dir, name);
    if (n <= 0 || (size_t)n >= sizeof(out)) return -1;

    bool is_dir = name[e->namelen - 1] == '/';
    if (is_dir) return mkdirs(out) == 0 ? 0 : -1;

    if (e->lho + 30 > zip_len) return -1;
    const uint8_t *local = zip + e->lho;
    if (r32(local) != SIG_LOCAL) return -1;
    uint16_t lnamelen = r16(local + 26);
    uint16_t lextralen = r16(local + 28);
    uint64_t data_off = e->lho + 30 + lnamelen + lextralen;
    if (data_off + e->csize > zip_len) return -1;

    char parent[4096];
    memcpy(parent, out, sizeof(parent));
    for (int i = (int)strlen(parent) - 1; i > 0; i--) {
        if (parent[i] == '/') { parent[i] = '\0'; break; }
    }
    if (mkdirs(parent) != 0) return -1;

    int fd = open(out, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;

    int rc = -1;
    const uint8_t *data = zip + data_off;

    if (e->usize > (16ull << 30)) goto done;  // >16GB single entry, hostile

    if (e->method == 0) {
        if (e->csize != e->usize) goto done;
        if (crc32(0L, data, (uInt)e->csize) != e->crc) goto done;
        size_t off = 0;
        while (off < e->usize) {
            ssize_t w = write(fd, data + off, e->usize - off);
            if (w <= 0) goto done;
            off += (size_t)w;
        }
        rc = 0;
    } else if (e->method == 8) {
        uint8_t *buf = malloc(e->usize ? e->usize : 1);
        if (!buf) goto done;
        if (inflate_raw(data, e->csize, buf, e->usize) != 0 ||
            crc32(0L, buf, (uInt)e->usize) != e->crc) {
            free(buf);
            goto done;
        }
        size_t off = 0;
        while (off < e->usize) {
            ssize_t w = write(fd, buf + off, e->usize - off);
            if (w <= 0) { free(buf); goto done; }
            off += (size_t)w;
        }
        free(buf);
        rc = 0;
    }

done:
    close(fd);
    if (rc != 0) unlink(out);
    return rc;
}

int tsx_zip_extract(const char *zip_path, const char *out_dir) {
    int fd = open(zip_path, O_RDONLY);
    if (fd < 0) return TSX_EIO;
    off_t sz = lseek(fd, 0, SEEK_END);
    if (sz < 22 || sz > (8ll << 30)) { close(fd); return TSX_EIO; }
    uint8_t *zip = malloc((size_t)sz);
    if (!zip) { close(fd); return TSX_EIO; }
    lseek(fd, 0, SEEK_SET);
    size_t got = 0;
    while (got < (size_t)sz) {
        ssize_t r = read(fd, zip + got, (size_t)sz - got);
        if (r <= 0) {
            free(zip); close(fd); return TSX_EIO;
        }
        got += (size_t)r;
    }
    close(fd);

    // EOCD scan: comment can push it back up to 64KB from the end
    size_t scan = (size_t)sz < 0x10016 ? (size_t)sz : 0x10016;
    size_t eocd = (size_t)sz - 22;
    bool found = false;
    for (size_t i = 0; i < scan - 21; i++) {
        size_t pos = (size_t)sz - 22 - i;
        if (r32(zip + pos) == SIG_EOCD) { eocd = pos; found = true; break; }
    }
    if (!found) { free(zip); return TSX_EEXTRACT; }

    uint64_t cd_off = r32(zip + eocd + 16);
    uint64_t entries = r16(zip + eocd + 10);

    if (cd_off == 0xffffffffu || entries == 0xffffu) {
        // zip64: locator sits right before the EOCD
        if (eocd < 20) { free(zip); return TSX_EEXTRACT; }
        const uint8_t *loc = zip + eocd - 20;
        if (r32(loc) != SIG_EOCD64LOC) { free(zip); return TSX_EEXTRACT; }
        uint64_t z64 = r64(loc + 8);
        if (z64 + 56 > (uint64_t)sz || r32(zip + z64) != SIG_EOCD64) {
            free(zip);
            return TSX_EEXTRACT;
        }
        entries = r64(zip + z64 + 32);
        cd_off = r64(zip + z64 + 48);
    }

    if (entries == 0 || entries > MAX_ENTRIES ||
        cd_off + entries * 46 > (uint64_t)sz) {
        free(zip);
        return TSX_EEXTRACT;
    }

    if (mkdirs(out_dir) != 0) { free(zip); return TSX_EIO; }

    size_t pos = (size_t)cd_off;
    int extracted = 0;
    int fail = 0;

    for (uint64_t i = 0; i < entries; i++) {
        if (pos + 46 > (size_t)sz || r32(zip + pos) != SIG_CENTRAL) {
            fail++;
            break;
        }
        uint16_t flags = r16(zip + pos + 8);
        uint16_t method = r16(zip + pos + 10);
        uint32_t crc = r32(zip + pos + 16);
        uint64_t csize = r32(zip + pos + 20);
        uint64_t usize = r32(zip + pos + 24);
        uint16_t namelen = r16(zip + pos + 28);
        uint16_t extralen = r16(zip + pos + 30);
        uint16_t commlen = r16(zip + pos + 32);
        uint64_t lho = r32(zip + pos + 42);

        if (pos + 46 + namelen + extralen + commlen > (size_t)sz) {
            fail++;
            break;
        }

        // zip64 sizes live in the extra field when the 32-bit slot overflowed
        if (csize == 0xffffffffu || usize == 0xffffffffu || lho == 0xffffffffu) {
            const uint8_t *xp = zip + pos + 46 + namelen;
            size_t xleft = extralen;
            while (xleft >= 4) {
                uint16_t id = r16(xp);
                uint16_t xsz = r16(xp + 2);
                if (4 + xsz > xleft) break;
                if (id == 0x0001) {
                    const uint8_t *v = xp + 4;
                    size_t need = 0;
                    if (usize == 0xffffffffu) need += 8;
                    if (csize == 0xffffffffu) need += 8;
                    if (lho == 0xffffffffu) need += 8;
                    if (need > xsz) break;
                    size_t k = 0;
                    if (usize == 0xffffffffu) { usize = r64(v + k); k += 8; }
                    if (csize == 0xffffffffu) { csize = r64(v + k); k += 8; }
                    if (lho == 0xffffffffu) { lho = r64(v + k); k += 8; }
                    break;
                }
                xp += 4 + xsz;
                xleft -= 4 + xsz;
            }
        }

        struct entry e = {
            .flags = flags, .method = method, .crc = crc,
            .csize = csize, .usize = usize, .lho = lho,
            .name = zip + pos + 46, .namelen = namelen,
        };
        if (extract_entry(zip, (size_t)sz, &e, out_dir) != 0) fail++;
        else extracted++;

        pos += 46 + namelen + extralen + commlen;
    }

    free(zip);
    if (fail) return TSX_EEXTRACT;
    if (extracted == 0) return TSX_EEXTRACT;
    return TSX_OK;
}
