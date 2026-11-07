// language: Objective-C, file: src/acquire.m, IPA acquisition pipeline
// resolves a VTSItem to a downloadable IPA, extracts, hands to tsx_install_package.
// resolution order: item.ipaHint -> VERTEX_MIRROR template -> VERTEX_MIRROR/{id}.ipa
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "tsx.h"
#include "vstore.h"

static NSString *const kAcquireDomain = @"VTSAcquireErrorDomain";

enum {
    VTSAcquireErrNoSource = 1,   // nothing resolved to a URL
    VTSAcquireErrEmpty    = 2,   // download produced 0 bytes
    VTSAcquireErrIO       = 3,   // temp file / extract / install failure
};

static NSError *AcqErr(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:kAcquireDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static NSString *AcqExpand(NSString *tmpl, VTSItem *item) {
    NSString *s = tmpl;
    s = [s stringByReplacingOccurrencesOfString:@"{id}"
        withString:[NSString stringWithFormat:@"%lld", (long long)item.trackId]];
    s = [s stringByReplacingOccurrencesOfString:@"{bundle}"
        withString:item.bundleId ?: @""];
    s = [s stringByReplacingOccurrencesOfString:@"{slug}"
        withString:[[item.name lowercaseString]
            stringByReplacingOccurrencesOfString:@" "
            withString:@"-"] ?: @""];
    return s;
}

// candidate URLs in priority order; mirrors may be set as a
// semicolon-separated list in VERTEX_MIRROR
static NSArray<NSString *> *AcqCandidates(VTSItem *item) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];

    if (item.ipaHint.length > 0)
        [out addObject:item.ipaHint];

    NSString *mirror = NSProcessInfo.processInfo.environment[@"VERTEX_MIRROR"];
    if (mirror.length > 0) {
        for (NSString *tmpl in [mirror componentsSeparatedByString:@";"]) {
            NSString *t = [tmpl stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length == 0) continue;
            NSString *url = AcqExpand(t, item);
            if (url.length > 0 && ![out containsObject:url])
                [out addObject:url];
        }
    }
    return out;
}

// download to a temp file, return its path (caller unlinks), nil + err on miss
static NSString *AcqDownload(NSArray<NSString *> *urls, NSError **err) {
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *dst = [tmpDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"vertex-%.0f.ipa", [NSDate date].timeIntervalSince1970]];

    for (NSString *url in urls) {
        NSError *fetchErr = nil;
        NSData *body = [VTSAppStore fetchSync:url timeout:120.0 error:&fetchErr];
        if (body.length == 0) continue;

        // reject obvious HTML error pages masquerading as an IPA
        if (body.length > 64) {
            const unsigned char *b = body.bytes;
            if (b[0] == '<' || (b[0] == '{' )) continue;
        }
        if (![body writeToFile:dst atomically:YES]) {
            if (err) *err = AcqErr(VTSAcquireErrIO,
                @"cannot write temp IPA (full disk?)");
            return nil;
        }
        return dst;
    }

    if (err)
        *err = AcqErr(VTSAcquireErrNoSource,
            urls.count == 0
                ? @"no source: set VERTEX_MIRROR or provide item.ipaHint"
                : @"every candidate source failed");
    return nil;
}

static int AcqInstall(NSString *ipaPath, bool force, NSError **err) {
    char tmp[] = "/var/tmp/vertex-acq.XXXXXX";
    if (!mkdtemp(tmp)) {
        if (err) *err = AcqErr(VTSAcquireErrIO, @"mkdtemp failed");
        return TSX_EIO;
    }

    int rc = tsx_zip_extract(ipaPath.fileSystemRepresentation, tmp);
    if (rc != TSX_OK) {
        if (err) *err = AcqErr(VTSAcquireErrIO,
            [NSString stringWithFormat:@"extract: %s", tsx_strerror(rc)]);
    } else {
        rc = tsx_install_package(tmp, force);
        if (rc != TSX_OK && err)
            *err = AcqErr(VTSAcquireErrIO,
                [NSString stringWithFormat:@"install: %s", tsx_strerror(rc)]);
    }

    char cmd[4300];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", tmp);
    if (system(cmd) != 0)
        fprintf(stderr, "warn: cleanup of %s failed\n", tmp);
    return rc;
}

int vts_acquire_item(VTSItem *item, bool force, NSError **err) {
    if (!item) {
        if (err) *err = AcqErr(VTSAcquireErrNoSource, @"nil item");
        return TSX_EINSTALL;
    }

    NSArray<NSString *> *urls = AcqCandidates(item);
    NSError *dlErr = nil;
    NSString *ipa = AcqDownload(urls, &dlErr);
    if (!ipa) {
        if (err) *err = dlErr;
        return TSX_EEXTRACT;
    }

    int rc = AcqInstall(ipa, force, err);
    unlink(ipa.fileSystemRepresentation);
    return rc;
}

// fetch <url> — single known-good IPA location, same install path
int vts_acquire_url(const char *url, bool force, NSError **err) {
    if (!url || !*url) {
        if (err) *err = AcqErr(VTSAcquireErrNoSource, @"empty url");
        return TSX_EEXTRACT;
    }
    NSArray<NSString *> *urls = @[ [NSString stringWithUTF8String:url] ];
    NSError *dlErr = nil;
    NSString *ipa = AcqDownload(urls, &dlErr);
    if (!ipa) {
        if (err) *err = dlErr;
        return TSX_EEXTRACT;
    }

    int rc = AcqInstall(ipa, force, err);
    unlink(ipa.fileSystemRepresentation);
    return rc;
}
