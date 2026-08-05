//
//  CloudKit+GuestHooks.m
//  LiveContainer
//
//  CloudKit resolves a container against the *process's* iCloud entitlements.
//  A guest app runs inside LiveContainer's process, which is signed without
//  com.apple.developer.icloud-container-identifiers, so the lookup yields nil
//  and CloudKit dereferences it — the guest dies with SIGSEGV before it can
//  report anything.
//
//  Handing the guest a nil container stops the crash but trades it for a worse
//  bug: messaging nil drops completion handlers on the floor, so an app that
//  waits for its iCloud check to come back waits forever. Give it a stand-in
//  instead — one that answers every call by reporting no iCloud account, the
//  same thing the app would hear from a device with iCloud signed out.
//

#import <mach-o/dyld.h>
#import "utils.h"

// Declared in FoundationPrivate.h; repeated here so this file stays free of
// the private UIKit headers that come with it.
void* SecTaskCreateFromSelf(CFAllocatorRef allocator);
CFTypeRef SecTaskCopyValueForEntitlement(void *task, CFStringRef key, CFErrorRef *error);

// Spelled out rather than imported so this file never has to link CloudKit.
static const NSInteger LCAccountStatusNoAccount = 3; // CKAccountStatusNoAccount
static const NSInteger LCErrorNotAuthenticated = 9;  // CKErrorNotAuthenticated

static NSError* lcNoAccountError(void) {
    return [NSError errorWithDomain:@"CKErrorDomain" code:LCErrorNotAuthenticated userInfo:@{
        NSLocalizedDescriptionKey: @"iCloud is not available to apps running in LiveContainer."
    }];
}

#pragma mark - Calling a block we only know at runtime

// A block carries its own type encoding when the compiler emits one, which is
// the only way to call a completion handler whose shape we never see.
enum {
    LCBlockHasCopyDispose = 1 << 25,
    LCBlockHasSignature   = 1 << 30,
};

struct LCBlockLayout {
    void* isa;
    int flags;
    int reserved;
    void (*invoke)(void*, ...);
    void* descriptor;
};

static NSMethodSignature* lcBlockSignature(id block) {
    struct LCBlockLayout* layout = (__bridge struct LCBlockLayout*)block;
    if(!(layout->flags & LCBlockHasSignature)) return nil;

    // descriptor: { reserved, size }, then copy/dispose if present, then signature
    uint8_t* cursor = layout->descriptor;
    cursor += sizeof(unsigned long) * 2;
    if(layout->flags & LCBlockHasCopyDispose) cursor += sizeof(void*) * 2;

    const char* types = *(const char**)cursor;
    return types ? [NSMethodSignature signatureWithObjCTypes:types] : nil;
}

// Completion handlers put their error last and their result first, so zero
// every argument and drop the error into the trailing slot if there is one.
static void lcCallBlock(id block, NSError* error) {
    NSMethodSignature* signature = lcBlockSignature(block);
    if(!signature) return;

    NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
    NSUInteger count = signature.numberOfArguments;
    for(NSUInteger i = 1; i < count; i++) {
        const char* type = [signature getArgumentTypeAtIndex:i];
        if(error && i == count - 1 && type[0] == '@' && type[1] != '?') {
            [invocation setArgument:&error atIndex:i];
            continue;
        }
        NSUInteger size = 0;
        NSGetSizeAndAlignment(type, &size, NULL);
        void* zero = calloc(1, size);
        [invocation setArgument:zero atIndex:i];
        free(zero);
    }
    [invocation invokeWithTarget:block];
}

// CKOperation hangs its results off block properties rather than a completion
// argument, so an operation we accept and never run has to be failed by hand.
static void lcFailOperation(id operation, NSError* error) {
    NSMutableArray* completions = [NSMutableArray array];
    id operationFinished = nil;

    for(Class cls = object_getClass(operation); cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        objc_property_t* properties = class_copyPropertyList(cls, &count);
        for(unsigned int i = 0; i < count; i++) {
            char* type = property_copyAttributeValue(properties[i], "T");
            BOOL isBlock = type && strncmp(type, "@?", 2) == 0;
            free(type);
            if(!isBlock) continue;

            NSString* name = @(property_getName(properties[i]));
            id block = nil;
            @try {
                block = [operation valueForKey:name];
            } @catch(NSException* exception) {
                continue;
            }
            if(!block) continue;

            if([name isEqualToString:@"completionBlock"]) operationFinished = block;
            else if([name hasSuffix:@"CompletionBlock"]) [completions addObject:block];
        }
        free(properties);
    }

    for(id completion in completions) lcCallBlock(completion, error);
    // NSOperation's own completionBlock takes no arguments and runs last
    if(operationFinished) lcCallBlock(operationFinished, nil);
}

#pragma mark - The stand-in

@interface LCCloudKitStub : NSObject
@property(nonatomic, copy) NSString* lc_impersonatedClass;
@property(nonatomic, copy) NSString* lc_containerIdentifier;
@end

@implementation LCCloudKitStub

+ (instancetype)stubForClass:(NSString *)className {
    LCCloudKitStub* stub = [LCCloudKitStub new];
    stub.lc_impersonatedClass = className;
    return stub;
}

- (Class)lc_realClass {
    return NSClassFromString(self.lc_impersonatedClass);
}

#pragma mark Passing for the real thing

- (Class)class {
    return [self lc_realClass] ?: super.class;
}

- (BOOL)isKindOfClass:(Class)cls {
    return [[self lc_realClass] isSubclassOfClass:cls] || [super isKindOfClass:cls];
}

- (BOOL)isMemberOfClass:(Class)cls {
    return cls == [self lc_realClass] || [super isMemberOfClass:cls];
}

- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [[self lc_realClass] instancesRespondToSelector:selector];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ (LiveContainer stub): %@>",
            self.lc_impersonatedClass, self.lc_containerIdentifier ?: @"unavailable"];
}

#pragma mark The calls worth answering precisely

- (NSString *)containerIdentifier {
    return self.lc_containerIdentifier;
}

- (id)privateCloudDatabase { return [LCCloudKitStub stubForClass:@"CKDatabase"]; }
- (id)publicCloudDatabase  { return [LCCloudKitStub stubForClass:@"CKDatabase"]; }
- (id)sharedCloudDatabase  { return [LCCloudKitStub stubForClass:@"CKDatabase"]; }
- (id)databaseWithDatabaseScope:(NSInteger)scope { return [LCCloudKitStub stubForClass:@"CKDatabase"]; }

// The one the app is usually waiting on. No account is a state every CloudKit
// app already handles, and it isn't an error, so report it without one.
- (void)accountStatusWithCompletionHandler:(void(^)(NSInteger status, NSError* error))completionHandler {
    if(!completionHandler) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        completionHandler(LCAccountStatusNoAccount, nil);
    });
}

- (void)addOperation:(id)operation {
    if(!operation) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        lcFailOperation(operation, lcNoAccountError());
    });
}

#pragma mark Everything else

// Anything not spelled out above still has to come back, or the app stalls the
// way it did with a nil container. Fail each callback the method was handed.
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    NSMethodSignature* signature = [super methodSignatureForSelector:selector];
    return signature ?: [[self lc_realClass] instanceMethodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    NSMethodSignature* signature = invocation.methodSignature;

    NSMutableArray* handlers = [NSMutableArray array];
    for(NSUInteger i = 2; i < signature.numberOfArguments; i++) {
        if(strcmp([signature getArgumentTypeAtIndex:i], "@?") != 0) continue;
        __unsafe_unretained id handler = nil;
        [invocation getArgument:&handler atIndex:i];
        if(handler) [handlers addObject:handler];
    }

    if(handlers.count) {
        NSError* error = lcNoAccountError();
        dispatch_async(dispatch_get_main_queue(), ^{
            for(id handler in handlers) lcCallBlock(handler, error);
        });
    }

    if(signature.methodReturnLength) {
        void* zero = calloc(1, signature.methodReturnLength);
        [invocation setReturnValue:zero];
        free(zero);
    }
}

@end

#pragma mark - Installing

static BOOL cloudKitStubInstalled = NO;

static BOOL processHasICloudContainers(void) {
    void* taskSelf = SecTaskCreateFromSelf(NULL);
    if(!taskSelf) return NO;

    CFTypeRef containers = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.developer.icloud-container-identifiers"), NULL);
    BOOL hasContainers = containers
        && CFGetTypeID(containers) == CFArrayGetTypeID()
        && CFArrayGetCount(containers) > 0;

    if(containers) CFRelease(containers);
    CFRelease(taskSelf);
    return hasContainers;
}

static void installCloudKitStub(void) {
    if(cloudKitStubInstalled) return;

    Class CKContainerClass = NSClassFromString(@"CKContainer");
    if(!CKContainerClass) return;
    cloudKitStubInstalled = YES;

    Method containerWithIdentifier = class_getClassMethod(CKContainerClass, @selector(containerWithIdentifier:));
    if(containerWithIdentifier) {
        method_setImplementation(containerWithIdentifier, imp_implementationWithBlock(^id(id self, NSString* identifier) {
            NSLog(@"[LC] CloudKit is unavailable in LiveContainer, standing in for container %s", identifier.UTF8String);
            LCCloudKitStub* stub = [LCCloudKitStub stubForClass:@"CKContainer"];
            stub.lc_containerIdentifier = identifier;
            return stub;
        }));
    }

    Method defaultContainer = class_getClassMethod(CKContainerClass, @selector(defaultContainer));
    if(defaultContainer) {
        method_setImplementation(defaultContainer, imp_implementationWithBlock(^id(id self) {
            NSLog(@"[LC] CloudKit is unavailable in LiveContainer, standing in for the default container");
            return [LCCloudKitStub stubForClass:@"CKContainer"];
        }));
    }
}

// CloudKit is usually pulled in lazily by whichever framework wants it, so the
// class may not exist yet when this dylib is injected. dyld replays this for
// every image already loaded, then calls it for each new one.
static void cloudKitImageAdded(const struct mach_header* header, intptr_t slide) {
    installCloudKitStub();
}

__attribute__((constructor))
static void CloudKitGuestHooksInit(void) {
    if(!NSUserDefaults.lcGuestAppId) return;
    // Signed with real iCloud containers for once? Then let CloudKit do its job.
    if(processHasICloudContainers()) return;

    installCloudKitStub();
    if(!cloudKitStubInstalled) {
        _dyld_register_func_for_add_image(cloudKitImageAdded);
    }
}
