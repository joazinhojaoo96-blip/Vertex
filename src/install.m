// language: Objective-C, file: src/install.m, container install + registration
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <stdio.h>

#include "tsx.h"
#include "tsx_system.h"

#define IOS(x) NSLog(@"[tsx] %s", (x))

static NSDictionary *dumpEntitlements(NSString *binaryPath) {
    SecStaticCodeRef code = NULL;
    CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:binaryPath];
    if (SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code) !=
        errSecSuccess)
        return nil;
    CFDictionaryRef info = NULL;
    NSDictionary *ents = nil;
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info) ==
        errSecSuccess) {
        ents = [(__bridge NSDictionary *)info
            objectForKey:(id)kSecCodeInfoEntitlementsDict];
        CFRelease(info);
    }
    CFRelease(code);
    return ents;
}

static BOOL isMachoFile(NSString *path) {
    FILE *f = fopen(path.fileSystemRepresentation, "r");
    if (!f) return NO;
    uint32_t magic = 0;
    size_t r = fread(&magic, 1, 4, f);
    fclose(f);
    if (r != 4) return NO;
    return magic == 0xbebafeca || magic == 0xcafebabe ||
           magic == 0xfeedfacf || magic == 0xcffaedfe;
}

static void fixPermissionsOfAppBundle(NSString *appBundlePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator<NSURL *> *en =
        [fm enumeratorAtURL:[NSURL fileURLWithPath:appBundlePath]
      includingPropertiesForKeys:nil
                         options:0
                    errorHandler:nil];
    NSURL *url;
    while ((url = [en nextObject])) {
        chown(url.fileSystemRepresentation, 33, 33);
        chmod(url.fileSystemRepresentation, 0644);
    }
    en = [fm enumeratorAtURL:[NSURL fileURLWithPath:appBundlePath]
       includingPropertiesForKeys:nil
                          options:0
                     errorHandler:nil];
    while ((url = [en nextObject])) {
        BOOL isDir = NO;
        [fm fileExistsAtPath:url.path isDirectory:&isDir];
        if (isDir || isMachoFile(url.path))
            chmod(url.fileSystemRepresentation, 0755);
    }
}

static NSString *findAppInDir(NSString *dir) {
    NSArray *items = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:dir
                            error:nil];
    for (NSString *item in items) {
        if ([item.pathExtension isEqualToString:@"app"])
            return [dir stringByAppendingPathComponent:item];
    }
    return nil;
}

static NSSet<NSString *> *immutableAppBundleIdentifiers(void) {
    NSMutableSet<NSString *> *ids = [NSMutableSet new];
    Class enCls = NSClassFromString(@"LSEnumerator");
    if (!enCls) return ids;
    NSEnumerator *en = [enCls enumeratorForApplicationProxiesWithOptions:0];
    LSApplicationProxy *proxy;
    while ((proxy = [en nextObject])) {
        if (proxy.installed &&
            ![proxy.bundleURL.path hasPrefix:@"/private/var/containers"]) {
            NSString *bid = proxy.bundleIdentifier.lowercaseString;
            if (bid) [ids addObject:bid];
        }
    }
    return ids;
}

static BOOL containerizationForEntitlements(NSDictionary *ents,
                                            NSString **customIdOut) {
    NSNumber *noContainer = ents[@"com.apple.private.security.no-container"];
    if ([noContainer isKindOfClass:NSNumber.class] && noContainer.boolValue)
        return NO;

    id containerRequired = ents[@"com.apple.private.security.container-required"];
    if ([containerRequired isKindOfClass:NSNumber.class]) {
        if (!((NSNumber *)containerRequired).boolValue) return NO;
    } else if ([containerRequired isKindOfClass:NSString.class]) {
        *customIdOut = (NSString *)containerRequired;
    }
    return YES;
}

static NSDictionary *environmentForContainer(NSString *containerPath,
                                             BOOL containerized) {
    NSString *home = containerized ? containerPath : @"/var/mobile";
    NSString *tmp = containerized
                        ? [containerPath stringByAppendingPathComponent:@"tmp"]
                        : @"/var/tmp";
    return @{@"CFFIXED_USER_HOME" : home, @"HOME" : home, @"TMPDIR" : tmp};
}

static NSDictionary *groupContainers(NSDictionary *ents, BOOL systemGroups) {
    NSString *key = systemGroups ? @"com.apple.security.system-groups"
                                 : @"com.apple.security.application-groups";
    Class cls = NSClassFromString(systemGroups ? @"MCMSystemDataContainer"
                                               : @"MCMSharedDataContainer");
    NSArray *groupIds = ents[key];
    if (![groupIds isKindOfClass:NSArray.class] || !cls) return nil;

    NSMutableDictionary *out = [NSMutableDictionary new];
    for (NSString *groupId in groupIds) {
        if (![groupId isKindOfClass:NSString.class]) continue;
        MCMContainer *c = (MCMContainer *)[cls containerWithIdentifier:groupId
                                                    createIfNecessary:YES
                                                              existed:NULL
                                                                error:NULL];
        if (c.url) out[groupId] = c.url.path;
    }
    return out.count ? out.copy : nil;
}

static NSDictionary *pluginsForBundle(NSString *path, NSString *appId) {
    NSString *pluginsPath = [path stringByAppendingPathComponent:@"PlugIns"];
    NSArray *names = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:pluginsPath
                            error:nil];
    if (!names.count) return @{};

    NSMutableDictionary *plugins = [NSMutableDictionary new];
    for (NSString *name in names) {
        NSString *pluginPath = [pluginsPath stringByAppendingPathComponent:name];
        NSDictionary *info = [NSDictionary
            dictionaryWithContentsOfFile:
                [pluginPath stringByAppendingPathComponent:@"Info.plist"]];
        NSString *pluginId = info[@"CFBundleIdentifier"];
        NSString *pluginExec = info[@"CFBundleExecutable"];
        if (!pluginId.length || !pluginExec.length) continue;

        NSString *execPath =
            [pluginPath stringByAppendingPathComponent:pluginExec];
        NSDictionary *ents = dumpEntitlements(execPath);

        NSString *dataId = pluginId;
        BOOL containerized = containerizationForEntitlements(ents, &dataId);

        Class mcm = NSClassFromString(@"MCMPluginKitPluginDataContainer");
        NSString *containerPath = nil;
        if (mcm) {
            MCMContainer *c = (MCMContainer *)
                [mcm containerWithIdentifier:dataId
                         createIfNecessary:YES
                                   existed:NULL
                                     error:NULL];
            containerPath = c.url.path;
        }

        NSMutableDictionary *p = [NSMutableDictionary new];
        if (ents) p[@"Entitlements"] = ents;
        p[@"ApplicationType"] = @"PluginKitPlugin";
        p[@"CFBundleIdentifier"] = pluginId;
        p[@"CodeInfoIdentifier"] = pluginId;
        p[@"CompatibilityState"] = @0;
        p[@"IsContainerized"] = @(containerized);
        if (containerPath) {
            p[@"Container"] = containerPath;
            p[@"EnvironmentVariables"] =
                environmentForContainer(containerPath, containerized);
        }
        p[@"Path"] = pluginPath;
        p[@"PluginOwnerBundleID"] = appId;
        p[@"SignerOrganization"] = @"Apple Inc.";
        p[@"SignatureVersion"] = @132352;
        p[@"SignerIdentity"] = @"Apple iPhone OS Application Signing";

        id team = ents[@"com.apple.developer.team-identifier"];
        if ([team isKindOfClass:NSString.class]) p[@"TeamIdentifier"] = team;

        NSDictionary *ag = groupContainers(ents, NO);
        NSDictionary *sg = groupContainers(ents, YES);
        NSMutableDictionary *gc = [NSMutableDictionary new];
        if (ag) [gc addEntriesFromDictionary:ag];
        if (sg) [gc addEntriesFromDictionary:sg];
        if (gc.count) {
            p[@"GroupContainers"] = gc.copy;
            if (ag) p[@"HasAppGroupContainers"] = @YES;
            if (sg) p[@"HasSystemGroupContainers"] = @YES;
        }

        plugins[pluginId] = p.copy;
    }
    return plugins.count ? plugins.copy : @{};
}

static BOOL registerBundle(NSString *path, BOOL forceSystem) {
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsCls) {
        IOS("LSApplicationWorkspace class missing");
        return NO;
    }
    LSApplicationWorkspace *ws = [wsCls defaultWorkspace];

    NSDictionary *info = [NSDictionary
        dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:
                                                  @"Info.plist"]];
    NSString *appId = info[@"CFBundleIdentifier"];
    NSString *execName = info[@"CFBundleExecutable"];
    if (!appId.length || !execName.length) return NO;

    NSString *execPath = [path stringByAppendingPathComponent:execName];
    NSDictionary *ents = dumpEntitlements(execPath);

    NSString *dataId = appId;
    BOOL containerized = containerizationForEntitlements(ents, &dataId);
    NSString *containerPath = nil;
    Class dataCls = NSClassFromString(@"MCMAppDataContainer");
    if (dataCls) {
        MCMContainer *c = (MCMContainer *)
            [dataCls containerWithIdentifier:dataId
                         createIfNecessary:YES
                                   existed:NULL
                                     error:NULL];
        containerPath = c.url.path;
    }

    BOOL removableSystemApp = [[NSFileManager defaultManager]
        fileExistsAtPath:[@"/System/Library/AppSignatures"
            stringByAppendingPathComponent:appId]];
    BOOL registerAsUser = [path hasPrefix:@"/var/containers"] &&
                          !removableSystemApp && !forceSystem;

    NSMutableDictionary *dict = [NSMutableDictionary new];
    if (ents) dict[@"Entitlements"] = ents;
    dict[@"ApplicationType"] = registerAsUser ? @"User" : @"System";
    dict[@"CFBundleIdentifier"] = appId;
    dict[@"CodeInfoIdentifier"] = appId;
    dict[@"CompatibilityState"] = @0;
    dict[@"IsContainerized"] = @(containerized);
    if (containerPath) {
        dict[@"Container"] = containerPath;
        dict[@"EnvironmentVariables"] =
            environmentForContainer(containerPath, containerized);
    }
    dict[@"IsDeletable"] = @YES;
    dict[@"Path"] = path;
    dict[@"SignerOrganization"] = @"Apple Inc.";
    dict[@"SignatureVersion"] = @132352;
    dict[@"SignerIdentity"] = @"Apple iPhone OS Application Signing";
    dict[@"IsAdHocSigned"] = @YES;
    dict[@"LSInstallType"] = @1;
    dict[@"HasMIDBasedSINF"] = @0;
    dict[@"MissingSINF"] = @0;
    dict[@"FamilyID"] = @0;
    dict[@"IsOnDemandInstallCapable"] = @0;

    id team = ents[@"com.apple.developer.team-identifier"];
    if ([team isKindOfClass:NSString.class]) dict[@"TeamIdentifier"] = team;

    NSDictionary *ag = groupContainers(ents, NO);
    NSDictionary *sg = groupContainers(ents, YES);
    NSMutableDictionary *gc = [NSMutableDictionary new];
    if (ag) [gc addEntriesFromDictionary:ag];
    if (sg) [gc addEntriesFromDictionary:sg];
    if (gc.count) {
        dict[@"GroupContainers"] = gc.copy;
        if (ag) dict[@"HasAppGroupContainers"] = @YES;
        if (sg) dict[@"HasSystemGroupContainers"] = @YES;
    }

    dict[@"_LSBundlePlugins"] = pluginsForBundle(path, appId);

    if (![ws registerApplicationDictionary:dict]) {
        IOS("registerApplicationDictionary failed");
        return NO;
    }
    return YES;
}

int tsx_install_package(const char *package_dir, bool force) {
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *pkg = [NSString stringWithUTF8String:package_dir];
        NSString *appPath =
            findAppInDir([pkg stringByAppendingPathComponent:@"Payload"]);
        if (!appPath) {
            IOS("no .app inside Payload/");
            return TSX_EINSTALL;
        }

        NSDictionary *info = [NSDictionary
            dictionaryWithContentsOfFile:
                [appPath stringByAppendingPathComponent:@"Info.plist"]];
        NSString *appId = info[@"CFBundleIdentifier"];
        if (!appId.length) {
            IOS("bundle has no CFBundleIdentifier");
            return TSX_EINSTALL;
        }

        if ([immutableAppBundleIdentifiers()
                containsObject:appId.lowercaseString] &&
            !force) {
            IOS("immutable system app id, use --force");
            return TSX_EINSTALL;
        }

        // amfi checks every Mach-O in the bundle on launch, trust them all
        // before the bundle ever reaches a container
        int injected = tsx_inject_bundle(appPath.fileSystemRepresentation);
        if (injected < 0) {
            NSLog(@"[tsx] trust cache injection failed: %s",
                  tsx_strerror(-injected));
            return -injected;
        }
        NSLog(@"[tsx] %d Mach-O cdhash(es) trusted", injected);

        Class mcmApp = NSClassFromString(@"MCMAppContainer");
        NSString *markName = [NSString stringWithUTF8String:TSX_MARKER];

        MCMAppContainer *container = nil;
        if (mcmApp) {
            container = (MCMAppContainer *)
                [mcmApp containerWithIdentifier:appId
                           createIfNecessary:NO
                                     existed:NULL
                                       error:NULL];
        }
        if (container) {
            NSString *marker =
                [container.url.path stringByAppendingPathComponent:markName];
            if (![fm fileExistsAtPath:marker] && !force) {
                IOS("app already installed and not ours, use --force");
                return TSX_EINSTALL;
            }
        }

        BOOL placeholderDone = NO;
        if (!container) {
            // primary: let the system stage it (same route TrollStore uses)
            NSString *tmp = [NSTemporaryDirectory()
                stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
            NSError *copyErr = nil;
            if ([fm copyItemAtPath:pkg toPath:tmp error:&copyErr]) {
                Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
                LSApplicationWorkspace *ws =
                    wsCls ? [wsCls defaultWorkspace] : nil;
                NSError *installErr = nil;
                @try {
                    placeholderDone =
                        [ws installApplication:[NSURL fileURLWithPath:tmp]
                                   withOptions:@{
                                       @"LSInstallType" : @1,
                                       @"PackageType" : @"Placeholder"
                                   }
                                         error:&installErr];
                } @catch (NSException *ex) {
                    placeholderDone = NO;
                }
                [fm removeItemAtPath:tmp error:NULL];
                if (!placeholderDone)
                    NSLog(@"[tsx] LS install failed: %@",
                          installErr.localizedDescription);
            } else {
                NSLog(@"[tsx] temp copy failed: %@", copyErr.localizedDescription);
            }

            if (mcmApp) {
                container = (MCMAppContainer *)
                    [mcmApp containerWithIdentifier:appId
                               createIfNecessary:NO
                                         existed:NULL
                                           error:NULL];
            }
        }

        if (!container) {
            // fallback: stage the bundle ourselves through MCM
            if (!mcmApp) {
                IOS("MCMAppContainer unavailable, cannot stage bundle");
                return TSX_EINSTALL;
            }
            NSError *mcmErr = nil;
            container = (MCMAppContainer *)
                [mcmApp containerWithIdentifier:appId
                           createIfNecessary:YES
                                     existed:NULL
                                       error:&mcmErr];
            if (!container) {
                NSLog(@"[tsx] MCM container create failed: %@",
                      mcmErr.localizedDescription);
                return TSX_EINSTALL;
            }
            NSString *target = [container.url.path
                stringByAppendingPathComponent:appPath.lastPathComponent];
            NSError *mvErr = nil;
            if (![fm copyItemAtPath:appPath toPath:target error:&mvErr]) {
                NSLog(@"[tsx] bundle copy failed: %@",
                      mvErr.localizedDescription);
                return TSX_EINSTALL;
            }
        } else if (!placeholderDone || !findAppInDir(container.url.path)) {
            NSString *installed = findAppInDir(container.url.path);
            if (installed)
                [fm removeItemAtPath:installed error:NULL];
            NSString *target = [container.url.path
                stringByAppendingPathComponent:appPath.lastPathComponent];
            NSError *mvErr = nil;
            if (![fm copyItemAtPath:appPath toPath:target error:&mvErr]) {
                NSLog(@"[tsx] bundle copy failed: %@",
                      mvErr.localizedDescription);
                return TSX_EINSTALL;
            }
        }

        NSString *marker =
            [container.url.path stringByAppendingPathComponent:markName];
        if (![fm fileExistsAtPath:marker]) {
            if (![fm createFileAtPath:marker contents:[NSData data] attributes:nil]) {
                IOS("marker write failed");
                return TSX_EINSTALL;
            }
        }

        NSString *installedApp = findAppInDir(container.url.path);
        if (!installedApp) {
            IOS("no .app inside container after staging");
            return TSX_EINSTALL;
        }

        fixPermissionsOfAppBundle(installedApp);

        if (!registerBundle(installedApp, NO)) {
            IOS("registration failed");
            return TSX_EINSTALL;
        }

        NSLog(@"[tsx] installed %@ at %@", appId, installedApp);
        return TSX_OK;
    }
}

int tsx_refresh_registered(void) {
    @autoreleasepool {
        NSString *markName = [NSString stringWithUTF8String:TSX_MARKER];
        NSString *root = @"/var/containers/Bundle/Application";
        NSArray *containers = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:root
                                error:nil];
        if (!containers.count) return TSX_EIO;

        int refreshed = 0;
        int first_err = TSX_OK;
        for (NSString *name in containers) {
            NSString *dir = [root stringByAppendingPathComponent:name];
            if (![[NSFileManager defaultManager]
                    fileExistsAtPath:
                        [dir stringByAppendingPathComponent:markName]])
                continue;

            NSString *appPath = findAppInDir(dir);
            if (!appPath) continue;

            int injected = tsx_inject_bundle(appPath.fileSystemRepresentation);
            if (injected < 0) {
                if (first_err == TSX_OK) first_err = -injected;
                continue;
            }
            if (!registerBundle(appPath, NO)) {
                if (first_err == TSX_OK) first_err = TSX_EINSTALL;
                continue;
            }
            refreshed++;
            NSLog(@"[tsx] refreshed %@", appPath.lastPathComponent);
        }
        if (refreshed == 0 && first_err != TSX_OK) return first_err;
        return refreshed;
    }
}
