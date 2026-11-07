// language: C/ObjC, file: include/tsx_system.h, iOS SDK structs + private class decls
// runtime lookups only (NSClassFromString / NSClassFromString + cast) so no
// private class symbols are imported at link time
#pragma once
#include <stdint.h>

#define TSX_CS_EMBEDDED_SIGNATURE  0xfade0cc0u
#define TSX_CS_CODEDIRECTORY       0xfade0c02u
#define TSX_CSSLOT_CODEDIRECTORY   0u

#define TSX_LC_CODE_SIGNATURE      0x1du
#define TSX_MH_MAGIC_64            0xfeedfacfu
#define TSX_CPU_TYPE_ARM64         0x0100000cu

struct tsx_cs_blob {
    uint32_t magic;
    uint32_t length;
};

struct tsx_cs_index {
    uint32_t type;
    uint32_t offset;
};

struct tsx_cs_superblob {
    uint32_t magic;
    uint32_t length;
    uint32_t count;
    struct tsx_cs_index index[];
};

#ifdef __OBJC__
#import <Foundation/Foundation.h>

@interface LSBundleProxy
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic) NSURL *dataContainerURL;
@property (nonatomic, readonly) NSURL *bundleContainerURL;
@end

@interface LSApplicationProxy : LSBundleProxy
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property NSURL *bundleURL;
@property NSString *bundleType;
@property NSString *canonicalExecutablePath;
@property (nonatomic, readonly) NSDictionary *groupContainerURLs;
@property (nonatomic, readonly) NSArray *plugInKitPlugins;
@property (getter = isInstalled, nonatomic, readonly) BOOL installed;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)registerApplicationDictionary:(NSDictionary *)dict;
- (BOOL)unregisterApplication:(id)arg1;
- (BOOL)installApplication:(NSURL *)packageURL withOptions:(NSDictionary *)options error:(NSError **)error;
- (BOOL)uninstallApplication:(NSString *)bundleIdentifier withOptions:(NSDictionary *)options;
- (BOOL)applicationIsInstalled:(NSString *)bundleIdentifier;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleIdentifier;
- (NSArray<LSApplicationProxy *> *)allInstalledApplications;
@end

@interface LSEnumerator : NSEnumerator
+ (instancetype)enumeratorForApplicationProxiesWithOptions:(NSUInteger)options;
@end

@interface MCMContainer : NSObject
+ (id)containerWithIdentifier:(id)identifier createIfNecessary:(BOOL)create existed:(BOOL *)existed error:(NSError **)error;
@property (nonatomic, readonly) NSURL *url;
@end

@interface MCMAppContainer : MCMContainer
@end
@interface MCMAppDataContainer : MCMContainer
@end
@interface MCMPluginKitPluginDataContainer : MCMContainer
@end
@interface MCMSystemDataContainer : MCMContainer
@end
@interface MCMSharedDataContainer : MCMContainer
@end
#endif
