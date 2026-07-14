#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// --- Helper storage for custom call settings with persistent settings ---

static NSString *const kSettingsSuiteName = @"ph.telegra.telegramcalltweak";
static NSString *const kForceBuiltInMicKey = @"forceBuiltInMic";
static NSString *const kShareAudioOnlyKey = @"shareAudioOnly";

static BOOL getForceBuiltInMicSetting() {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSettingsSuiteName];
    return [defaults boolForKey:kForceBuiltInMicKey];
}

static BOOL getShareAudioOnlySetting() {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSettingsSuiteName];
    return [defaults boolForKey:kShareAudioOnlyKey];
}

// --- Dynamic Swizzling Implementation (TrollStore / Sideload Friendly) ---

static void swizzle(Class class, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(class, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(class, swizzledSelector);
    
    if (!originalMethod || !swizzledMethod) {
        return;
    }
    
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

// 1. Hook public AVAudioSession to intercept and force Built-in Mic
@interface AVAudioSession (TweakHook)
@end
@implementation AVAudioSession (TweakHook)
- (BOOL)swizzled_setPreferredInput:(AVAudioSessionPortDescription *)inPort error:(NSError **)outError {
    if (getForceBuiltInMicSetting()) {
        // Find built-in mic port
        AVAudioSessionPortDescription *builtInMic = nil;
        for (AVAudioSessionPortDescription *port in self.availableInputs) {
            if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
                builtInMic = port;
                break;
            }
        }
        if (builtInMic) {
            NSLog(@"[TelegramCallTweak] Redirecting setPreferredInput from %@ to Built-in Mic", inPort.portType);
            return [self swizzled_setPreferredInput:builtInMic error:outError];
        }
    }
    return [self swizzled_setPreferredInput:inPort error:outError];
}
@end

// 2. Hook WebRTC video capturer to block outgoing video frames when Audio-Only is enabled
@interface RTCCameraVideoCapturerHook : NSObject
@end
@implementation RTCCameraVideoCapturerHook
- (void)swizzled_captureOutput:(id)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(id)connection {
    if (getShareAudioOnlySetting()) {
        // Drop the frame
        return;
    }
    // Forward to original implementation
    typedef void (*OriginalMethodType)(id, SEL, id, CMSampleBufferRef, id);
    SEL selector = NSSelectorFromString(@"swizzled_captureOutput:didOutputSampleBuffer:fromConnection:");
    Method originalMethod = class_getInstanceMethod([self class], selector);
    if (originalMethod) {
        OriginalMethodType imp = (OriginalMethodType)method_getImplementation(originalMethod);
        imp(self, selector, output, sampleBuffer, connection);
    }
}
@end

// 3. Hook UIWindow makeKeyAndVisible to show launch confirmation popup
@interface UIWindow (TweakHook)
@end
@implementation UIWindow (TweakHook)
- (void)swizzled_makeKeyAndVisible {
    [self swizzled_makeKeyAndVisible];
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *rootVC = self.rootViewController;
            if (rootVC) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Tweak Injected"
                                                                               message:@"TelegramCallTweak has loaded successfully!"
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [rootVC presentViewController:alert animated:YES completion:nil];
            }
        });
    });
}
@end

// --- Tweak Entry Point ---
__attribute__((constructor)) static void initTweak() {
    NSLog(@"[TelegramCallTweak] Dynamic swizzler initializing...");
    
    // Hook UIWindow makeKeyAndVisible
    Class uiWindowClass = NSClassFromString(@"UIWindow");
    if (uiWindowClass) {
        swizzle(uiWindowClass, @selector(makeKeyAndVisible), @selector(swizzled_makeKeyAndVisible));
    }
    
    // Hook system AVAudioSession input routing
    Class avAudioSessionClass = NSClassFromString(@"AVAudioSession");
    if (avAudioSessionClass) {
        NSLog(@"[TelegramCallTweak] Hooking AVAudioSession...");
        swizzle(avAudioSessionClass, @selector(setPreferredInput:error:), @selector(swizzled_setPreferredInput:error:));
    }
    
    // Hook WebRTC Camera / Screen Capturer
    Class rtcCameraCapturer = NSClassFromString(@"RTCCameraVideoCapturer");
    if (rtcCameraCapturer) {
        NSLog(@"[TelegramCallTweak] Hooking RTCCameraVideoCapturer...");
        SEL captureSelector = NSSelectorFromString(@"captureOutput:didOutputSampleBuffer:fromConnection:");
        if (class_getInstanceMethod(rtcCameraCapturer, captureSelector)) {
            // Inject swizzled method dynamically
            Method swizzledMethod = class_getInstanceMethod([RTCCameraVideoCapturerHook class], @selector(swizzled_captureOutput:didOutputSampleBuffer:fromConnection:));
            BOOL added = class_addMethod(rtcCameraCapturer,
                                         NSSelectorFromString(@"swizzled_captureOutput:didOutputSampleBuffer:fromConnection:"),
                                         method_getImplementation(swizzledMethod),
                                         method_getTypeEncoding(swizzledMethod));
            if (added) {
                swizzle(rtcCameraCapturer, captureSelector, NSSelectorFromString(@"swizzled_captureOutput:didOutputSampleBuffer:fromConnection:"));
            }
        }
    }
    
    NSLog(@"[TelegramCallTweak] Dynamic swizzler completed setup!");
}
