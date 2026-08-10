//
//  LCGuestVolume.m
//  LiveContainer
//

#import "LCGuestVolume.h"
#import <notify.h>

@interface LCGuestVolume()
@property(nonatomic) NSString *dataUUID;
@property(nonatomic) NSNumber *volumeToken;
@property(nonatomic) NSNumber *ackToken;
@property(nonatomic) float volumeBeforeMute;
@end

@implementation LCGuestVolume

- (instancetype)initWithDataUUID:(NSString *)dataUUID {
    self = [super init];
    if(self) {
        _dataUUID = dataUUID;
        _volume = 1.0f;
        _volumeBeforeMute = 1.0f;
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
}

// A fixed literal keyed by container, not something derived from the app group
// id: the two processes each work that id out for themselves, from entitlements
// and container probing, and they only have to disagree once for the names to
// stop matching and every change to vanish.
- (NSString *)baseName {
    return [NSString stringWithFormat:@"com.kdt.livecontainer.mute.%@", self.dataUUID];
}

- (void)setVolume:(float)volume {
    volume = MIN(MAX(volume, 0.0f), 1.0f);
    _volume = volume;
    _confirmed = NO;
    [self observeAcknowledgements];

    NSString *base = self.baseName;
    // A notification name carries no payload, so the level travels as the name's
    // 64-bit state, in thousandths. The token is registered once and kept: a
    // slider drag comes through here a hundred times, and the state belongs to
    // the name for as long as someone holds a registration on it.
    NSString *volumeName = [base stringByAppendingString:@".volume"];
    if(!self.volumeToken) {
        int token = 0;
        if(notify_register_check(volumeName.UTF8String, &token) == NOTIFY_STATUS_OK) {
            self.volumeToken = @(token);
        }
    }
    if(self.volumeToken) {
        notify_set_state(self.volumeToken.intValue, (uint64_t)lroundf(volume * 1000.0f));
    }
    notify_post(volumeName.UTF8String);

    // Silence and full volume also go out under the names that carried mute
    // before there was a level, so those two — the ones reached by tapping —
    // survive even if the state payload does not.
    if(volume <= 0.0f) {
        notify_post([base stringByAppendingString:@".on"].UTF8String);
    } else if(volume >= 1.0f) {
        notify_post([base stringByAppendingString:@".off"].UTF8String);
    }
    NSLog(@"[LCAudioMute] host posted %@ = %.2f", volumeName, volume);
}

- (BOOL)muted {
    return self.volume <= 0.0f;
}

- (void)toggleMute {
    if(self.muted) {
        // Back to where the slider was left, not to full: a window turned down
        // to a background murmur and then muted should come back a murmur.
        self.volume = self.volumeBeforeMute > 0.0f ? self.volumeBeforeMute : 1.0f;
    } else {
        self.volumeBeforeMute = self.volume;
        self.volume = 0.0f;
    }
}

- (void)observeAcknowledgements {
    if(self.ackToken) return;
    NSString *ackName = [self.baseName stringByAppendingString:@".ack"];
    int token = 0;
    __weak typeof(self) weakSelf = self;
    uint32_t status = notify_register_dispatch(ackName.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
        LCGuestVolume *volume = weakSelf;
        if(!volume) return;
        volume->_confirmed = YES;
        NSLog(@"[LCAudioMute] guest acknowledged volume=%.2f", volume.volume);
    });
    if(status == NOTIFY_STATUS_OK) {
        self.ackToken = @(token);
    }
}

- (void)invalidate {
    if(self.ackToken) {
        notify_cancel(self.ackToken.intValue);
        self.ackToken = nil;
    }
    if(self.volumeToken) {
        notify_cancel(self.volumeToken.intValue);
        self.volumeToken = nil;
    }
}

@end
