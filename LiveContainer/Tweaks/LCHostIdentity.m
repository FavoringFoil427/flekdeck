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
//  FlekDeck.app, whose Info.plist carries encryptedUdid because the signing
//  service injects it there. In multitask mode it is PlugIns/LiveProcess.appex,
//  which never had the key, so those checks quietly failed in parallel and
//  nowhere else.
//
//  The value cannot be written into the appex's Info.plist: an app cannot write
//  inside its own bundle on iOS, and the appex seals Info.plist in its own
//  _CodeSignature/CodeResources. It is supplied at runtime instead, by two means:
//
//    1. the CFBundle info dictionary is patched in place, which covers both the
//       Objective-C accessors and the CoreFoundation ones. NSBundle is layered
//       over CFBundle rather than bridged to it, so swizzling ObjC methods does
//       nothing for a reader that calls CFBundleGetValueForInfoDictionaryKey —
//       this repo already treats the two as separate patch surfaces.
//    2. the two NSBundle accessors are hooked as well, and left in place even
//       when (1) succeeds, to cover a Foundation that hands back a copy or a
//       CFBundle that rebuilds its dictionary later and drops the key.
//
//  The value itself comes from the app group, where the host app publishes it at
//  launch, rather than from walking up to the app bundle on disk: the extension
//  hosting a guest is not necessarily the one inside the app that published it.
//
//  Self-disabling: if the signing service ever injects the key into the appex
//  too, the values match and nothing is installed.
//
@import Foundation;
@import CoreFoundation;
@import ObjectiveC;

#import <stdatomic.h>
#import <dlfcn.h>
#import <sys/stat.h>

#import "utils.h"
#import "Tweaks.h"
#import "../FoundationPrivate.h"

static NSBundle* hostProcessBundle = nil;
static NSString* hostEncryptedUdid = nil;
static NSDictionary* patchedInfoDictionary = nil;


// Whether anything ever actually asked. Without this the diagnostic can only say
// the hook installed, which is not the same fact and was mistaken for it once
// already. The return address is captured rather than resolved: dladdr takes the
// loader lock, and this runs on whatever thread the guest reads from.
static atomic_int identityReadCount = 0;
static _Atomic(void*) firstReaderAddress = NULL;

// Which app this guest is. The captured return address can only ever name an
// *image*, which is not the question being asked: the first caller is usually a
// framework rather than the app, and dladdr resolves to nothing at all when the
// address lands in a hook trampoline — LiveContainer installs plenty of those,
// and an unresolved address was being written out as an empty string, so the row
// fell back to saying "guest code". The guest knows its own identity for free, so
// record that as the answer and keep the image name as a supporting detail.
static NSString* guestAppDescription = nil;

static inline void noteIdentityRead(void* returnAddress) {
    if(atomic_fetch_add(&identityReadCount, 1) == 0) {
        atomic_store(&firstReaderAddress, returnAddress);
    }
}

// Called before the hooks go in, while NSBundle.mainBundle is already the guest.
static NSString* describeGuestApp(void) {
    NSBundle* guestBundle = NSBundle.mainBundle;
    NSDictionary* info = guestBundle.infoDictionary;
    NSString* name = info[@"CFBundleDisplayName"];
    if(![name isKindOfClass:NSString.class] || name.length == 0) {
        name = info[@"CFBundleName"];
    }
    if(![name isKindOfClass:NSString.class]) {
        name = nil;
    }
    NSString* identifier = guestBundle.bundleIdentifier;
    if(name.length > 0 && identifier.length > 0) {
        return [NSString stringWithFormat:@"%@ (%@)", name, identifier];
    }
    if(name.length > 0) {
        return name;
    }
    return identifier.length > 0 ? identifier : @"";
}

@interface NSBundle(LCHostIdentity)
@end

@implementation NSBundle(LCHostIdentity)

// Both routes have to be covered: bundle.infoDictionary[@"key"] never reaches
// objectForInfoDictionaryKey:. Off the fast path this is a pointer compare.
- (NSDictionary*)hook_infoDictionary {
    NSDictionary* info = [self hook_infoDictionary];
    if(self != hostProcessBundle) {
        return info;
    }
    noteIdentityRead(__builtin_return_address(0));
    // If patching CFBundle took, the real dictionary already answers and handing
    // back a substitute would only risk disagreeing with it.
    if(info[@"encryptedUdid"]) {
        return info;
    }
    return patchedInfoDictionary ?: info;
}

- (id)hook_objectForInfoDictionaryKey:(NSString*)key {
    if(self == hostProcessBundle && [key isEqualToString:@"encryptedUdid"]) {
        noteIdentityRead(__builtin_return_address(0));
        id value = [self hook_objectForInfoDictionaryKey:key];
        return value ?: hostEncryptedUdid;
    }
    return [self hook_objectForInfoDictionaryKey:key];
}

@end

#pragma mark - Diagnostics

// Recorded to the app group, since the extension has no UI and cannot be attached
// to on someone else's device. These keys outlive the app itself, so the date is
// written alongside: a status with no timestamp reads as current when it is not.
static void recordOutcome(NSString* status, NSString* detail, NSString* resolvedUdid) {
    NSUserDefaults* sharedDefaults = NSUserDefaults.lcSharedDefaults;
    if(!sharedDefaults) return;
    [sharedDefaults setObject:status forKey:@"LCHostIdentityStatus"];
    [sharedDefaults setObject:detail ?: @"" forKey:@"LCHostIdentityDetail"];
    [sharedDefaults setObject:resolvedUdid ?: @"" forKey:@"LCHostIdentityUdid"];
    [sharedDefaults setObject:NSDate.now forKey:@"LCHostIdentityDate"];
}

// Flushed from a background queue well after launch: resolving the reader means
// dladdr, and the one place it must never run is the window this hook installs in,
// where dyld's recursive lock is disabled while the guest binary loads.
static void scheduleReadReport(void) {
    for(int pass = 1; pass <= 3; pass++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)pass * 10 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSUserDefaults* sharedDefaults = NSUserDefaults.lcSharedDefaults;
            if(!sharedDefaults) return;

            int reads = atomic_load(&identityReadCount);
            [sharedDefaults setObject:@(reads) forKey:@"LCHostIdentityReads"];

            // The answer to "which app asked", which is the one the diagnostic
            // exists to give and the one that cannot fail to resolve.
            [sharedDefaults setObject:guestAppDescription ?: @"" forKey:@"LCHostIdentityReaderApp"];

            NSString* reader = @"";
            NSString* readerFingerprint = @"";
            void* address = atomic_load(&firstReaderAddress);
            Dl_info info;
            if(address && dladdr(address, &info) && info.dli_fname) {
                const char* lastSlash = strrchr(info.dli_fname, '/');
                reader = @(lastSlash ? lastSlash + 1 : info.dli_fname);
                // Size and build date of the dylib that asked. Two installs of the
                // same tweak agree on both; two different builds almost never do.
                // This exists because the alternative — comparing the files by hand —
                // means moving them between devices, which is not always possible.
                struct stat readerStat;
                if(stat(info.dli_fname, &readerStat) == 0) {
                    NSDateFormatter* formatter = [NSDateFormatter new];
                    formatter.dateFormat = @"yyyy-MM-dd";
                    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
                    readerFingerprint = [NSString stringWithFormat:@"%lld bytes · %@",
                                         (long long)readerStat.st_size,
                                         [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:readerStat.st_mtimespec.tv_sec]]];
                }
            } else if(address) {
                // Said out loud rather than left blank. A caller inside a hook
                // trampoline belongs to no image, so this is expected often
                // enough that silence was being read as "nothing asked".
                reader = [NSString stringWithFormat:@"unresolved caller %p", address];
            }
            [sharedDefaults setObject:reader forKey:@"LCHostIdentityReader"];
            [sharedDefaults setObject:readerFingerprint forKey:@"LCHostIdentityReaderFingerprint"];
        });
    }
}

#pragma mark - CoreFoundation

// Writes the key into the dictionary both the ObjC and the CF accessors read, so a
// guest calling CFBundleGetValueForInfoDictionaryKey is covered too. Every step is
// guarded, and a failure is a recorded string rather than a dead guest.
static BOOL patchCoreFoundationInfoDictionary(NSBundle* bundle, NSString* udid, NSString** failure) {
    if(![bundle respondsToSelector:@selector(_cfBundle)]) {
        *failure = @"no _cfBundle";
        return NO;
    }
    CFBundleRef bundleRef = (__bridge CFBundleRef)[bundle _cfBundle];
    if(!bundleRef || CFGetTypeID(bundleRef) != CFBundleGetTypeID()) {
        *failure = @"not a CFBundle";
        return NO;
    }
    // Cheap proof this is the extension and not the guest bundle.
    CFStringRef identifier = CFBundleGetIdentifier(bundleRef);
    if(!identifier || ![bundle.bundleIdentifier isEqualToString:(__bridge NSString*)identifier]) {
        *failure = @"bundle identity mismatch";
        return NO;
    }

    id info = (__bridge id)CFBundleGetInfoDictionary(bundleRef);
    if(![info isKindOfClass:NSDictionary.class] || ![info respondsToSelector:@selector(setObject:forKey:)]) {
        *failure = @"info dictionary not mutable";
        return NO;
    }

    // Through the ObjC bridge, never CFDictionarySetValue. CF's mutability check
    // aborts the process outright with nothing to catch, which on a tester's device
    // would surface as a guest that dies before its first frame. The ObjC path
    // raises an ordinary NSException instead.
    @try {
        [(NSMutableDictionary*)info setObject:udid forKey:@"encryptedUdid"];
    } @catch (NSException* exception) {
        *failure = @"info dictionary rejected the write";
        return NO;
    }

    // Believe the read, not the write: CF is the route the method hooks cannot
    // cover, so only CF answering correctly means it is covered.
    CFTypeRef readBack = CFBundleGetValueForInfoDictionaryKey(bundleRef, CFSTR("encryptedUdid"));
    if(![(__bridge id)readBack isKindOfClass:NSString.class] ||
       ![(__bridge NSString*)readBack isEqualToString:udid]) {
        *failure = @"CoreFoundation did not read it back";
        return NO;
    }
    return YES;
}

#pragma mark - Init

void LCHostIdentityInit(void) {
    // Single mode needs nothing: the host process bundle is already the app's.
    if(!NSUserDefaults.isLiveProcess) {
        return;
    }

    // Captured before anything is hooked, while the main bundle has already been
    // swapped to the guest's: this is what the diagnostic reports as the reader.
    guestAppDescription = describeGuestApp();

    NSBundle* appexBundle = NSUserDefaults.lcMainBundle;
    if(!appexBundle) {
        recordOutcome(@"No host process bundle to answer for", @"", nil);
        return;
    }

    // Published by the host app when it launched. Preferred over reading the app
    // bundle off disk, because the extension hosting this guest is not necessarily
    // the one inside the app that published it: with no LiveProcess.appex of its
    // own, LCUtils falls back to another LiveContainer's extension, and walking up
    // from that lands on a different app's Info.plist or on nothing at all.
    NSString* udid = [NSUserDefaults.lcSharedDefaults stringForKey:@"LCHostEncryptedUdid"];
    NSString* source = @"published by the app";

    if(![udid isKindOfClass:NSString.class] || udid.length == 0) {
        // Only reached if a guest runs before the app has ever launched with this
        // build. Same answer, found the long way.
        NSString* appBundlePath = appexBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        if(![appBundlePath hasSuffix:@".app"]) {
            recordOutcome(@"App published no identifier, and no app bundle above the extension",
                          appexBundle.bundlePath, nil);
            return;
        }
        NSString* appInfoPath = [appBundlePath stringByAppendingPathComponent:@"Info.plist"];
        udid = [NSDictionary dictionaryWithContentsOfFile:appInfoPath][@"encryptedUdid"];
        source = appBundlePath.lastPathComponent;
        if(![udid isKindOfClass:NSString.class] || udid.length == 0) {
            recordOutcome(@"No encryptedUdid in the app group or in the containing app",
                          appBundlePath, nil);
            return;
        }
    }

    NSString* existingUdid = appexBundle.infoDictionary[@"encryptedUdid"];
    if([existingUdid isKindOfClass:NSString.class] && [existingUdid isEqualToString:udid]) {
        recordOutcome(@"Extension already carries the key", @"injected at signing time", udid);
        return;
    }

    NSString* cfFailure = nil;
    BOOL patchedCoreFoundation = patchCoreFoundationInfoDictionary(appexBundle, udid, &cfFailure);

    NSMutableDictionary* patched = appexBundle.infoDictionary.mutableCopy ?: [NSMutableDictionary dictionary];
    patched[@"encryptedUdid"] = udid;

    hostProcessBundle = appexBundle;
    hostEncryptedUdid = udid;
    patchedInfoDictionary = patched;

    // Installed even when CoreFoundation took the write, both as a belt on that
    // and as the tripwire that says whether anything ever asked.
    swizzle(NSBundle.class, @selector(infoDictionary), @selector(hook_infoDictionary));
    swizzle(NSBundle.class, @selector(objectForInfoDictionaryKey:), @selector(hook_objectForInfoDictionaryKey:));
    scheduleReadReport();

    recordOutcome(@"Carried into the extension",
                  patchedCoreFoundation
                      ? [NSString stringWithFormat:@"%@, CoreFoundation patched", source]
                      : [NSString stringWithFormat:@"%@, method hooks only — %@", source, cfFailure ?: @"unknown"],
                  udid);
}
