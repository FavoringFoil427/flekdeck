//
//  Notification.m
//  LiveContainer
//
//  Created by s s on 2025/7/21.
//

#import "UserNotifications/UserNotifications.h"
#import "../LiveContainer/utils.h"
@interface UNUserNotificationCenter(private)
@property (nonatomic, copy) NSString *bundleIdentifier;
@end

// UNUserNotificationCenter takes its identity from NSBundle.mainBundle, which by
// now is the guest's bundle — an id usernotificationsd has no record of, so every
// request dies silently. Speak as the host app instead, which is a real installed
// app with a notification record of its own.
static NSString *lc_notificationBundleIdentifier(void) {
    NSBundle *bundle = NSUserDefaults.lcMainBundle;
    if(NSUserDefaults.isLiveProcess) {
        // In parallel mode mainBundle is LiveContainer.app/PlugIns/LiveProcess.appex.
        // An extension has no notification registration either, so walk back up to
        // the containing app and borrow its identity — the daemon accepts it.
        NSString *appPath = bundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        NSBundle *containingApp = [NSBundle bundleWithPath:appPath];
        if(containingApp.bundleIdentifier) {
            bundle = containingApp;
        }
    }
    return bundle.bundleIdentifier;
}

__attribute__((constructor))
static void UNHooksInit(void) {
    if(!NSUserDefaults.lcGuestAppId) return;
    if([NSUserDefaults.guestAppInfo[@"fixLocalNotification"] boolValue] || NSUserDefaults.isSideStore) {
        [UNUserNotificationCenter.currentNotificationCenter setBundleIdentifier:lc_notificationBundleIdentifier()];
    }
}
