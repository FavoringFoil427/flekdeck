//
//  LCHostIdentity.m
//  LiveContainer
//
//  Carries the host app's encryptedUdid across into LiveProcess.
//
//  Guest apps that gate features on a per-device identifier read it from the
//  bundle of the host *process*, not from NSBundle.mainBundle — LiveContainer
//  swaps mainBundle to the guest bundle, but +bundleForClass:, +allBundles,
//  +bundleWithIdentifier: and anything that captured Bundle.main before the swap
//  all still resolve to the process's real bundle. In single mode that is
//  FlekLauncher.app, whose Info.plist carries encryptedUdid because the signing
//  service injects it there. In multitask mode it is PlugIns/LiveProcess.appex,
//  which never had the key, so those checks quietly failed in parallel and
//  nowhere else.
//
//  The value cannot simply be written into the appex's Info.plist: an app cannot
//  write inside its own bundle on iOS, and the appex seals Info.plist in its own
//  _CodeSignature/CodeResources, so editing it would put the extension's
//  signature in question. Instead the app's Info.plist — readable, two levels up
//  from the appex — is consulted once at startup and the answer is served from
//  memory for that one bundle and that one key.
//
//  Self-disabling: if the signing service ever injects the key into the appex
//  too, the values match and nothing is installed.
//
@import Foundation;
@import ObjectiveC;

#import "utils.h"
#import "Tweaks.h"

static NSBundle* hostProcessBundle = nil;
static NSString* hostEncryptedUdid = nil;
static NSDictionary* patchedInfoDictionary = nil;

@interface NSBundle(LCHostIdentity)
@end

@implementation NSBundle(LCHostIdentity)

// Both routes have to be covered: bundle.infoDictionary[@"key"] never reaches
// objectForInfoDictionaryKey:. Everything off the fast path is a pointer compare
// against one bundle, and the patched dictionary is built once during init, so no
// call here allocates or takes a lock.
- (NSDictionary*)hook_infoDictionary {
    if(self == hostProcessBundle) {
        return patchedInfoDictionary;
    }
    return [self hook_infoDictionary];
}

- (id)hook_objectForInfoDictionaryKey:(NSString*)key {
    if(self == hostProcessBundle && [key isEqualToString:@"encryptedUdid"]) {
        return hostEncryptedUdid;
    }
    return [self hook_objectForInfoDictionaryKey:key];
}

@end

void LCHostIdentityInit(void) {
    // Single mode needs nothing: the host process bundle is already the app's.
    if(!NSUserDefaults.isLiveProcess) {
        return;
    }

    NSBundle* appexBundle = NSUserDefaults.lcMainBundle;
    if(![appexBundle.bundlePath hasSuffix:@".appex"]) {
        return;
    }

    // .../FlekLauncher.app/PlugIns/LiveProcess.appex -> .../FlekLauncher.app
    NSString* appBundlePath = appexBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    if(![appBundlePath hasSuffix:@".app"]) {
        return;
    }

    NSDictionary* appInfo = [NSDictionary dictionaryWithContentsOfFile:[appBundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSString* udid = appInfo[@"encryptedUdid"];
    if(![udid isKindOfClass:NSString.class] || udid.length == 0) {
        return;
    }

    NSString* existingUdid = appexBundle.infoDictionary[@"encryptedUdid"];
    if([existingUdid isKindOfClass:NSString.class] && [existingUdid isEqualToString:udid]) {
        return;
    }

    NSMutableDictionary* patched = appexBundle.infoDictionary.mutableCopy ?: [NSMutableDictionary dictionary];
    patched[@"encryptedUdid"] = udid;

    hostProcessBundle = appexBundle;
    hostEncryptedUdid = udid;
    patchedInfoDictionary = patched;

    swizzle(NSBundle.class, @selector(infoDictionary), @selector(hook_infoDictionary));
    swizzle(NSBundle.class, @selector(objectForInfoDictionaryKey:), @selector(hook_objectForInfoDictionaryKey:));
}
