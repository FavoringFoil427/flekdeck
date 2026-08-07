//
//  ODR+GuestHooks.m
//  LiveContainer
//
//  On-demand resources are registered with ondemandd by installd at install
//  time. A guest app never goes through installd — it is just a directory in
//  LiveContainer's Documents — so the daemon has no record of its tags and
//  every NSBundleResourceRequest fails with NSBundleOnDemandResourceInvalidTagError.
//
//  Repacked IPAs of ODR games usually carry the asset packs unpacked inside the
//  app bundle already, so nothing actually needs downloading. When every file a
//  tag asks for is sitting there, serve the request locally and teach NSBundle
//  where those files live. When it isn't, get out of the way and let the real
//  request fail on its own terms rather than reporting a success the app can't use.
//

#import "utils.h"

static NSString* odrResourceDirectory = nil;
static NSDictionary<NSString*, NSArray<NSString*>*>* odrFilesForTag = nil;
static NSSet<NSString*>* odrLocalFiles = nil;

// Repackers drop the unpacked asset packs wherever they like — Documents,
// OnDemandResources, the bundle root. Look for a file we know a pack contains
// rather than guessing the folder name.
static NSString* odrFindResourceDirectory(NSBundle* bundle, NSString* sampleFile) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* root = bundle.bundlePath;

    NSMutableArray<NSString*>* directories = [NSMutableArray arrayWithObject:root];
    for(NSString* entry in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString* path = [root stringByAppendingPathComponent:entry];
        BOOL isDirectory = NO;
        if([fm fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) {
            [directories addObject:path];
        }
    }

    for(NSString* directory in directories) {
        if([fm fileExistsAtPath:[directory stringByAppendingPathComponent:sampleFile]]) return directory;
    }

    NSLog(@"[LC] ODR: %{public}s", [NSString stringWithFormat:@"%@ is not in any directory of %@; searched %@",
          sampleFile, root, [directories valueForKey:@"lastPathComponent"]].UTF8String);
    return nil;
}

static void odrSetUpIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle* bundle = NSBundle.mainBundle;
        NSString* plistPath = [bundle.bundlePath stringByAppendingPathComponent:@"OnDemandResources.plist"];
        NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if(!plist) return;

        NSDictionary* tags = plist[@"NSBundleResourceRequestTags"];
        NSDictionary* packs = plist[@"NSBundleResourceRequestAssetPacks"];
        if(!tags.count || !packs.count) return;

        // tag -> every file of every asset pack the tag covers
        NSMutableDictionary* filesForTag = [NSMutableDictionary dictionary];
        for(NSString* tag in tags) {
            NSMutableArray* files = [NSMutableArray array];
            for(NSString* packId in tags[tag][@"NSAssetPacks"]) {
                [files addObjectsFromArray:packs[packId]];
            }
            filesForTag[tag] = files;
        }

        // Find where the packs were unpacked to, if they were unpacked at all
        NSString* sampleFile = [filesForTag.allValues.firstObject firstObject];
        if(!sampleFile) return;
        NSString* directory = odrFindResourceDirectory(bundle, sampleFile);
        if(!directory) {
            NSLog(@"[LC] ODR: %{public}s declares on-demand resources but none are unpacked in the bundle", NSUserDefaults.lcGuestAppId.UTF8String);
            return;
        }

        odrResourceDirectory = directory;
        odrFilesForTag = filesForTag;
        odrLocalFiles = [NSSet setWithArray:[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]];
        NSLog(@"[LC] ODR: found %lu unpacked resources in %{public}s",
              (unsigned long)odrLocalFiles.count, directory.lastPathComponent.UTF8String);

        // Only take over NSBundle's lookup once we know we can answer it
        swizzle(NSBundle.class, @selector(pathForResource:ofType:), @selector(hook_pathForResource:ofType:));
        swizzle(NSBundle.class, @selector(URLForResource:withExtension:), @selector(hook_URLForResource:withExtension:));
    });
}

@implementation NSBundleResourceRequest(LiveContainerGuestHooks)

// Every file behind every requested tag is already in the bundle
- (BOOL)lc_isSatisfiedLocally {
    odrSetUpIfNeeded();
    if(!odrResourceDirectory || !self.tags.count) return NO;

    for(NSString* tag in self.tags) {
        NSArray* files = odrFilesForTag[tag];
        if(!files.count) return NO;
        for(NSString* file in files) {
            if(![odrLocalFiles containsObject:file]) return NO;
        }
    }
    return YES;
}

// Answer the way the real request does — off the main thread, which an app may
// well be blocking until the resources land. See lcGuestCallbackQueue().
- (void)hook_beginAccessingResourcesWithCompletionHandler:(void(^)(NSError *error))completionHandler {
    if([self lc_isSatisfiedLocally]) {
        NSLog(@"[LC] ODR: serving tags %{public}s from the bundle, skipping ondemandd", self.tags.description.UTF8String);
        dispatch_async(lcGuestCallbackQueue(), ^{
            completionHandler(nil);
        });
        return;
    }
    [self hook_beginAccessingResourcesWithCompletionHandler:completionHandler];
}

- (void)hook_conditionallyBeginAccessingResourcesWithCompletionHandler:(void(^)(BOOL resourcesAvailable))completionHandler {
    if([self lc_isSatisfiedLocally]) {
        dispatch_async(lcGuestCallbackQueue(), ^{
            completionHandler(YES);
        });
        return;
    }
    [self hook_conditionallyBeginAccessingResourcesWithCompletionHandler:completionHandler];
}

- (void)hook_endAccessingResources {
    // Nothing was ever checked out of the daemon, so there is nothing to return
    if([self lc_isSatisfiedLocally]) return;
    [self hook_endAccessingResources];
}

@end

@implementation NSBundle(LiveContainerODRHooks)

- (NSString *)lc_odrPathForFile:(NSString *)name ofType:(NSString *)extension {
    NSString* fileName = extension.length ? [name stringByAppendingPathExtension:extension] : name;
    if(!fileName || ![odrLocalFiles containsObject:fileName]) return nil;
    return [odrResourceDirectory stringByAppendingPathComponent:fileName];
}

- (NSString *)hook_pathForResource:(NSString *)name ofType:(NSString *)extension {
    NSString* path = [self hook_pathForResource:name ofType:extension];
    return path ?: [self lc_odrPathForFile:name ofType:extension];
}

- (NSURL *)hook_URLForResource:(NSString *)name withExtension:(NSString *)extension {
    NSURL* url = [self hook_URLForResource:name withExtension:extension];
    if(url) return url;
    NSString* path = [self lc_odrPathForFile:name ofType:extension];
    return path ? [NSURL fileURLWithPath:path] : nil;
}

@end

__attribute__((constructor))
static void ODRGuestHooksInit(void) {
    if(!NSUserDefaults.lcGuestAppId) return;
    swizzle(NSBundleResourceRequest.class, @selector(beginAccessingResourcesWithCompletionHandler:), @selector(hook_beginAccessingResourcesWithCompletionHandler:));
    swizzle(NSBundleResourceRequest.class, @selector(conditionallyBeginAccessingResourcesWithCompletionHandler:), @selector(hook_conditionallyBeginAccessingResourcesWithCompletionHandler:));
    swizzle(NSBundleResourceRequest.class, @selector(endAccessingResources), @selector(hook_endAccessingResources));
}
