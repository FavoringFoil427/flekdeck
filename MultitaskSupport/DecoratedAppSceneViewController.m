#import "DecoratedAppSceneViewController.h"
#import "ResizeHandleView.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "AppSceneViewController.h"
#import "UIKitPrivate+MultitaskSupport.h"
#import "PiPManager.h"
#import "VirtualWindowsHostView.h"
#import "../LiveContainer/Localization.h"
#import "utils.h"

@implementation RBSTarget(hook)
+ (instancetype)hook_targetWithPid:(pid_t)pid environmentIdentifier:(NSString *)environmentIdentifier {
    if([environmentIdentifier containsString:@"LiveProcess"]) {
        environmentIdentifier = [NSString stringWithFormat:@"LiveProcess:%d", pid];
    }
    return [self hook_targetWithPid:pid environmentIdentifier:environmentIdentifier];
}
@end
static int hook_return_2(void) {
    return 2;
}
__attribute__((constructor))
void UIKitFixesInit(void) {
    // Fix _UIPrototypingMenuSlider not continually updating its value on iOS 17+
    Class _UIFluidSliderInteraction = objc_getClass("_UIFluidSliderInteraction");
    if(_UIFluidSliderInteraction) {
        method_setImplementation(class_getInstanceMethod(_UIFluidSliderInteraction, @selector(_state)), (IMP)hook_return_2);
    }
    // Fix physical keyboard focus on iOS 17+
    if(@available(iOS 17.0, *)) {
        method_exchangeImplementations(class_getClassMethod(RBSTarget.class, @selector(targetWithPid:environmentIdentifier:)), class_getClassMethod(RBSTarget.class, @selector(hook_targetWithPid:environmentIdentifier:)));
    }
}

@interface DecoratedAppSceneViewController()
@property(nonatomic) NSArray* activatedVerticalConstraints;
@property(nonatomic) NSString* dataUUID;
@property(nonatomic) NSString* windowName;
@property(nonatomic) int pid;
@property(nonatomic) CGRect originalFrame;
@property(nonatomic) UIBarButtonItem *maximizeButton;
@property(nonatomic) bool isAppTerminationRequested;
/// Whether the guest has already been reported as drawing its own content. The
/// cue can arrive from more than one place, so the first one wins and the rest
/// are ignored.
@property(nonatomic) BOOL didReportContentArrived;
- (void)applySceneFrameToSettings:(UIMutableApplicationSceneSettings *)settings orientation:(UIInterfaceOrientation)orientation;
@end

/// How long after its scene is presented the window keeps the launch screen it
/// opened with. The guest is drawing by then — a launch screen of its own if it
/// is still starting up — so what replaces ours is, for most apps, the same
/// picture. Long enough for that first frame to land, short enough that a guest
/// whose picture differs is not sat behind ours.
static const NSTimeInterval kContentGraceAfterScene = 0.45;

/// The last word, for a guest whose scene never gets presented at all — one that
/// dies on the way up. Nothing may leave a stand-in covering a window for good.
static const NSTimeInterval kContentArrivalLimit = 4.0;

@implementation DecoratedAppSceneViewController
- (instancetype)initWindowName:(NSString*)windowName bundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID rootVC:(UIViewController*)rootVC {
    self = [super initWithNibName:nil bundle:nil];
    _scaleRatio = 1.0;
    _isMaximized = YES;
    [rootVC addChildViewController:self];
    [MultitaskDockManager.shared.windowHostingView addSubview:self.view];
    _appSceneVC = [[AppSceneViewController alloc] initWithBundleId:bundleId dataUUID:dataUUID delegate:self];
    [self setupDecoratedView];
    
    [MultitaskDockManager.shared addRunningApp:windowName appUUID:dataUUID view:self.view];

    // The window opens immediately, carrying the app's launch screen, and drops
    // it once the guest is drawing its own. This is the last resort for a guest
    // that never gets that far.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kContentArrivalLimit * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self reportContentArrived];
    });


    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(switcherBarVisibilityChanged)
                                                 name:@"MultitaskBarVisibilityChanged"
                                               object:nil];
    
    self.dataUUID = dataUUID;
    self.windowName = windowName;
    self.navigationItem.title = windowName;
    
    return self;
}

- (void)setupDecoratedView {
    CGFloat navBarHeight = 44;
    self.view = [UIStackView new];
    BOOL isLandscape = UIInterfaceOrientationIsLandscape(UIApplication.sharedApplication.statusBarOrientation);
    CGRect frame = CGRectMake(0, 0, isLandscape ? 480 : 320, (isLandscape ? 320 : 480) + navBarHeight);
    CGPoint rootViewCenter = self.view.superview.center;
    frame.origin = CGPointMake(rootViewCenter.x - frame.size.width / 2, rootViewCenter.y - frame.size.height / 2);
    
    if(_isMaximized) {
        // Don't call updateMaximizedFrameWithSettings here — navBar not created yet.
        // The frame will be set after updateVerticalConstraints below.
        CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
        // save origin as normalized coordinates
        frame.origin.x /= maxFrame.size.width;
        frame.origin.y /= maxFrame.size.height;
        self.originalFrame = frame;
    } else {
        self.view.frame = frame;
    }
    
    // Navigation bar
    UINavigationBar *navigationBar = [[UINavigationBar alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, navBarHeight)];
    navigationBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UINavigationItem *navigationItem = [[UINavigationItem alloc] initWithTitle:@"Unnamed window"];
    navigationBar.items = @[navigationItem];
    
    self.view.axis = UILayoutConstraintAxisVertical;
    // Backdrop behind the guest scene. Black rather than systemBackground: when
    // the guest doesn't fill the container — commonly in landscape, where an app
    // that renders at a different aspect (or hasn't caught up to a rotation yet)
    // leaves strips on the sides — this is what shows through, and white strips
    // read as broken. Black matches the letterboxing every other app does.
    self.view.backgroundColor = UIColor.blackColor;
    self.view.layer.cornerRadius = 0;
    self.view.layer.masksToBounds = YES;

    self.navigationBar = navigationBar;
    self.navigationItem = navigationBar.items.firstObject;
    if (!self.navigationBar.superview) {
        [self.view addArrangedSubview:self.navigationBar];
    }
    
    CGRect contentFrame = CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height - navBarHeight);
    UIView *fixedPositionContentView = [[UIView alloc] initWithFrame:contentFrame];
    self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if([NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"]) {
        [self.view insertArrangedSubview:fixedPositionContentView atIndex:0];
    } else {
        [self.view addArrangedSubview:fixedPositionContentView];
    }
    [self.view sendSubviewToBack:fixedPositionContentView];
    
    self.contentView = [[UIView alloc] initWithFrame:contentFrame];
    self.contentView.layer.anchorPoint = self.contentView.layer.position = CGPointMake(0, 0);
    self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [fixedPositionContentView addSubview:self.contentView];
    
    self.view.layer.borderWidth = 0;
    
    [self addChildViewController:_appSceneVC];
    [self.view insertSubview:_appSceneVC.view atIndex:0];
    _appSceneVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    
    [self updateVerticalConstraints];
    [NSLayoutConstraint activateConstraints:@[
        [_appSceneVC.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_appSceneVC.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    
    // Set the maximized frame now that navBar is created and hidden
    if(_isMaximized) {
        [self updateMaximizedFrameWithSettings:self.appSceneVC.settings];
    }
    
    [self updateOriginalFrame];
}


- (UIMenu *)customizeMenu {
    __weak typeof(self) weakSelf = self;

    UIAction *copyPid = [UIAction actionWithTitle:[NSString stringWithFormat:@"%@ %d", @"lc.multitask.copyPid".loc, self.appSceneVC.pid]
                                            image:[UIImage systemImageNamed:@"doc.on.doc"]
                                       identifier:nil
                                          handler:^(UIAction *action) {
        UIPasteboard.generalPasteboard.string = @(weakSelf.appSceneVC.pid).stringValue;
    }];

    BOOL isPiPActive = [PiPManager.shared isPiPWithVC:self.appSceneVC];
    UIAction *togglePiP = [UIAction actionWithTitle:isPiPActive ? @"lc.multitask.disablePip".loc : @"lc.multitask.enablePip".loc
                                              image:[UIImage systemImageNamed:isPiPActive ? @"pip.exit" : @"pip.enter"]
                                         identifier:nil
                                            handler:^(UIAction *action) {
        if([PiPManager.shared isPiPWithVC:weakSelf.appSceneVC]) {
            [PiPManager.shared stopPiP];
        } else {
            [PiPManager.shared startPiPWithVC:weakSelf.appSceneVC];
        }
    }];

    // A real slider living inside a real menu — the reason this menu is built in
    // UIKit rather than as a SwiftUI `Menu`, which takes actions and submenus only.
    UICustomViewMenuElement *scaleSlider = [UICustomViewMenuElement elementWithViewProvider:^UIView *(UICustomViewMenuElement *element) {
        return [weakSelf scaleSliderViewWithTitle:@"lc.multitask.scale".loc
                                              min:0.5
                                              max:2.0
                                            value:weakSelf.scaleRatio
                                     stepInterval:0.01];
    }];

    return [UIMenu menuWithTitle:@"" children:@[copyPid, togglePiP, scaleSlider]];
}

- (UIView *)scaleSliderViewWithTitle:(NSString *)title min:(CGFloat)minValue max:(CGFloat)maxValue value:(CGFloat)initialValue stepInterval:(CGFloat)step {
    __weak typeof(self) weakSelf = self;
    return [DecoratedAppSceneViewController scaleSliderViewWithTitle:title min:minValue max:maxValue value:initialValue stepInterval:step onChange:^(CGFloat newValue) {
        [weakSelf applyScaleRatio:newValue];
    }];
}

// Stolen from UIKitester
+ (UIView *)scaleSliderViewWithTitle:(NSString *)title min:(CGFloat)minValue max:(CGFloat)maxValue value:(CGFloat)initialValue stepInterval:(CGFloat)step onChange:(void (^)(CGFloat newValue))onChange {
    UIView *containerView = [[UIView alloc] init];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    containerView.exclusiveTouch = YES;

    UIStackView *stackView = [[UIStackView alloc] init];
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.spacing = 0.0;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [containerView addSubview:stackView];
    
    [NSLayoutConstraint activateConstraints:@[
        [stackView.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:10.0],
        [stackView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-8.0],
        [stackView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:16.0],
        [stackView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-16.0]
    ]];
    
    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont boldSystemFontOfSize:12.0];
    [stackView addArrangedSubview:label];
    
    _UIPrototypingMenuSlider *slider = [[_UIPrototypingMenuSlider alloc] init];
    slider.minimumValue = minValue;
    slider.maximumValue = maxValue;
    slider.value = initialValue;
    slider.stepSize = step;
    
    NSLayoutConstraint *sliderHeight = [slider.heightAnchor constraintEqualToConstant:40.0];
    sliderHeight.active = YES;
    
    [stackView addArrangedSubview:slider];
    
    // UIAction rather than target/action: this builder is a class method, so there's
    // no instance to act as the target — the caller supplies the behaviour instead.
    [slider addAction:[UIAction actionWithHandler:^(UIAction *action) {
        onChange(((UISlider *)action.sender).value);
    }] forControlEvents:UIControlEventValueChanged];

    return containerView;
}

- (void)scaleSliderChanged:(_UIPrototypingMenuSlider *)slider {
    [self applyScaleRatio:slider.value];
}

- (void)applyScaleRatio:(CGFloat)newValue {
    self.scaleRatio = newValue;
    self.appSceneVC.scaleRatio = _scaleRatio;
    self.appSceneVC.contentView.layer.sublayerTransform = CATransform3DMakeScale(_scaleRatio, _scaleRatio, 1.0);
    __weak typeof(self) weakSelf = self;
    [self.appSceneVC updateFrameWithSettingsBlock:^(UIMutableApplicationSceneSettings *settings) {
        if(_isMaximized) {
            [weakSelf updateMaximizedSafeAreaWithSettings:settings];
        } else {
            // it seems some apps don't honor these settings so we don't cover the top of the app
            settings.peripheryInsets = UIEdgeInsetsZero;
            settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;
        }
    }];
}

- (void)closeWindow {
    _isAppTerminationRequested = true;
    if([_appSceneVC isAppRunning] || !_appSceneVC.isAppTerminationCleanUpCalled) {
        // -terminate covers both a running guest and one that never started —
        // the second happens when the window is closed while the app's files are
        // still being staged, and going through the teardown is what releases
        // them. Either way the teardown calls us back to close the window.
        [_appSceneVC terminate];
    } else {
        // The app already exited on its own and the teardown has run, so nothing
        // will call back; close the window directly.
        [self appSceneVCAppDidExit:self.appSceneVC];
    }
}

- (void)minimizeWindow {
    if (self.view.hidden) return;
    // Reduce Motion: the window gives way where it stands instead of collapsing
    // to a tenth of its size. The counterpart of the fade it comes back with, so
    // a guest window leaves the way it arrives.
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha = 0;
        if (!reduceMotion) {
            self.view.transform = CGAffineTransformMakeScale(0.1, 0.1);
        }
    } completion:^(BOOL finished) {
        if (!finished) return;
        [self finishMinimizeWindow];
    }];
}

/// Reports, once, that the guest is drawing its own content — the cue to drop the
/// launch screen the window opened with.
- (void)reportContentArrived {
    if (self.didReportContentArrived) return;
    self.didReportContentArrived = YES;
    // Posted rather than called, the way the bar's visibility travels the other
    // way between these two files — the dock is Swift and this is not, and a
    // notification needs neither side's generated header.
    [NSNotificationCenter.defaultCenter postNotificationName:@"LCWindowContentDidArrive" object:self.view];
}

- (void)finishMinimizeWindow {
    self.view.hidden = YES;
    self.view.transform = CGAffineTransformIdentity;
    [self.view.superview sendSubviewToBack:self.view];
}

- (void)minimizeWindowPiP {
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha = 0;
    } completion:^(BOOL finished) {
        self.view.hidden = YES;
    }];
}

- (void)unminimizeWindowPiP {
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.hidden = NO;
        self.view.alpha = 1;
    } completion:nil];
}

- (void)maximizeWindow {
    // Windows are always maximized in chromeless mode — no-op
    return;
}

- (void)appSceneVCAppDidExit:(AppSceneViewController*)vc {
    BOOL skipTerminationScreen = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCSkipTerminatedScreen"];
    BOOL isManual = _isAppTerminationRequested;
    if(isManual || skipTerminationScreen) {
        
        MultitaskDockManager *dock = [MultitaskDockManager shared];
        [dock removeRunningApp:self.dataUUID];
        
        self.view.layer.masksToBounds = NO;
        [UIView transitionWithView:self.view duration:0.4 options:UIViewAnimationOptionTransitionCurlUp animations:^{
            self.view.hidden = YES;
        } completion:^(BOOL b){
            [self.view removeFromSuperview];
        }];
        
        if(skipTerminationScreen) {
            [MultitaskRelaunchManager scheduleRelaunchIfNeededWithBundleId:self.appSceneVC.bundleId dataUUID:self.dataUUID isManualTermination:isManual];
        }
    } else {
        UILabel *label = [[UILabel alloc] initWithFrame:self.view.bounds];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.lineBreakMode = NSLineBreakByWordWrapping;
        label.numberOfLines = 0;
        label.text = NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", @"");
        label.textAlignment = NSTextAlignmentCenter;
        [self.view insertSubview:label atIndex:0];
    }
}

- (void)appSceneVC:(AppSceneViewController*)vc didInitializeWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if(error) {
            // Nothing is coming, so take the launch screen down rather than leave
            // it standing in for an app that failed to start.
            [self reportContentArrived];
            [vc appTerminationCleanUp];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"lc.common.error".loc message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.copy".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                UIPasteboard.generalPasteboard.string = error.localizedDescription;
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        } else {
            self.pid = vc.pid;
            [self updateOriginalFrame];
            if (self.pidAvailableHandler) {
                self.pidAvailableHandler(@(self.pid), nil);
            }
        }
    });
}

- (void)appSceneVCDidPresentScene:(AppSceneViewController*)vc {
    // The guest's scene is on screen now and it is drawing into it. Give that
    // first frame a moment to land, then let go of the launch screen this window
    // opened with. This is the cue that fires for every guest; the settings
    // update below is merely an earlier one when the guest happens to send it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kContentGraceAfterScene * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self reportContentArrived];
    });
}

- (void)appSceneVC:(AppSceneViewController*)vc didUpdateFromSettings:(UIMutableApplicationSceneSettings *)baseSettings transitionContext:(id)newContext {
    UIMutableApplicationSceneSettings *newSettings = [vc.presenter.scene.settings mutableCopy];
    newSettings.userInterfaceStyle = baseSettings.userInterfaceStyle;
    newSettings.interfaceOrientation = baseSettings.interfaceOrientation;
    newSettings.deviceOrientation = baseSettings.deviceOrientation;
    newSettings.foreground = YES;
    
    if(self.isMaximized) {
        [self updateMaximizedFrameWithSettings:newSettings];
    } else {
        [self updateWindowedFrameWithSettings:newSettings];
    }
    [self applySceneFrameToSettings:newSettings orientation:baseSettings.interfaceOrientation];

    [_appSceneVC.presenter.scene updateSettings:newSettings withTransitionContext:newContext completion:nil];

    // An early cue when it comes, but only that: a settings update arrives when
    // the guest changes something about its scene, and an app that changes
    // nothing never sends one. `appSceneVCDidPresentScene:` is what this actually
    // relies on.
    [self reportContentArrived];
}

// Resizes the guest scene's drawable to match the current container view size.
// Must be called whenever self.view.frame changes (rotation, bar show/hide),
// otherwise apps that don't push their own settings update keep rendering at the
// old size and leave a blank strip where the view grew.
- (void)applySceneFrameToSettings:(UIMutableApplicationSceneSettings *)settings orientation:(UIInterfaceOrientation)orientation {
    // Measured from bounds, never from frame. A window carries a transform while
    // it is growing out of its icon, and `frame` is undefined under one — the
    // guest's scene is presented during exactly that stretch, so reading the frame
    // told it that it was icon-sized. It would lay out for that and stay wrong
    // until something forced a fresh settings update, which is why toggling the
    // bar appeared to repair it. Bounds is the size the window really occupies,
    // transform or no transform.
    CGSize windowSize = self.view.bounds.size;
    CGRect newFrame = CGRectMake(0, 0, windowSize.width/self.scaleRatio, (windowSize.height - self.navigationBar.frame.size.height)/self.scaleRatio);
    if(UIInterfaceOrientationIsLandscape(orientation)) {
        settings.frame = CGRectMake(0, 0, newFrame.size.height, newFrame.size.width);
    } else {
        settings.frame = CGRectMake(0, 0, newFrame.size.width, newFrame.size.height);
    }
}

- (void)adjustNavigationBarButtonSpacingWithNegativeSpacing:(CGFloat)spacing rightMargin:(CGFloat)margin {
    if (!self.navigationBar) return;
    [self findAndAdjustButtonBarStackView:self.navigationBar withSpacing:spacing rightMargin:margin];
}

- (void)findAndAdjustButtonBarStackView:(UIView *)view withSpacing:(CGFloat)spacing rightMargin:(CGFloat)margin {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:NSClassFromString(@"_UIButtonBarStackView")]) {
            if ([subview respondsToSelector:@selector(setSpacing:)]) {
                [(_UIButtonBarStackView *)subview setSpacing:spacing];
            }
            
            if (subview.superview) {
                for (NSLayoutConstraint *constraint in subview.superview.constraints) {
                    if ((constraint.firstItem == subview && constraint.firstAttribute == NSLayoutAttributeTrailing) ||
                        (constraint.secondItem == subview && constraint.secondAttribute == NSLayoutAttributeTrailing)) {
                        constraint.constant = (constraint.firstItem == subview) ? -margin : margin;
                        break;
                    }
                }
                
                [subview setNeedsLayout];
                [subview.superview setNeedsLayout];
            }
            
            return;
        }
        
        [self findAndAdjustButtonBarStackView:subview withSpacing:spacing rightMargin:margin];
    }
}




- (void)moveWindow:(UIPanGestureRecognizer*)sender {
    if(_isMaximized) return;
    
    CGPoint point = [sender translationInView:self.view];
    [sender setTranslation:CGPointZero inView:self.view];

    self.view.center = CGPointMake(self.view.center.x + point.x, self.view.center.y + point.y);
    [self updateOriginalFrame];
}

- (void)resizeWindow:(UIPanGestureRecognizer*)sender {
    if(_isMaximized) return;
    
    CGPoint point = [sender translationInView:self.view];
    [sender setTranslation:CGPointZero inView:self.view];

    CGRect frame = self.view.frame;
    frame.size.width = MAX(50, frame.size.width + point.x);
    frame.size.height = MAX(50, frame.size.height + point.y);
    self.view.frame = frame;
    [self updateOriginalFrame];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    // FIXME: how to bring view to front when touching the passthrough view?
    [self.view.superview bringSubviewToFront:self.view];
}

- (void)updateVerticalConstraints {
    // Update safe area insets
    if(_isMaximized) {
        __weak typeof(self) weakSelf = self;
        self.appSceneVC.nextUpdateSettingsBlock = ^(UIMutableApplicationSceneSettings *settings) {
            [weakSelf updateMaximizedFrameWithSettings:settings];
        };
    }
    
    self.navigationBar.hidden = YES;
    
    [NSLayoutConstraint deactivateConstraints:self.activatedVerticalConstraints];
    self.activatedVerticalConstraints = @[
        [self.appSceneVC.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.appSceneVC.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.navigationBar.heightAnchor constraintEqualToConstant:0]
    ];
    [NSLayoutConstraint activateConstraints:self.activatedVerticalConstraints];
}

- (void)switcherBarVisibilityChanged {
    if(!_isMaximized) return;
    [UIView animateWithDuration:0.3 animations:^{
        [self.appSceneVC.presenter.scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            [self updateMaximizedFrameWithSettings:settings];
            // Keep the guest drawable in sync with the resized container so no
            // blank strip is left when the bar hides and the view grows.
            [self applySceneFrameToSettings:settings orientation:UIApplication.sharedApplication.statusBarOrientation];
        }];
    }];
}

- (UIEdgeInsets)updateMaximizedSafeAreaWithSettings:(UIMutableApplicationSceneSettings *)settings {
    BOOL bottomWindowBar = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"];
    UIEdgeInsets safeAreaInsets = self.view.window.safeAreaInsets;
    if(self.navigationBar.hidden) {
        if(MultitaskDockManager.shared.barVisible) {
            safeAreaInsets.bottom = 0; // App window doesn't extend to bottom; switcher bar handles it
        }
        settings.peripheryInsets = safeAreaInsets;
        safeAreaInsets = UIEdgeInsetsZero;
    } else if(bottomWindowBar) {
        // allow the control bar to overlap the bottom safe area
        safeAreaInsets.bottom = 0;
        settings.peripheryInsets = safeAreaInsets;
        safeAreaInsets.top = safeAreaInsets.left = safeAreaInsets.right = 0;
    } else {
        settings.peripheryInsets = UIEdgeInsetsMake(0, safeAreaInsets.left, safeAreaInsets.bottom, safeAreaInsets.right);
        safeAreaInsets.bottom = safeAreaInsets.left = safeAreaInsets.right = 0;
    }
    
    // scale peripheryInsets to match the scale ratio
    settings.peripheryInsets = UIEdgeInsetsMake(settings.peripheryInsets.top/_scaleRatio, settings.peripheryInsets.left/_scaleRatio, settings.peripheryInsets.bottom/_scaleRatio, settings.peripheryInsets.right/_scaleRatio);
    if(UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) {
        UIInterfaceOrientation currentOrientation = UIApplication.sharedApplication.statusBarOrientation;
        if(UIInterfaceOrientationIsLandscape(currentOrientation)) {
            safeAreaInsets.top = 0;
        }
        switch(currentOrientation) {
            case UIInterfaceOrientationLandscapeLeft:
                settings.safeAreaInsetsPortrait = UIEdgeInsetsMake(settings.peripheryInsets.left, 0, settings.peripheryInsets.right, settings.peripheryInsets.bottom);
                break;
            case UIInterfaceOrientationLandscapeRight:
                settings.safeAreaInsetsPortrait = UIEdgeInsetsMake(settings.peripheryInsets.left, settings.peripheryInsets.bottom, settings.peripheryInsets.right, 0);
                break;
            default:
                settings.safeAreaInsetsPortrait = UIEdgeInsetsMake(settings.peripheryInsets.top, settings.peripheryInsets.left, settings.peripheryInsets.bottom, settings.peripheryInsets.right);
                break;
        }

    } else {
        settings.safeAreaInsetsPortrait = UIEdgeInsetsMake(settings.peripheryInsets.top, settings.peripheryInsets.left, settings.peripheryInsets.bottom, settings.peripheryInsets.right);
    }
    
    safeAreaInsets.bottom = 0;
    return safeAreaInsets;
}

- (void)updateMaximizedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, [self updateMaximizedSafeAreaWithSettings:settings]);
    if(MultitaskDockManager.shared.barVisible) {
        // Reserve exactly the bar's strip thickness so the app sits flush with
        // it — no background gap showing through. The bar lives on the current
        // short edge (bottom in portrait, right edge in landscape), so reserve
        // from the matching dimension. Previously the bottom reserved a larger
        // fixed value (40) than the bar's real height, leaving an empty strip.
        CGFloat barThickness = MultitaskDockManager.shared.barReservedThickness;
        if(UIInterfaceOrientationIsLandscape(UIApplication.sharedApplication.statusBarOrientation)) {
            maxFrame.size.width -= barThickness;
        } else {
            maxFrame.size.height -= barThickness;
        }
    }
    [self setWindowFrame:maxFrame];
}

/// Places the window through bounds and centre rather than `frame`.
///
/// A window carries a transform while it is growing out of its icon, or
/// shrinking back into it, and `frame` is undefined under a transform —
/// assigning it there is read back through the transform and leaves the window's
/// bounds distorted for good. The scene reports its settings as the guest starts
/// up, which is exactly when the opening animation is still running, so this path
/// has to be safe to take mid-flight. With no transform it is identical to
/// setting the frame.
- (void)setWindowFrame:(CGRect)frame {
    self.view.bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
    self.view.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
}

- (void)updateWindowedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    UIEdgeInsets safeAreaInsets = self.view.window.safeAreaInsets;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, safeAreaInsets);
    settings.peripheryInsets = UIEdgeInsetsZero;
    settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;
    
    CGRect newFrame = CGRectMake(self.originalFrame.origin.x * maxFrame.size.width, self.originalFrame.origin.y * maxFrame.size.height, self.originalFrame.size.width, self.originalFrame.size.height);
    CGPoint center = self.view.center;
    CGRect frame = CGRectZero;
    frame.size.width = MIN(newFrame.size.width, maxFrame.size.width);
    frame.size.height = MIN(newFrame.size.height, maxFrame.size.height);
    CGFloat oobOffset = MAX(30, frame.size.width - 30);
    frame.origin.x = MAX(maxFrame.origin.x - oobOffset, MIN(CGRectGetMaxX(maxFrame) - frame.size.width + oobOffset, center.x - frame.size.width / 2));
    frame.origin.y = MAX(maxFrame.origin.y, MIN(center.y - frame.size.height / 2, CGRectGetMaxY(maxFrame) - frame.size.height));
    [UIView animateWithDuration:0.3 animations:^{
        [self setWindowFrame:frame];
    }];
}

- (void)updateOriginalFrame {
    if(_isMaximized) return;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    // Derived from bounds and centre rather than frame, which is undefined while
    // the window is animating into or out of its icon.
    CGSize size = self.view.bounds.size;
    CGPoint origin = CGPointMake(self.view.center.x - size.width / 2, self.view.center.y - size.height / 2);
    // save origin as normalized coordinates
    self.originalFrame = CGRectMake(origin.x / maxFrame.size.width, origin.y / maxFrame.size.height, size.width, size.height);
}

@end
