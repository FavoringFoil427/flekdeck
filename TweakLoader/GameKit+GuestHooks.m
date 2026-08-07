//
//  GameKit+GuestHooks.m
//  LiveContainer
//
//  Game Center identifies a game by the code signature of the process asking,
//  which for a guest is LiveContainer's. The guest's own bundle identifier never
//  reaches gamed — NSBundle is patched inside the process, the daemon reads the
//  signature over XPC — so the server is asked about a descriptor no Game Center
//  title matches and answers 5019, surfaced as GKErrorGameUnrecognized.
//
//  Nothing can be done about that from in here: authenticating as the real game
//  would take a process signed as the real game. What can be fixed is the shape
//  of the failure. An app told its Game Center app is unrecognised tends to
//  treat that as broken and stop; an app told nobody is signed in carries on
//  without it, because that happens to ordinary players every day. Report the
//  second, and leave the local player unauthenticated, which it genuinely is.
//

#import <mach-o/dyld.h>
#import "utils.h"

static BOOL gameKitStubInstalled = NO;

static void installGameKitStub(void) {
    if(gameKitStubInstalled) return;

    Class GKLocalPlayerClass = NSClassFromString(@"GKLocalPlayer");
    if(!GKLocalPlayerClass) return;
    gameKitStubInstalled = YES;

    // The modern entry point. GameKit would hand the app a sign-in screen to
    // present, or an error; a player who is signed out gets neither, so the app
    // is told authentication finished and nobody arrived.
    // On the main queue, unlike the other guest stubs, because that is where real
    // GameKit calls this handler and apps write it expecting to touch UI there. A
    // game that blocked its main thread waiting for sign-in would deadlock — but
    // it would deadlock on a stock device too, so no shipped game does it, and
    // there is nothing here to work around at the cost of off-main UI calls.
    Method setAuthenticateHandler = class_getInstanceMethod(GKLocalPlayerClass, @selector(setAuthenticateHandler:));
    if(setAuthenticateHandler) {
        method_setImplementation(setAuthenticateHandler, imp_implementationWithBlock(^(id self, void(^handler)(id viewController, NSError* error)) {
            NSLog(@"[LC] Game Center cannot recognise a guest app, reporting the player as signed out");
            if(!handler) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(nil, nil);
            });
        }));
    }

    // The pre-iOS 6 spelling, still what some engines call through to
    Method authenticateWithCompletionHandler = class_getInstanceMethod(GKLocalPlayerClass, @selector(authenticateWithCompletionHandler:));
    if(authenticateWithCompletionHandler) {
        method_setImplementation(authenticateWithCompletionHandler, imp_implementationWithBlock(^(id self, void(^handler)(NSError* error)) {
            if(!handler) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(nil);
            });
        }));
    }
}

// A guest that links GameKit the usual way already has the class by the time
// this dylib is injected, which is the common case. One that pulls it in later —
// weak-linked, or dlopened by a plugin — does not, so watch for it arriving.
// dyld replays this for every image already loaded, then calls it for each new
// one.
static void gameKitImageAdded(const struct mach_header* header, intptr_t slide) {
    installGameKitStub();
}

__attribute__((constructor))
static void GameKitGuestHooksInit(void) {
    if(!NSUserDefaults.lcGuestAppId) return;

    installGameKitStub();
    if(!gameKitStubInstalled) {
        _dyld_register_func_for_add_image(gameKitImageAdded);
    }
}
