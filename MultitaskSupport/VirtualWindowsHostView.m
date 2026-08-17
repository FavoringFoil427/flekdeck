//
//  VirtualWindowsHostView.m
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
#import "DecoratedAppSceneViewController.h"
#import "VirtualWindowsHostView.h"

static void *kBackdropObservationContext = &kBackdropObservationContext;

@interface VirtualWindowsHostView()
/// Opaque black filler shown behind the app windows. Guest windows don't always
/// cover the screen — a landscape-only app on a portrait device is laid out as a
/// scaled landscape strip, and even a maximized one leaves slivers outside its
/// rounded corners. Without this, what shows in those gaps is the launcher behind
/// the host view, which is white in light mode. Hidden whenever no app window is
/// visible, so the springboard and its wallpaper are untouched on the home state.
@property(nonatomic) UIView *backdropView;
@end

@implementation VirtualWindowsHostView
- (instancetype)init {
    CGRect frame = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).keyWindow.bounds;
    self = [super initWithFrame:frame];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.shouldForwardTapAction = YES;

    _backdropView = [[UIView alloc] initWithFrame:self.bounds];
    _backdropView.backgroundColor = UIColor.blackColor;
    _backdropView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // Never a hit-test candidate, so hitTest: below still reports "nothing here"
    // and lets taps fall through to the springboard when no window is up.
    _backdropView.userInteractionEnabled = NO;
    _backdropView.hidden = YES;
    [self addSubview:_backdropView];

    return self;
}

- (void)dealloc {
    for(UIView *subview in self.subviews) {
        if(subview == _backdropView) continue;
        [subview removeObserver:self forKeyPath:@"hidden" context:kBackdropObservationContext];
        [subview removeObserver:self forKeyPath:@"alpha" context:kBackdropObservationContext];
    }
}

#pragma mark Backdrop

// Windows are shown/hidden from a dozen places (launch, minimize, restore, PiP,
// "one app on stage", termination). Observing the two properties that decide
// visibility keeps the backdrop correct without having to hook every one of them.
- (void)didAddSubview:(UIView *)subview {
    [super didAddSubview:subview];
    if(subview == _backdropView) return;
    [subview addObserver:self forKeyPath:@"hidden" options:0 context:kBackdropObservationContext];
    [subview addObserver:self forKeyPath:@"alpha" options:0 context:kBackdropObservationContext];
    [self sendSubviewToBack:_backdropView];
    [self updateBackdropVisibility];
}

- (void)willRemoveSubview:(UIView *)subview {
    [super willRemoveSubview:subview];
    if(subview == _backdropView) return;
    [subview removeObserver:self forKeyPath:@"hidden" context:kBackdropObservationContext];
    [subview removeObserver:self forKeyPath:@"alpha" context:kBackdropObservationContext];
    // The subview is still in self.subviews at this point; re-check once it's gone.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateBackdropVisibility];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if(context != kBackdropObservationContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    [self updateBackdropVisibility];
}

- (void)setBackdropSuspended:(BOOL)backdropSuspended {
    _backdropSuspended = backdropSuspended;
    [self updateBackdropVisibility];
}

- (void)updateBackdropVisibility {
    if(self.backdropSuspended) {
        // A window is on its way into or out of an icon; what is behind it should
        // be the home screen it is travelling across, not a black field.
        _backdropView.hidden = YES;
        return;
    }
    BOOL anyWindowVisible = NO;
    for(UIView *subview in self.subviews) {
        if(subview == _backdropView) continue;
        if(!subview.hidden && subview.alpha > 0.1) {
            anyWindowVisible = YES;
            break;
        }
    }
    _backdropView.hidden = !anyWindowVisible;
}

#pragma mark Touch handling

- (BOOL)handleStatusBarTapAction:(UIAction *)action {
    if(!self.shouldForwardTapAction) return NO;
    // grab the frontmost app window, if it's visible pass this event to it
    UIView *frontmostView = self.subviews.lastObject;
    if(!frontmostView.hidden) {
        DecoratedAppSceneViewController *decoratedVC = (id)frontmostView._viewDelegate;
        [decoratedVC.appSceneVC handleStatusBarTapAction:action];
    }
    return !frontmostView.hidden;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView* hitView = [super hitTest:point withEvent:event];
    if(hitView == self) {
        self.shouldForwardTapAction = NO;
        return nil;
    } else {
        self.shouldForwardTapAction = YES;
        return hitView;
    }
}
@end
