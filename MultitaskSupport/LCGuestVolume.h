//
//  LCGuestVolume.h
//  LiveContainer
//

@import Foundation;

NS_ASSUME_NONNULL_BEGIN

/// The host end of one guest's volume control.
///
/// Nothing on this side can turn down another process's output, so this only
/// carries a level across to the guest, where LCAudioMute applies it. Split out
/// of the scene view controller so that anything with a container id can drive
/// it — a multitask window, or one of the placeholders standing in for the
/// internal pages, which have no guest process to carry it to.
@interface LCGuestVolume : NSObject

- (instancetype)initWithDataUUID:(NSString *)dataUUID;

/// Playback gain for the guest, 0 through 1. Multiplies whatever volume the app
/// itself is using rather than replacing it.
@property(nonatomic) float volume;
@property(nonatomic, readonly) BOOL muted;
/// YES once the guest has answered a level change. Never required for anything —
/// its value is in telling a dead channel apart from an audio path the guest
/// cannot reach.
@property(nonatomic, readonly) BOOL confirmed;

/// Silences the guest, or restores it to the level it had before being muted.
- (void)toggleMute;

/// Drops the notification registrations. Safe to call more than once.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
