// language: Objective-C, file: include/vstore.h, VertexStore catalog contract
// Apple iTunes Search / Lookup / RSS marketing feed, no auth required
#pragma once
#include <stdbool.h>
#ifdef __OBJC__

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const VTSStoreErrorDomain;

enum {
    VTSStoreErrNetwork = 1,   // transport failure or timeout
    VTSStoreErrHTTP    = 2,   // non-2xx status
    VTSStoreErrParse   = 3,   // JSON shape not recognized
    VTSStoreErrEmpty   = 4,   // zero results
};

@interface VTSItem : NSObject
@property (nonatomic) int64_t trackId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *seller;
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic) double price;            // 0.0 = free
@property (nonatomic, copy) NSString *currency;
@property (nonatomic, copy) NSString *artwork; // 512px when available
@property (nonatomic, copy, nullable) NSString *storeUrl;
@property (nonatomic, copy, nullable) NSString *genre;
@property (nonatomic) double rating;
@property (nonatomic) int64_t ratingCount;
@property (nonatomic) int64_t sizeBytes;
@property (nonatomic, copy, nullable) NSString *version;
@property (nonatomic, copy, nullable) NSString *minOS;
@property (nonatomic, copy, nullable) NSString *ipaHint;  // direct IPA url when a source exposes one
@property (nonatomic, readonly) BOOL paid;
@property (nonatomic, readonly) NSString *priceLabel;
+ (nullable instancetype)itemWithStoreDict:(NSDictionary *)d;
+ (nullable instancetype)itemWithFeedDict:(NSDictionary *)d;
- (NSString *)row;   // fixed-width CLI line
@end

@interface VTSAppStore : NSObject

// GET search?term=..&entity=software  -> full catalog entries, price included
+ (nullable NSArray<VTSItem *> *)search:(NSString *)term
                                country:(NSString *)cc
                                  limit:(NSInteger)limit
                                  error:(NSError **)err;

// GET lookup?id=1,2,3  -> batch metadata, used to price chart rows
+ (nullable NSArray<VTSItem *> *)lookupIds:(NSArray<NSNumber *> *)ids
                                   country:(NSString *)cc
                                     error:(NSError **)err;

+ (nullable NSArray<VTSItem *> *)lookupBundle:(NSString *)bundleId
                                       country:(NSString *)cc
                                         error:(NSError **)err;

// kind: "free" | "paid" | "grossing"  -> rss.applemarketingtools.com feed,
// then lookupIds() fills price/size/artwork the feed omits
+ (nullable NSArray<VTSItem *> *)chart:(NSString *)kind
                               country:(NSString *)cc
                                 limit:(NSInteger)limit
                                 error:(NSError **)err;

// blocking GET for the CLI/download paths; completion runs on session queue
+ (nullable NSData *)fetchSync:(NSString *)urlStr
                      timeout:(NSTimeInterval)timeout
                        error:(NSError **)err;

@end

// src/acquire.m — resolve item -> download IPA -> extract -> tsx_install_package.
// returns TSX_* code; on failure *err carries the acquire-domain detail.
int vts_acquire_item(VTSItem *item, bool force, NSError *_Nullable *_Nullable err);

// fetch a known IPA url through the same download + install path
int vts_acquire_url(const char *url, bool force, NSError *_Nullable *_Nullable err);

NS_ASSUME_NONNULL_END
#endif
