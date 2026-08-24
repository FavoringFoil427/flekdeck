#import <Foundation/Foundation.h>

/// The queue guest-facing API stubs deliver their callbacks on.
///
/// Never the main queue. An app is allowed to start one of these requests and
/// then block its main thread until the answer arrives, because the frameworks
/// being stood in for answer from another thread. Replying via the main queue
/// makes that a deadlock: the blocked main thread never drains the queue, so the
/// answer never lands and the launch watchdog ends the app about twenty seconds
/// later, with nothing of ours on the stack to say why.
///
/// Serial rather than a global concurrent queue, so that several stubbed replies
/// still reach the app in the order it asked for them — which is what it got
/// while these all went through the main queue.
///
/// Kept here rather than in utils.h, which upstream consolidated into
/// LiveContainer/utils.h: everything left there is static inline, so TweakLoader
/// does not link that file's implementation, and a definition placed in it would
/// not resolve for this target.
dispatch_queue_t lcGuestCallbackQueue(void);
