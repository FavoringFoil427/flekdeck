//
//  VirtualWindowsHostView.h
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
@import UIKit;

API_AVAILABLE(ios(16.0))
@interface VirtualWindowsHostView: UIView
@property(nonatomic) BOOL shouldForwardTapAction;
/// Holds the backdrop back while a window is travelling into or out of its icon.
///
/// The backdrop is there to letterbox a guest whose drawable does not fill the
/// screen, so it blacks out everything behind any visible window. A window in
/// flight is visible but much smaller than the screen, and blacking out the rest
/// hides the very thing the flight is crossing: the springboard. Worse, it
/// arrives in one frame, because a window's opacity reaches its final value the
/// moment its animation is committed rather than when it looks that way.
@property(nonatomic) BOOL backdropSuspended;
- (BOOL)handleStatusBarTapAction:(UIAction *)action;
@end
