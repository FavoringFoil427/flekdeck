//
//  FlekStore+GuestHooks.m
//  LiveContainer
//
//  Some apps ported through the FlekStore ship an injected FlekSt0re.dylib that,
//  a moment after launch, shows the porter's promo through a FlekstoreAlertWindow —
//  driven from the completion handler of a server call that hashes the binary (its
//  BinaryChecker) and decides what to display.
//
//  In the builds seen, that class is missing several of its own methods from the
//  runtime method table — +showAlert to open the promo, and -dismiss / -closeAlert
//  to take it down again — so when the dylib calls one, it lands on nothing and the
//  app aborts with "unrecognized selector": after the Unity loading screen for
//  showAlert, or a few seconds later on the auto-dismiss timer for dismiss. init
//  and the setup* builders are present (they run), so the gap is only the action
//  methods, and it is a set, not a single call.
//
//  The dylib is heavily obfuscated and phones home with a hash of itself, so editing
//  its bytes is the wrong tool. Leave it untouched and supply the missing methods —
//  but as stand-ins that do nothing. Drawing the promo is not possible from here:
//  its content comes from that server reply (a test endpoint) and remote assets, and
//  that pipeline does not deliver in the guest, so any attempt to present it only
//  puts an empty opaque window over the game. The point is narrower and worth more:
//  keep every call the dylib makes on this class from aborting the app. The promo
//  does not appear; the game runs.
//
//  Scoped by the class name, which nothing else defines, and each stand-in is added
//  only where the real method is absent, so nothing legitimate is touched.
//

@import Foundation;
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import "../LiveContainer/utils.h"

static BOOL flekstoreShimInstalled = NO;

// Every one of the crashing calls is a void, no-argument action, so a single empty
// function with a "v@:" signature stands in for all of them.
static void flekstoreNoop(__unused id self, __unused SEL _cmd) { }

static void supplyClassNoop(Class cls, SEL sel) {
    if(![cls respondsToSelector:sel]) {
        class_addMethod(object_getClass(cls), sel, (IMP)flekstoreNoop, "v@:");
    }
}

static void supplyInstanceNoop(Class cls, SEL sel) {
    if(![cls instancesRespondToSelector:sel]) {
        class_addMethod(cls, sel, (IMP)flekstoreNoop, "v@:");
    }
}

static void installFlekstoreShim(void) {
    if(flekstoreShimInstalled) return;

    Class alertWindow = NSClassFromString(@"FlekstoreAlertWindow");
    if(!alertWindow) return;
    flekstoreShimInstalled = YES;

    supplyClassNoop(alertWindow, @selector(showAlert));
    supplyInstanceNoop(alertWindow, @selector(dismiss));
    supplyInstanceNoop(alertWindow, @selector(closeAlert));
    supplyInstanceNoop(alertWindow, @selector(openFlekstore));

    NSLog(@"[LC] FlekStore promo: supplied stand-ins for FlekstoreAlertWindow's missing action methods; the app runs, the ad stays unshown");
}

// FlekSt0re.dylib is a framework in the guest bundle and may not be loaded yet
// when this runs. dyld replays this for every image already mapped, then calls it
// for each new one, so the class is caught whenever it arrives.
static void flekstoreImageAdded(const struct mach_header* header, intptr_t slide) {
    installFlekstoreShim();
}

__attribute__((constructor))
static void FlekStoreGuestHooksInit(void) {
    if(!NSUserDefaults.lcGuestAppId) return;

    installFlekstoreShim();
    if(!flekstoreShimInstalled) {
        _dyld_register_func_for_add_image(flekstoreImageAdded);
    }
}
