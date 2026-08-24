//
//  AppSceneView.h
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "UIKitPrivate+MultitaskSupport.h"
#import "FoundationPrivate.h"
#import "LCGuestVolume.h"
@import UIKit;
@import Foundation;


@class AppSceneViewController;

API_AVAILABLE(ios(16.0))
@protocol AppSceneViewControllerDelegate <NSObject>
- (void)appSceneVCAppDidExit:(AppSceneViewController*)vc;
- (void)appSceneVC:(AppSceneViewController*)vc didInitializeWithError:(NSError*)error;
@optional
- (void)appSceneVC:(AppSceneViewController*)vc didUpdateFromSettings:(UIMutableApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType;
- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc;
/// The guest's scene is about to be created from these settings. The window owns
/// the geometry they carry — its own frame, the drawable the guest is handed and
/// the insets the guest keeps clear — and this is the last moment to put the
/// current answer in. A window is built long before its guest starts, and what was
/// true then is not always still true now.
- (void)appSceneVC:(AppSceneViewController*)vc willPresentSceneWithSettings:(UIMutableApplicationSceneSettings *)settings;
/// The guest's scene has been presented — its content is now on screen as fast as
/// the guest can draw it, which for an app still starting up means its own launch
/// screen. Unlike a settings update, which only arrives if the guest changes
/// something, this happens for every guest exactly once.
- (void)appSceneVCDidPresentScene:(AppSceneViewController*)vc;
@end

API_AVAILABLE(ios(16.0))
@interface AppSceneViewController : UIViewController<_UISceneSettingsDiffAction>
@property(nonatomic) NSString* bundleId;
@property(nonatomic) NSString* dataUUID;
@property(nonatomic) int pid;
@property(nonatomic) id<AppSceneViewControllerDelegate> delegate;
@property(nonatomic) BOOL isAppRunning;
@property(nonatomic) BOOL shouldIgnoreSceneUpdates, shouldSkipDebounceOnce;
@property(nonatomic) CGFloat scaleRatio;
/// Volume control for this window's guest.
@property(nonatomic, readonly) LCGuestVolume *audio;
@property(nonatomic) UIView* contentView;
@property(nonatomic) _UIScenePresenter *presenter;
@property(nonatomic) UIMutableApplicationSceneSettings *settings;
/// Applied to the scene the next time this window lays out. Set by the window
/// when geometry changes while the guest is not in a position to be told yet.
@property(nonatomic) void(^nextUpdateSettingsBlock)(UIMutableApplicationSceneSettings *settings);
/// Whether the teardown has already run, so a caller closing this window can
/// tell a guest that exited on its own from one that never got to start.
@property(nonatomic, readonly) bool isAppTerminationCleanUpCalled;
@property(nonatomic) _UISceneHostingController *hostingController API_AVAILABLE(ios(17.0));
- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate;
- (void)setBackgroundNotificationEnabled:(bool)enabled;
- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block;
- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))block;
- (void)appTerminationCleanUp;
- (void)terminate;
- (void)openURLScheme:(NSString *)urlString;
- (void)handleStatusBarTapAction:(UIAction *)action;
- (BOOL)usesHostingControllerAPI;
@end

