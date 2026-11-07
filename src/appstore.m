// language: Objective-C, file: src/appstore.m, VertexStore catalog client
// iTunes Search + Lookup are unauthenticated JSON; RSS charts lack price/size,
// so chart rows get a follow-up lookupIds() pass to fill metadata.
#import "vstore.h"

NSErrorDomain const VTSStoreErrorDomain = @"VTSStoreErrorDomain";

static NSString *const kSearchBase = @"https://itunes.apple.com/search";
static NSString *const kLookupBase = @"https://itunes.apple.com/lookup";
static NSString *const kRSSBase    = @"https://rss.applemarketingtools.com/api/v2";

static NSError *VTSErr(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:VTSStoreErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static NSString *VTSPercent(NSString *s) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSString *VTSPathSafe(NSString *s) {
    NSString *cc = [s stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    if (cc.length != 2) return @"us";
    NSCharacterSet *alpha = [NSCharacterSet letterCharacterSet];
    for (NSUInteger i = 0; i < cc.length; i++) {
        if (![alpha characterIsMember:[cc characterAtIndex:i]]) return @"us";
    }
    return cc;
}

static id VTSFetchJSON(NSString *urlStr, NSTimeInterval timeout, NSError **err) {
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (err) *err = VTSErr(VTSStoreErrParse, @"bad URL");
        return nil;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = timeout > 0 ? timeout : 20.0;
    req.HTTPMethod = @"GET";
    [req setValue:@"Vertex/1.0" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *body = nil;
    __block NSError *netErr = nil;
    __block NSInteger status = 0;

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            body = d;
            netErr = e;
            if ([r isKindOfClass:[NSHTTPURLResponse class]])
                status = ((NSHTTPURLResponse *)r).statusCode;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout > 0 ? timeout : 20.0) * NSEC_PER_SEC)));

    if (netErr) {
        if (err) *err = VTSErr(VTSStoreErrNetwork, netErr.localizedDescription);
        return nil;
    }
    if (status < 200 || status > 299) {
        if (err) *err = VTSErr(VTSStoreErrHTTP,
            [NSString stringWithFormat:@"HTTP %ld", (long)status]);
        return nil;
    }
    if (!body) {
        if (err) *err = VTSErr(VTSStoreErrNetwork, @"empty body");
        return nil;
    }

    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
    if (!json) {
        if (err) *err = VTSErr(VTSStoreErrParse, @"invalid JSON");
        return nil;
    }
    return json;
}

static NSString *VTSString(id v) {
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    return @"";
}

static double VTSDouble(id v) {
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [v doubleValue];
    return 0.0;
}

static int64_t VTSInt64(id v) {
    if ([v isKindOfClass:[NSNumber class]]) return [v longLongValue];
    if ([v isKindOfClass:[NSString class]]) return [v longLongValue];
    return 0;
}

@implementation VTSItem

+ (instancetype)itemWithStoreDict:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    int64_t tid = VTSInt64(d[@"trackId"]);
    NSString *name = VTSString(d[@"trackName"]);
    if (tid == 0 || name.length == 0) return nil;

    VTSItem *it = [VTSItem new];
    it.trackId   = tid;
    it.name      = name;
    it.seller    = VTSString(d[@"sellerName"]);
    it.bundleId  = VTSString(d[@"bundleId"]);
    it.price     = VTSDouble(d[@"price"]);
    it.currency  = VTSString(d[@"currency"]) ?: @"USD";
    it.artwork   = VTSString(d[@"artworkUrl512"]);
    if (it.artwork.length == 0) it.artwork = VTSString(d[@"artworkUrl100"]);
    it.storeUrl  = VTSString(d[@"trackViewUrl"]);
    it.genre     = VTSString(d[@"primaryGenreName"]);
    it.rating    = VTSDouble(d[@"averageUserRating"]);
    it.ratingCount = VTSInt64(d[@"userRatingCount"]);
    it.sizeBytes = VTSInt64(d[@"fileSizeBytes"]);
    it.version   = VTSString(d[@"version"]);
    it.minOS     = VTSString(d[@"minimumOsVersion"]);
    it.ipaHint   = VTSString(d[@"ipaHint"]);
    return it;
}

+ (instancetype)itemWithFeedDict:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    NSString *tidStr = VTSString(d[@"id"]);
    int64_t tid = tidStr.longLongValue;
    NSString *name = VTSString(d[@"name"]);
    if (tid == 0 || name.length == 0) return nil;

    VTSItem *it = [VTSItem new];
    it.trackId   = tid;
    it.name      = name;
    it.seller    = VTSString(d[@"artistName"]);
    it.bundleId  = VTSString(d[@"bundleId"]);
    it.artwork   = VTSString(d[@"artworkUrl100"]);
    if (it.artwork.length == 0) it.artwork = VTSString(d[@"artworkUrl512"]);
    it.genre     = VTSString(d[@"genres"].firstObject);
    if (it.genre.length == 0) it.genre = VTSString(d[@"primaryGenreName"]);
    it.price     = 0.0;
    it.currency  = @"USD";
    it.rating    = VTSDouble(d[@"averageUserRating"]);
    it.ratingCount = VTSInt64(d[@"userRatingCount"]);
    return it;
}

- (BOOL)paid {
    return self.price > 0.0;
}

- (NSString *)priceLabel {
    if (self.price <= 0.0) return @"FREE";
    NSNumberFormatter *f = [NSNumberFormatter new];
    f.numberStyle = NSNumberFormatterCurrencyStyle;
    f.currencyCode = self.currency.length ? self.currency : @"USD";
    NSString *s = [f stringFromNumber:@(self.price)];
    return s ?: [NSString stringWithFormat:@"%.2f", self.price];
}

- (NSString *)row {
    NSString *price = self.priceLabel;
    while (price.length < 9) price = [@" " stringByAppendingString:price];
    NSString *name = self.name;
    if (name.length > 34) name = [[name substringToIndex:33] stringByAppendingString:@"…"];
    while (name.length < 34) name = [name stringByAppendingString:@" "];
    NSString *seller = self.seller;
    if (seller.length > 22) seller = [[seller substringToIndex:21] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@"%@  %@  %@  id=%lld",
            price, name, seller, (long long)self.trackId];
}

@end

@implementation VTSAppStore

+ (NSArray<VTSItem *> *)search:(NSString *)term
                       country:(NSString *)cc
                         limit:(NSInteger)limit
                         error:(NSError **)err {
    if (term.length == 0) {
        if (err) *err = VTSErr(VTSStoreErrEmpty, @"empty search term");
        return nil;
    }
    NSString *url = [NSString stringWithFormat:
        @"%@?term=%@&entity=software&limit=%ld&country=%@",
        kSearchBase, VTSPercent(term), (long)MAX(1, MIN(limit, 200)), VTSPathSafe(cc)];

    id json = VTSFetchJSON(url, 20.0, err);
    if (!json) return nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (err) *err = VTSErr(VTSStoreErrParse, @"search: root not object");
        return nil;
    }
    NSArray *results = ((NSDictionary *)json)[@"results"];
    if (![results isKindOfClass:[NSArray class]]) {
        if (err) *err = VTSErr(VTSStoreErrParse, @"search: no results array");
        return nil;
    }

    NSMutableArray<VTSItem *> *out = [NSMutableArray arrayWithCapacity:results.count];
    for (id d in results) {
        VTSItem *it = [VTSItem itemWithStoreDict:d];
        if (it) [out addObject:it];
    }
    if (out.count == 0) {
        if (err) *err = VTSErr(VTSStoreErrEmpty, @"no matches");
        return nil;
    }
    return out;
}

+ (NSArray<VTSItem *> *)lookupIds:(NSArray<NSNumber *> *)ids
                          country:(NSString *)cc
                            error:(NSError **)err {
    if (ids.count == 0) {
        if (err) *err = VTSErr(VTSStoreErrEmpty, @"no ids");
        return nil;
    }
    NSMutableString *joined = [NSMutableString string];
    for (NSNumber *n in ids) {
        if (joined.length) [joined appendString:@","];
        [joined appendFormat:@"%lld", n.longLongValue];
    }
    NSString *url = [NSString stringWithFormat:@"%@?id=%@&country=%@",
                     kLookupBase, joined, VTSPathSafe(cc)];

    id json = VTSFetchJSON(url, 20.0, err);
    if (!json) return nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (err) *err = VTSErr(VTSStoreErrParse, @"lookup: root not object");
        return nil;
    }
    NSArray *results = ((NSDictionary *)json)[@"results"];
    if (![results isKindOfClass:[NSArray class]]) {
        if (err) *err = VTSErr(VTSStoreErrParse, @"lookup: no results array");
        return nil;
    }

    NSMutableArray<VTSItem *> *out = [NSMutableArray arrayWithCapacity:results.count];
    for (id d in results) {
        VTSItem *it = [VTSItem itemWithStoreDict:d];
        if (it) [out addObject:it];
    }
    return out;
}

+ (NSArray<VTSItem *> *)lookupBundle:(NSString *)bundleId
                             country:(NSString *)cc
                               error:(NSError **)err {
    if (bundleId.length == 0) {
        if (err) *err = VTSErr(VTSStoreErrEmpty, @"empty bundle id");
        return nil;
    }
    NSString *url = [NSString stringWithFormat:@"%@?bundleId=%@&country=%@",
                     kLookupBase, VTSPercent(bundleId), VTSPathSafe(cc)];

    id json = VTSFetchJSON(url, 20.0, err);
    if (!json) return nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (err) *err = VTSErr(VTSStoreErrParse, @"lookupBundle: root not object");
        return nil;
    }
    NSArray *results = ((NSDictionary *)json)[@"results"];
    if (![results isKindOfClass:[NSArray class]]) {
        if (err) *err = VTSErr(VTSStoreErrParse, @"lookupBundle: no results array");
        return nil;
    }

    NSMutableArray<VTSItem *> *out = [NSMutableArray array];
    for (id d in results) {
        VTSItem *it = [VTSItem itemWithStoreDict:d];
        if (it) [out addObject:it];
    }
    if (out.count == 0) {
        if (err) *err = VTSErr(VTSStoreErrEmpty, @"bundle not found");
        return nil;
    }
    return out;
}

+ (NSArray<VTSItem *> *)chart:(NSString *)kind
                      country:(NSString *)cc
                        limit:(NSInteger)limit
                        error:(NSError **)err {
    NSString *feed = kind.length ? kind.lowercaseString : @"free";
    if (![feed isEqualToString:@"free"] &&
        ![feed isEqualToString:@"paid"] &&
        ![feed isEqualToString:@"grossing"]) {
        if (err) *err = VTSErr(VTSStoreErrParse,
            @"chart kind must be free, paid or grossing");
        return nil;
    }
    NSInteger n = MAX(1, MIN(limit, 100));
    NSString *url = [NSString stringWithFormat:@"%@/%@/apps/top-%@/%ld/apps.json",
                     kRSSBase, VTSPathSafe(cc), feed, (long)n];

    id json = VTSFetchJSON(url, 20.0, err);
    if (!json) return nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (err) *err = VTSErr(VTSStoreErrParse, @"chart: root not object");
        return nil;
    }
    NSDictionary *feedDict = ((NSDictionary *)json)[@"feed"];
    NSArray *entryArr = [feedDict isKindOfClass:[NSDictionary class]]
        ? feedDict[@"results"] : nil;
    if (![entryArr isKindOfClass:[NSArray class]]) {
        if (err) *err = VTSErr(VTSStoreErrParse, @"chart: no results feed");
        return nil;
    }

    NSMutableArray<VTSItem *> *feedItems = [NSMutableArray arrayWithCapacity:entryArr.count];
    NSMutableArray<NSNumber *> *ids = [NSMutableArray arrayWithCapacity:entryArr.count];
    for (id d in entryArr) {
        VTSItem *it = [VTSItem itemWithFeedDict:d];
        if (it) {
            [feedItems addObject:it];
            [ids addObject:@(it.trackId)];
        }
    }
    if (feedItems.count == 0) {
        if (err) *err = VTSErr(VTSStoreErrEmpty, @"chart feed empty");
        return nil;
    }

    // feed omits price/size — one batch lookup restores full metadata,
    // order preserved by rebuilding from the id list
    NSMutableArray<VTSItem *> *priced = [NSMutableArray arrayWithCapacity:feedItems.count];
    NSArray<VTSItem *> *full = [self lookupIds:ids country:cc error:NULL];
    NSMutableDictionary<NSNumber *, VTSItem *> *byId = [NSMutableDictionary dictionary];
    for (VTSItem *f in full) byId[@(f.trackId)] = f;

    for (VTSItem *f in feedItems) {
        VTSItem *match = byId[@(f.trackId)];
        if (match) {
            [priced addObject:match];
        } else {
            [priced addObject:f];
        }
    }
    return priced;
}

+ (NSData *)fetchSync:(NSString *)urlStr
              timeout:(NSTimeInterval)timeout
                error:(NSError **)err {
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (err) *err = VTSErr(VTSStoreErrParse, @"bad download URL");
        return nil;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = timeout > 0 ? timeout : 60.0;
    req.HTTPMethod = @"GET";
    [req setValue:@"Vertex/1.0" forHTTPHeaderField:@"User-Agent"];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *body = nil;
    __block NSError *netErr = nil;
    __block NSInteger status = 0;

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            body = d;
            netErr = e;
            if ([r isKindOfClass:[NSHTTPURLResponse class]])
                status = ((NSHTTPURLResponse *)r).statusCode;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout > 0 ? timeout : 60.0) * NSEC_PER_SEC)));

    if (netErr) {
        if (err) *err = VTSErr(VTSStoreErrNetwork, netErr.localizedDescription);
        return nil;
    }
    if (status < 200 || status > 299) {
        if (err) *err = VTSErr(VTSStoreErrHTTP,
            [NSString stringWithFormat:@"HTTP %ld", (long)status]);
        return nil;
    }
    if (!body) {
        if (err) *err = VTSErr(VTSStoreErrNetwork, @"empty download body");
        return nil;
    }
    return body;
}

@end
