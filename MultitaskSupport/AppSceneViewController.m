//
//  AppSceneView.m
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "AppSceneViewController.h"
#import "DecoratedAppSceneViewController.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "../LiveContainerSwiftUI/Utilities/LCUtils.h"
#import "PiPManager.h"
#import "Localization.h"
#import "LCSharedUtils.h"
#import "utils.h"
#import <notify.h>
#import <stdio.h>
#import <sys/stdio.h>
#import <sys/clonefile.h>

#pragma mark - App group staging

// A private app's bundle and data container live in FlekLauncher's own
// container, which LiveProcess cannot read, so both are staged into the app
// group before the guest starts and the container is brought back when it
// exits.
//
// This used to be remove-then-copy run inline on the main thread. Both halves
// scale with the number of files rather than their size, so an app with a large
// asset tree froze the UI for seconds at each end — which is why big games and
// media-heavy apps felt so much worse to open and close than small ones, and
// why the window animation stuttered. Measured on a 20k-file tree: a recursive
// remove is ~610ms and NSFileManager's copy ~1660ms, against ~140ms to clone
// the tree and ~0.1ms to rename it.
//
// So nothing here removes or copies a tree on the path the user is waiting on:
// trees are cloned into place, displaced by a rename, and deleted later.

// Serial: two windows opening at once would otherwise race on the same staged
// bundle, and each stage is short enough that serialising them costs nothing.
static dispatch_queue_t LCStagingQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.livecontainer.multitask.staging", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Live windows per staged bundle. A bundle is shared by every window running
// that app, so it may only be staged while nobody is using it and may only be
// discarded once the last window has gone. Without this, opening a second
// window re-staged the bundle out from under the running one, and closing
// either window deleted the bundle the other was still executing from.
static NSCountedSet *LCStagedBundleUsers(void) {
    static NSCountedSet *users;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ users = [NSCountedSet new]; });
    return users;
}

static NSURL *LCStagingTrashURL(NSURL *appGroupLC) {
    return [appGroupLC URLByAppendingPathComponent:@".StagingTrash"];
}

// Deleting a large tree is one unlink per file. Renaming it into the trash is a
// single operation, which is all the caller has to wait for; the deletion
// itself happens later, off any path the user can see.
static BOOL LCDiscardTree(NSURL *url, NSURL *appGroupLC) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if(![fm fileExistsAtPath:url.path]) {
        return YES;
    }
    NSURL *trashDir = LCStagingTrashURL(appGroupLC);
    [fm createDirectoryAtURL:trashDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *grave = [trashDir URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if(rename(url.path.fileSystemRepresentation, grave.path.fileSystemRepresentation) == 0) {
        return YES;
    }
    // Same-volume rename should not fail here, but never leave the caller with
    // a path it believes is clear.
    return [fm removeItemAtURL:url error:nil];
}

static void LCSweepStagingTrash(NSURL *appGroupLC) {
    NSURL *trashDir = LCStagingTrashURL(appGroupLC);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // Its own manager: NSFileManager.defaultManager is not safe to drive
        // from an arbitrary queue while the rest of the app is using it.
        NSFileManager *fm = [NSFileManager new];
        NSArray<NSURL *> *graves = [fm contentsOfDirectoryAtURL:trashDir includingPropertiesForKeys:nil options:0 error:nil];
        for(NSURL *grave in graves) {
            [fm removeItemAtURL:grave error:nil];
        }
    });
}

// clonefile gives an APFS copy-on-write clone of an entire tree in one call: no
// file data is duplicated and no per-file copy work is done, so it costs a
// fraction of NSFileManager's copy and almost no disk.
static BOOL LCCloneTree(NSURL *src, NSURL *dst) {
    if(clonefile(src.path.fileSystemRepresentation, dst.path.fileSystemRepresentation, 0) == 0) {
        return YES;
    }
    // Not APFS, or the two ended up on different volumes. Correctness first.
    // Logged because the copy is orders of magnitude slower: if staging is ever
    // sluggish again, this line is the difference between "the clone stopped
    // working" and "something else is at fault".
    NSLog(@"[LC] staging: clonefile unavailable for %@ (%s), falling back to a full copy",
          src.lastPathComponent, strerror(errno));
    // Clear anything a half-finished clone may have left, or the copy would only
    // fail again on a destination that already exists.
    NSError *error = nil;
    [NSFileManager.defaultManager removeItemAtURL:dst error:nil];
    if([NSFileManager.defaultManager copyItemAtURL:src toURL:dst error:&error]) {
        return YES;
    }
    NSLog(@"[LC] staging: failed to stage %@: %@", src.lastPathComponent, error);
    return NO;
}

// Replace whatever is at dst with a clone of src.
static BOOL LCStageTree(NSURL *src, NSURL *dst, NSURL *appGroupLC) {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:dst.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    // Cleared even when there is nothing to stage: a container left in the app
    // group by a run that never got to clean up must not be handed to the guest
    // as though it were its own.
    LCDiscardTree(dst, appGroupLC);
    if(![fm fileExistsAtPath:src.path]) {
        return NO;
    }
    return LCCloneTree(src, dst);
}

// Blocking; call on LCStagingQueue. Returns whether the app was claimed and so
// has to be released through LCUnstageAppFromAppGroup later.
static BOOL LCStageAppToAppGroup(NSString *bundleId, NSString *dataUUID) {
    NSURL *appGroupPath = [LCSharedUtils appGroupPath];
    if(!appGroupPath) {
        return NO;
    }
    NSURL *appGroupLC = [appGroupPath URLByAppendingPathComponent:@"LiveContainer"];
    NSURL *docURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    NSFileManager *fm = NSFileManager.defaultManager;

    // Claim the bundle before touching it. Several windows can run the same app,
    // and they all execute from this one staged copy, so it may only be replaced
    // while nobody is using it — re-staging it under a running guest leaves that
    // guest unable to load anything it had not already mapped.
    NSCountedSet *users = LCStagedBundleUsers();
    BOOL bundleAlreadyInUse;
    @synchronized(users) {
        bundleAlreadyInUse = [users countForObject:bundleId] > 0;
        [users addObject:bundleId];
    }
    if(!bundleAlreadyInUse) {
        NSURL *srcBundle = [docURL URLByAppendingPathComponent:[NSString stringWithFormat:@"Applications/%@", bundleId]];
        NSURL *dstBundle = [appGroupLC URLByAppendingPathComponent:[NSString stringWithFormat:@"Applications/%@", bundleId]];
        LCStageTree(srcBundle, dstBundle, appGroupLC);
    }

    // The data container belongs to this window alone, so it is always staged
    // fresh and handed back when the window closes.
    NSURL *srcData = [docURL URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]];
    NSURL *dstData = [appGroupLC URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]];
    LCStageTree(srcData, dstData, appGroupLC);

    // Tweaks, refreshed every launch like the bundle and the container above.
    // Staging once froze this folder at whatever existed the first time the
    // device ever ran anything in parallel, so a tweak installed or updated
    // afterwards was present in single mode — which reads the live
    // Documents/Tweaks — and silently missing here. A premium check living in a
    // tweak then worked in one mode and not the other.
    //
    // Swapped in rather than overwritten in place: multitask runs several guests
    // at once, and clearing the folder before refilling it leaves a window in
    // which a guest starting concurrently finds no tweaks at all. renameatx_np
    // with RENAME_SWAP exchanges the two directories in one step, so a guest
    // sees either the old set or the new one.
    NSURL *srcTweaks = [docURL URLByAppendingPathComponent:@"Tweaks"];
    NSURL *dstTweaks = [appGroupLC URLByAppendingPathComponent:@"Tweaks"];
    if ([fm fileExistsAtPath:srcTweaks.path]) {
        NSURL *stagedTweaks = [appGroupLC URLByAppendingPathComponent:@"Tweaks.staging"];
        LCDiscardTree(stagedTweaks, appGroupLC);
        if (LCCloneTree(srcTweaks, stagedTweaks)) {
            if (renameatx_np(AT_FDCWD, stagedTweaks.path.fileSystemRepresentation,
                             AT_FDCWD, dstTweaks.path.fileSystemRepresentation,
                             RENAME_SWAP) == 0) {
                // The swap left the previous set where the staging copy was.
                LCDiscardTree(stagedTweaks, appGroupLC);
            } else {
                // Nothing to swap with on the first ever parallel launch. Clear
                // the destination first: a plain rename will not replace a
                // non-empty directory, and failing here would leave the guest
                // running against a stale set of tweaks.
                LCDiscardTree(dstTweaks, appGroupLC);
                rename(stagedTweaks.path.fileSystemRepresentation, dstTweaks.path.fileSystemRepresentation);
            }
        }
    }

    LCSweepStagingTrash(appGroupLC);
    return YES;
}

// Blocking; call on LCStagingQueue. reclaimData brings the guest's container
// back over the local one — pass NO when the guest never started.
static void LCUnstageAppFromAppGroup(NSString *bundleId, NSString *dataUUID, BOOL reclaimData) {
    // Released first, and unconditionally: bailing out below with the claim still
    // held would pin the bundle for the rest of the session, so it would never be
    // re-staged and never cleaned up.
    NSCountedSet *users = LCStagedBundleUsers();
    BOOL wasLastUser;
    @synchronized(users) {
        [users removeObject:bundleId];
        wasLastUser = [users countForObject:bundleId] == 0;
    }

    NSURL *appGroupPath = [LCSharedUtils appGroupPath];
    if(!appGroupPath) {
        return;
    }
    NSURL *appGroupLC = [appGroupPath URLByAppendingPathComponent:@"LiveContainer"];
    NSURL *docURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    NSFileManager *fm = NSFileManager.defaultManager;

    NSURL *stagedData = [appGroupLC URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]];
    NSURL *localData = [docURL URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]];
    if(!reclaimData) {
        LCDiscardTree(stagedData, appGroupLC);
    } else if([fm fileExistsAtPath:stagedData.path]) {
        // Swapped back rather than deleted-and-copied. Besides trading a walk of
        // every file for a single rename, this removes the window in which the
        // local container had been deleted and its replacement not yet written:
        // being killed in there used to lose the guest's data outright.
        //
        // Nothing below clears the local container until its replacement is
        // somewhere safe, so a failure at any step costs the session's changes
        // at worst, never the container.
        BOOL localExists = [fm fileExistsAtPath:localData.path];
        if(localExists &&
           renameatx_np(AT_FDCWD, stagedData.path.fileSystemRepresentation,
                        AT_FDCWD, localData.path.fileSystemRepresentation,
                        RENAME_SWAP) == 0) {
            // The swap left the pre-launch copy where the staged one was.
            LCDiscardTree(stagedData, appGroupLC);
        } else if(!localExists &&
                  rename(stagedData.path.fileSystemRepresentation, localData.path.fileSystemRepresentation) == 0) {
            // First run of this container, so there was nothing to swap with.
        } else {
            // Swapping is unsupported here. Land a copy beside the container
            // first and only then put it in place.
            NSURL *incoming = [localData URLByAppendingPathExtension:@"incoming"];
            LCDiscardTree(incoming, appGroupLC);
            if(LCCloneTree(stagedData, incoming)) {
                LCDiscardTree(localData, appGroupLC);
                if(rename(incoming.path.fileSystemRepresentation, localData.path.fileSystemRepresentation) == 0) {
                    LCDiscardTree(stagedData, appGroupLC);
                } else {
                    NSLog(@"[LC] staging: failed to reclaim container %@: %s", dataUUID, strerror(errno));
                }
            } else {
                NSLog(@"[LC] staging: could not copy container %@ back, leaving it staged", dataUUID);
            }
        }
    }

    // The bundle is shared between every window running this app, so it only
    // goes once the last of them has exited.
    if(wasLastUser) {
        NSURL *stagedBundle = [appGroupLC URLByAppendingPathComponent:[NSString stringWithFormat:@"Applications/%@", bundleId]];
        LCDiscardTree(stagedBundle, appGroupLC);
    }

    LCSweepStagingTrash(appGroupLC);
}

@interface AppSceneViewController()
@property int resizeDebounceToken;
@property CGPoint normalizedOrigin;
@property bool isNativeWindow;
@property NSUUID* identifier;
@property bool stagedToAppGroup;
@end

@interface AppSceneViewController()
@property(nonatomic) UIWindowScene *hostScene;
@property(nonatomic) NSString *sceneID;
@property(nonatomic) NSExtension* extension;
@property(nonatomic, readwrite) bool isAppTerminationCleanUpCalled;
@end

@implementation AppSceneViewController

// Readonly with a hand-written getter, so the backing store is not synthesized.
@synthesize audio = _audio;


- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    self.view = [[UIView alloc] init];
    // Black, not clear: the guest's presentation view doesn't always cover this
    // view (aspect mismatch, mid-rotation), and a clear backdrop would let the
    // decorated container's colour show through the gap.
    self.view.backgroundColor = UIColor.blackColor;
    self.contentView = [[UIView alloc] init];
    [self.view addSubview:_contentView];
    self.delegate = delegate;
    self.dataUUID = dataUUID;
    self.bundleId = bundleId;
    self.scaleRatio = 1.0;
    self.isAppTerminationCleanUpCalled = false;
    self.settings = [UIMutableApplicationSceneSettings new];
    // init extension
    NSError* error = nil;
    _extension = [NSExtension extensionWithIdentifier:LCUtils.liveProcessBundleIdentifier error:&error];
    if(error) {
        [delegate appSceneVC:self didInitializeWithError:error];
        return nil;
    }
    _extension.preferredLanguages = @[];
    
    NSExtensionItem *item = [NSExtensionItem new];
    NSMutableArray* bookmarks = [NSMutableArray array];
    NSMutableDictionary *userInfo = @{
        @"hostUrlScheme": NSUserDefaults.lcAppUrlScheme,
        @"selected": _bundleId,
        @"selectedContainer": _dataUUID,
        @"bookmarks": bookmarks,
        @"lcHomePath": NSHomeDirectory(),
    }.mutableCopy;
    
    NSString* launchAppUrlScheme = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    [NSUserDefaults.lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
    if(launchAppUrlScheme) {
        [userInfo setValue:launchAppUrlScheme forKey:@"launchAppUrlScheme"];
    }
    
    NSURL *docURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"LCSharePrivateDataWithLiveProcess"]) {
        NSData* bookmarkData = [docURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
        if(bookmarkData) {
            [bookmarks addObject:bookmarkData];
        }
    }
    
    item.userInfo = userInfo;

    __weak typeof(self) weakSelf = self;
    [_extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *error) {
        [weakSelf appTerminationCleanUp];
        [weakSelf.delegate appSceneVC:weakSelf didInitializeWithError:error];
    }];
    [_extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];

    _isNativeWindow = [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode" ] == 1;

    // Local app files are staged into the app group so the extension can reach
    // them (security-scoped bookmarks are unreliable on iOS 26+). That walks the
    // whole bundle and data container, so it runs on the staging queue and the
    // guest starts once it is finished — the window can be built and animated in
    // while it happens, instead of the main thread sitting on it.
    bool isSharedApp = false;
    [LCSharedUtils findBundleWithBundleId:bundleId isSharedAppOut:&isSharedApp];
    if (isSharedApp) {
        [self beginExtensionRequestWithItem:item delegate:delegate];
    } else {
        NSString *stagingBundleId = bundleId;
        NSString *stagingDataUUID = dataUUID;
        dispatch_async(LCStagingQueue(), ^{
            BOOL staged = LCStageAppToAppGroup(stagingBundleId, stagingDataUUID);
            dispatch_async(dispatch_get_main_queue(), ^{
                AppSceneViewController *strongSelf = weakSelf;
                if(!strongSelf || strongSelf.isAppTerminationCleanUpCalled) {
                    // The window was closed while we were staging. Hand the
                    // bundle back rather than pinning it for the whole session.
                    if(staged) {
                        dispatch_async(LCStagingQueue(), ^{
                            LCUnstageAppFromAppGroup(stagingBundleId, stagingDataUUID, NO);
                        });
                    }
                    return;
                }
                strongSelf.stagedToAppGroup = staged;
                [strongSelf beginExtensionRequestWithItem:item delegate:delegate];
            });
        });
    }

    return self;
}

// The delegate is passed in rather than read from self: -viewDidMoveToWindow:
// clears self.delegate on teardown, and this callback still has to reach the
// object that asked for the launch.
- (void)beginExtensionRequestWithItem:(NSExtensionItem *)item delegate:(id<AppSceneViewControllerDelegate>)delegate {
    [_extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *identifier) {
        if(identifier) {
            [MultitaskManager registerMultitaskContainerWithContainer:self.dataUUID];
            self.identifier = identifier;
            self.pid = [self.extension pidForRequestIdentifier:self.identifier];
            [delegate appSceneVC:self didInitializeWithError:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setUpAppPresenter];
            });
        } else {
            NSError* error = [NSError errorWithDomain:@"LiveProcess" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to start app. Child process has unexpectedly crashed"}];
            [delegate appSceneVC:self didInitializeWithError:error];
        }
    }];
}

- (void)setUpAppPresenter {
    RBSProcessPredicate* predicate = [PrivClass(RBSProcessPredicate) predicateMatchingIdentifier:@(self.pid)];
    
    FBProcessManager *manager = [PrivClass(FBProcessManager) sharedInstance];
    // At this point, the process is spawned and we're ready to create a scene to render in our app
    RBSProcessHandle* processHandle = [PrivClass(RBSProcessHandle) handleForPredicate:predicate error:nil];
    [manager registerProcessForAuditToken:processHandle.auditToken];
    // NSString *identifier = [NSString stringWithFormat:@"sceneID:%@-%@", bundleID, @"default"];
    self.sceneID = [NSString stringWithFormat:@"sceneID:%@-%@", @"LiveProcess", self.dataUUID];
    
    FBSMutableSceneDefinition *definition = [PrivClass(FBSMutableSceneDefinition) definition];
    definition.identity = [PrivClass(FBSSceneIdentity) identityForIdentifier:self.sceneID];
    definition.clientIdentity = [PrivClass(FBSSceneClientIdentity) identityForProcessIdentity:processHandle.identity];
    definition.specification = [UIApplicationSceneSpecification specification];
    FBSMutableSceneParameters *parameters = [PrivClass(FBSMutableSceneParameters) parametersForSpecification:definition.specification];
    
    UIMutableApplicationSceneSettings *settings = self.settings;
    settings.canShowAlerts = YES;
    settings.cornerRadiusConfiguration = [[PrivClass(BSCornerRadiusConfiguration) alloc] initWithTopLeft:self.view.layer.cornerRadius bottomLeft:self.view.layer.cornerRadius bottomRight:self.view.layer.cornerRadius topRight:self.view.layer.cornerRadius];
    settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;
    settings.foreground = YES;
    
    settings.deviceOrientation = UIDevice.currentDevice.orientation;
    settings.interfaceOrientation = UIApplication.sharedApplication.statusBarOrientation;
    if(UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
        settings.frame = CGRectMake(0, 0, self.view.frame.size.height, self.view.frame.size.width);
    } else {
        settings.frame = CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height);
    }
    //settings.interruptionPolicy = 2; // reconnect
    settings.level = 1;
    settings.persistenceIdentifier = self.dataUUID;
    if(self.isNativeWindow) {
        UIEdgeInsets defaultInsets = self.view.window.safeAreaInsets;
        settings.peripheryInsets = defaultInsets;
        settings.safeAreaInsetsPortrait = defaultInsets;
    }
    
    settings.statusBarDisabled = !self.isNativeWindow;
    //settings.previewMaximumSize =
    //settings.deviceOrientationEventsEnabled = YES;
    parameters.settings = settings;
    
    UIMutableApplicationSceneClientSettings *clientSettings = [UIMutableApplicationSceneClientSettings new];
    clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;
    clientSettings.statusBarStyle = 0;
    parameters.clientSettings = clientSettings;
    
    FBScene *scene = [[PrivClass(FBSceneManager) sharedInstance] createSceneWithDefinition:definition initialParameters:parameters];
    
    self.presenter = [scene.uiPresentationManager createPresenterWithIdentifier:self.sceneID];
    [self.presenter modifyPresentationContext:^(UIMutableScenePresentationContext *context) {
        context.appearanceStyle = 2;
    }];
    [self.presenter activate];
    
    // If we have a staging URL scheme, pass it now
    NSString *launchUrl = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    if(launchUrl) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
        [self openURLScheme:launchUrl];
    }
    
    __weak typeof(self) weakSelf = self;
    [self.extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];
    
    // Black out every layer between us and the guest's rendered content. The
    // host view sits above self.view, so colouring self.view alone still left
    // white showing wherever the guest's drawable is smaller than the container
    // (landscape aspect mismatch, mid-rotation).
    [self applyBackdropColor];

    [self.contentView addSubview:self.presenter.presentationView];
    self.contentView.layer.anchorPoint = CGPointMake(0, 0);
    self.contentView.layer.position = CGPointMake(0, 0);
    
    [self.view.window.windowScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];
}

- (void)terminate {
    if(self.isAppRunning) {
        [self.extension _kill:SIGTERM];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.extension _kill:SIGKILL];
        });
    } else {
        // No process to signal yet — most likely the window was closed while its
        // files were still being staged. Tear down anyway: that releases the
        // staged bundle and stops a guest that has not started from outliving
        // the window that asked for it. A no-op if the teardown already ran.
        [self appTerminationCleanUp];
    }
}

- (void)_performActionsForUIScene:(UIScene *)scene withUpdatedFBSScene:(id)fbsScene settingsDiff:(FBSSceneSettingsDiff *)diff fromSettings:(UIApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType {
    if(!self.isAppRunning) {
        [self appTerminationCleanUp];
    }
    if(!diff) return;
    
    [self applyBackdropColor];
    UIMutableApplicationSceneSettings *baseSettings = [diff settingsByApplyingToMutableCopyOfSettings:settings];
    UIApplicationSceneTransitionContext *newContext = [context copy];
    newContext.actions = nil;
    if(self.isNativeWindow) {
        // directly update the settings
        baseSettings.interruptionPolicy = 0;
        baseSettings.peripheryInsets = self.view.window.safeAreaInsets;
        [self.presenter.scene updateSettings:baseSettings withTransitionContext:newContext completion:nil];
    } else {
        [self.delegate appSceneVC:self didUpdateFromSettings:baseSettings transitionContext:newContext];
    }
}

// Re-stamped rather than set once: UIKit can swap or re-style the presentation
// view when the guest flips orientation, which would drop a one-shot colour.
- (void)applyBackdropColor {
    self.view.backgroundColor = UIColor.blackColor;
    self.contentView.backgroundColor = UIColor.blackColor;
    self.presenter.presentationView.backgroundColor = UIColor.blackColor;
}

- (void)viewWillLayoutSubviews {
    [self applyBackdropColor];
    [self updateFrameWithSettingsBlock:self.nextUpdateSettingsBlock];
    self.nextUpdateSettingsBlock = nil;
}
- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block {
    __block int currentDebounceToken = self.resizeDebounceToken + 1;
    _resizeDebounceToken = currentDebounceToken;
    dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC));
    dispatch_after(delay, dispatch_get_main_queue(), ^{
        if(currentDebounceToken != self.resizeDebounceToken) {
            return;
        }
        CGRect frame = CGRectMake(self.view.frame.origin.x, self.view.frame.origin.y, self.view.frame.size.width / self.scaleRatio, self.view.frame.size.height / self.scaleRatio);
        [self.presenter.scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            settings.deviceOrientation = UIDevice.currentDevice.orientation;
            settings.interfaceOrientation = self.view.window.windowScene.interfaceOrientation;
            if(UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
                CGRect frame2 = CGRectMake(frame.origin.x, frame.origin.y, frame.size.height, frame.size.width);
                settings.frame = frame2;
            } else {
                settings.frame = frame;
            }
            if(block) {
                block(settings);
            }
        }];
    });
}

- (BOOL)isAppRunning {
    return _pid > 0 && getpgid(_pid) > 0;
}

- (void)appTerminationCleanUp {
    if(_isAppTerminationCleanUpCalled) {
        return;
    }
    _isAppTerminationCleanUpCalled = true;

    [_audio invalidate];

    dispatch_async(dispatch_get_main_queue(), ^{
        // Bring the guest's container back and release the staged bundle. This
        // is off the closing path entirely now: it used to delete the local
        // container and copy thousands of files back over it while the close
        // animation was waiting to run, which is what made large apps take so
        // long to shut.
        //
        // Claimed here rather than above because staging finishes on this queue
        // too. Deciding on the main thread orders the two against each other, so
        // a window closed while it was still staging is released exactly once —
        // by whichever of the two runs second.
        if (self.stagedToAppGroup) {
            self.stagedToAppGroup = false;
            NSString *bundleId = self.bundleId;
            NSString *dataUUID = self.dataUUID;
            dispatch_async(LCStagingQueue(), ^{
                LCUnstageAppFromAppGroup(bundleId, dataUUID, YES);
            });
        }

        if(self.sceneID) {
            [[PrivClass(FBSceneManager) sharedInstance] destroyScene:self.sceneID withTransitionContext:nil];
        }
        if(self.presenter){
            [self.presenter deactivate];
            [self.presenter invalidate];
            self.presenter = nil;
        }
        
        [self.delegate appSceneVCAppDidExit:self];
        [MultitaskManager unregisterMultitaskContainerWithContainer:self.dataUUID];
    });
}

// Created on first use rather than at init: a window that is never touched
// never registers a notification token, and most never are.
- (LCGuestVolume *)audio {
    if(!_audio) {
        _audio = [[LCGuestVolume alloc] initWithDataUUID:self.dataUUID];
    }
    return _audio;
}

- (void)setBackgroundNotificationEnabled:(bool)enabled {
    if(enabled) {
        // Re-add UIApplicationDidEnterBackgroundNotification
        [NSNotificationCenter.defaultCenter addObserver:self.extension selector:@selector(_hostDidEnterBackgroundNote:) name:UIApplicationDidEnterBackgroundNotification object:UIApplication.sharedApplication];
        [NSNotificationCenter.defaultCenter addObserver:self.extension selector:@selector(_hostWillResignActiveNote:) name:UIApplicationWillResignActiveNotification object:UIApplication.sharedApplication];
    } else {
        // Remove UIApplicationDidEnterBackgroundNotification so apps like YouTube can continue playing video
        [NSNotificationCenter.defaultCenter removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApplication.sharedApplication];
        [NSNotificationCenter.defaultCenter removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApplication.sharedApplication];
    }
}

- (void)viewDidMoveToWindow:(UIWindow *)newWindow shouldAppearOrDisappear:(BOOL)appear {
    [super viewDidMoveToWindow:newWindow shouldAppearOrDisappear:appear];
    if(!newWindow) {
        if(self.sceneID) {
            [self.view.window.windowScene _unregisterSettingsDiffActionArrayForKey:self.sceneID];
        }
        self.delegate = nil;
    }
}

- (void)openURLScheme:(NSString *)urlString {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        // pull from UserDefaults.standard.setValue(launchURLStr, forKey: "launchAppUrlScheme")
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        NSURL *url = [NSURL URLWithString:urlString];
        context.payload = @{UIApplicationLaunchOptionsURLKey: urlString};
        context.actions = [NSSet setWithObject:[[UIOpenURLAction alloc] initWithURL:url]];
        return context;
    }];
}

- (void)handleStatusBarTapAction:(UIAction *)action {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        context.actions = [NSSet setWithObject:action];
        return context;
    }];
}

@end
 
