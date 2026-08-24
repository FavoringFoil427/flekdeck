//
//  PiPManager.h
//  LiveContainer
//
//  Created by s s on 2025/6/3.
//
@import Foundation;
@import AVKit;
@import UIKit;
#import "FoundationPrivate.h"
#import "AppSceneViewController.h"

API_AVAILABLE(ios(16.0))
@interface PiPManager : NSObject<AVPictureInPictureControllerDelegate>
@property (class, nonatomic, readonly) PiPManager *shared;
// Whether the singleton exists yet. Constructing it has side effects, so a
// caller that only wants to know whether PiP is running must ask this first —
// if there is no manager, there is no PiP, and the answer is already known.
@property (class, nonatomic, readonly) BOOL hasShared;
@property (nonatomic, readonly) bool isPiP;
- (BOOL)isPiPWithVC:(AppSceneViewController*)vc;
- (BOOL)isPiPWithDecoratedVC:(UIViewController*)vc;
- (void)stopPiP;
- (void)startPiPWithVC:(AppSceneViewController*)vc;

@end
