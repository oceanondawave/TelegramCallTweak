#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// --- Declaring interfaces to resolve compile warnings ---

@interface PresentationCallImpl : NSObject
- (BOOL)isScreencastActive;
- (void)disableScreencast;
@end

@interface VoiceChatCameraPreviewControllerNode : NSObject
- (id)valueForKey:(NSString *)key;
- (void)setValue:(id)value forKey:(NSString *)key;
@end

@interface WheelControlNodeItem : NSObject
- (instancetype)initWithTitle:(NSString *)title;
@end

// --- Helper storage for custom call settings with persistent settings ---

static NSString *const kSettingsSuiteName = @"ph.telegra.telegramcalltweak";
static NSString *const kForceBuiltInMicKey = @"forceBuiltInMic";
static NSString *const kShareAudioOnlyKey = @"shareAudioOnly";

static BOOL getForceBuiltInMicSetting() {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSettingsSuiteName];
    return [defaults boolForKey:kForceBuiltInMicKey];
}

static void setForceBuiltInMicSetting(BOOL value) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSettingsSuiteName];
    [defaults setBool:value forKey:kForceBuiltInMicKey];
    [defaults synchronize];
}

static BOOL getShareAudioOnlySetting() {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSettingsSuiteName];
    return [defaults boolForKey:kShareAudioOnlyKey];
}

static void setShareAudioOnlySetting(BOOL value) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSettingsSuiteName];
    [defaults setBool:value forKey:kShareAudioOnlyKey];
    [defaults synchronize];
}

// --- Dynamic Swizzling Implementation (TrollStore / Sideload Friendly) ---

static void swizzle(Class class, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(class, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(class, swizzledSelector);
    
    BOOL didAddMethod = class_addMethod(class,
                                        originalSelector,
                                        method_getImplementation(swizzledMethod),
                                        method_getTypeEncoding(swizzledMethod));
    
    if (didAddMethod) {
        class_replaceMethod(class,
                            swizzledSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

// --- Swizzled Methods ---

// 1. ManagedAudioSessionImpl Hook
@interface NSObject (ManagedAudioSessionImplHook)
@end
@implementation NSObject (ManagedAudioSessionImplHook)
- (void)swizzled_updateAudioSessionType:(NSInteger)type outputMode:(NSInteger)outputMode {
    [self swizzled_updateAudioSessionType:type outputMode:outputMode];
    if (getForceBuiltInMicSetting()) {
        NSArray<AVAudioSessionPortDescription *> *inputs = [[AVAudioSession sharedInstance] availableInputs];
        AVAudioSessionPortDescription *builtInMic = nil;
        for (AVAudioSessionPortDescription *input in inputs) {
            if ([input.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
                builtInMic = input;
                break;
            }
        }
        if (builtInMic) {
            NSError *error = nil;
            [[AVAudioSession sharedInstance] setPreferredInput:builtInMic error:&error];
        }
    }
}
@end

// 2. PresentationCallImpl Hooks
@interface NSObject (PresentationCallImplHook)
@end
@implementation NSObject (PresentationCallImplHook)
- (void)swizzled_videoButtonPressed {
    PresentationCallImpl *call = (PresentationCallImpl *)self;
    if ([call isScreencastActive]) {
        [call disableScreencast];
    } else {
        [self swizzled_videoButtonPressed];
    }
}

- (void)swizzled_handleScreencastFrame:(id)frame buffer:(CVPixelBufferRef)pixelBuffer {
    if (getShareAudioOnlySetting()) {
        return;
    }
    [self swizzled_handleScreencastFrame:frame buffer:pixelBuffer];
}
@end

// 3. VoiceChatCameraPreviewControllerNode Hooks
@interface NSObject (VoiceChatCameraPreviewControllerNodeHook)
@end
@implementation NSObject (VoiceChatCameraPreviewControllerNodeHook)
- (void)swizzled_setupWheelNode {
    [self swizzled_setupWheelNode];
    
    id wheelNode = [self valueForKey:@"wheelNode"];
    if (wheelNode) {
        NSMutableArray *items = [[wheelNode valueForKey:@"items"] mutableCopy];
        
        WheelControlNodeItem *audioTab = [NSClassFromString(@"WheelControlNodeItem") alloc];
        if ([audioTab respondsToSelector:@selector(initWithTitle:)]) {
            audioTab = [audioTab initWithTitle:@"Share Audio Only"];
        }
        
        if (audioTab) {
            [items insertObject:audioTab atIndex:0];
            [wheelNode setValue:items forKey:@"items"];
        }
    }
}

- (void)swizzled_wheelNodeSelectedIndexChanged:(NSInteger)index {
    [self swizzled_wheelNodeSelectedIndexChanged:index];
    setShareAudioOnlySetting(index == 0);
}
@end

// 4. Hook UIApplication to show launch confirmation toast
@interface NSObject (UIApplicationHook)
@end
@implementation NSObject (UIApplicationHook)
- (instancetype)swizzled_init {
    id instance = [self swizzled_init];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in scene.windows) {
                        if (w.isKeyWindow) {
                            window = w;
                            break;
                        }
                    }
                }
            }
        }
        if (!window) {
            window = [UIApplication sharedApplication].keyWindow;
        }
        
        UIViewController *rootVC = window.rootViewController;
        if (rootVC) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Tweak Injected"
                                                                           message:@"TelegramCallTweak has loaded successfully!"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [rootVC presentViewController:alert animated:YES completion:nil];
        }
    });
    
    return instance;
}
@end

// --- Tweak Entry Point ---
__attribute__((constructor)) static void initTweak() {
    NSLog(@"[TelegramCallTweak] Dynamic swizzler initializing...");
    
    // Hook UIApplication init
    Class uiAppClass = NSClassFromString(@"UIApplication");
    if (uiAppClass) {
        swizzle(uiAppClass, @selector(init), @selector(swizzled_init));
    }
    
    // Hook ManagedAudioSessionImpl
    Class managedAudioSession = NSClassFromString(@"ManagedAudioSessionImpl");
    if (managedAudioSession) {
        swizzle(managedAudioSession, @selector(updateAudioSessionType:outputMode:), @selector(swizzled_updateAudioSessionType:outputMode:));
    }
    
    // Hook PresentationCallImpl
    Class presentationCall = NSClassFromString(@"PresentationCallImpl");
    if (presentationCall) {
        swizzle(presentationCall, @selector(videoButtonPressed), @selector(swizzled_videoButtonPressed));
        swizzle(presentationCall, @selector(handleScreencastFrame:buffer:), @selector(swizzled_handleScreencastFrame:buffer:));
    }
    
    // Hook VoiceChatCameraPreviewControllerNode
    Class cameraPreviewNode = NSClassFromString(@"VoiceChatCameraPreviewControllerNode");
    if (cameraPreviewNode) {
        swizzle(cameraPreviewNode, @selector(setupWheelNode), @selector(swizzled_setupWheelNode));
        swizzle(cameraPreviewNode, @selector(wheelNodeSelectedIndexChanged:), @selector(swizzled_wheelNodeSelectedIndexChanged:));
    }
    
    NSLog(@"[TelegramCallTweak] Dynamic swizzler completed setup!");
}
