#import "FoundationPrivate.h"
#import "AppSceneViewController.h"

API_AVAILABLE(ios(16.0))
@interface DecoratedAppSceneViewController : UIViewController<AppSceneViewControllerDelegate>
@property(nonatomic) AppSceneViewController* appSceneVC;
@property(nonatomic) UIStackView *view;
@property(nonatomic) UINavigationBar *navigationBar;
@property(nonatomic) UINavigationItem *navigationItem;
@property(nonatomic) UIView* contentView;

@property(nonatomic) BOOL isMaximized;
@property(nonatomic) CGFloat scaleRatio;
- (instancetype)initWindowName:(NSString*)windowName bundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID rootVC:(UIViewController*)rootVC;
- (void)closeWindow;
- (void)minimizeWindow;
- (void)minimizeWindowPiP;
- (void)unminimizeWindowPiP;
- (void)updateVerticalConstraints;
/// Menu for the switcher card's Customize button: copy PID, toggle PiP, and a live
/// UI-scale slider. Built here because it's a real `UIMenu` — the slider goes in via
/// `UICustomViewMenuElement`, which is private UIKit and only visible to this target.
- (UIMenu *)customizeMenu;
@property(nonatomic, copy) void (^pidAvailableHandler)(NSNumber *pid, NSError *error);
@end

