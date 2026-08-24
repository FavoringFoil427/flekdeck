#import "GuestCallbackQueue.h"

dispatch_queue_t lcGuestCallbackQueue(void) {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.kdt.livecontainer.guest-callbacks", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}
