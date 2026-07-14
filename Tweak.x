#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// --- Helper storage for custom call settings reading directly from Swiftgram's App Group ---

static NSUserDefaults *getSwiftgramGroupDefaults() {
    NSString *baseBundleId = [[NSBundle mainBundle] bundleIdentifier];
    if ([[[NSBundle mainBundle] bundlePath] hasSuffix:@".appex"]) {
        NSRange lastDotRange = [baseBundleId rangeOfString:@"." options:NSBackwardsSearch];
        if (lastDotRange.location != NSNotFound) {
            baseBundleId = [baseBundleId substringToIndex:lastDotRange.location];
        }
    }
    NSString *groupName = [NSString stringWithFormat:@"group.%@", baseBundleId];
    NSLog(@"[TelegramCallTweak] Resolved App Group Name: %@", groupName);
    return [[NSUserDefaults alloc] initWithSuiteName:groupName];
}

static BOOL getForceBuiltInMicSetting() {
    NSUserDefaults *defaults = getSwiftgramGroupDefaults();
    BOOL val = [defaults boolForKey:@"forceBuiltInMic"];
    // Also print out the entire settings keys for debugging
    NSLog(@"[TelegramCallTweak] Reading 'forceBuiltInMic' value: %d", val);
    return val;
}

static BOOL getShareAudioOnlySetting() {
    NSUserDefaults *defaults = getSwiftgramGroupDefaults();
    BOOL val = [defaults boolForKey:@"shareAudioOnly"];
    NSLog(@"[TelegramCallTweak] Reading 'shareAudioOnly' value: %d", val);
    return val;
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
    NSLog(@"[TelegramCallTweak] setPreferredInput called with port: %@", inPort.portType);
    if (getForceBuiltInMicSetting()) {
        AVAudioSessionPortDescription *builtInMic = nil;
        for (AVAudioSessionPortDescription *port in self.availableInputs) {
            if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
                builtInMic = port;
                break;
            }
        }
        if (builtInMic) {
            NSLog(@"[TelegramCallTweak] Force Device Mic is ON. Redirecting setPreferredInput from %@ to Built-in Mic", inPort.portType);
            return [self swizzled_setPreferredInput:builtInMic error:outError];
        }
    }
    return [self swizzled_setPreferredInput:inPort error:outError];
}
@end

// 2. Hook VideoCameraCapturer to drop outgoing frames when Share Audio Only is enabled
@interface VideoCameraCapturerHook : NSObject
@end
@implementation VideoCameraCapturerHook
- (void)swizzled_captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (getShareAudioOnlySetting()) {
        NSLog(@"[TelegramCallTweak] Share Audio Only is ON. Dropping video frame buffer.");
        return;
    }
    // Forward to original implementation
    typedef void (*OriginalMethodType)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *);
    SEL selector = NSSelectorFromString(@"swizzled_captureOutput:didOutputSampleBuffer:fromConnection:");
    Method originalMethod = class_getInstanceMethod([self class], selector);
    if (originalMethod) {
        OriginalMethodType imp = (OriginalMethodType)method_getImplementation(originalMethod);
        imp(self, selector, captureOutput, sampleBuffer, connection);
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
    
    // Hook VideoCameraCapturer
    Class videoCameraCapturer = NSClassFromString(@"VideoCameraCapturer");
    if (videoCameraCapturer) {
        NSLog(@"[TelegramCallTweak] Hooking VideoCameraCapturer...");
        SEL captureSelector = NSSelectorFromString(@"captureOutput:didOutputSampleBuffer:fromConnection:");
        if (class_getInstanceMethod(videoCameraCapturer, captureSelector)) {
            Method swizzledMethod = class_getInstanceMethod([VideoCameraCapturerHook class], @selector(swizzled_captureOutput:didOutputSampleBuffer:fromConnection:));
            BOOL added = class_addMethod(videoCameraCapturer,
                                         NSSelectorFromString(@"swizzled_captureOutput:didOutputSampleBuffer:fromConnection:"),
                                         method_getImplementation(swizzledMethod),
                                         method_getTypeEncoding(swizzledMethod));
            if (added) {
                swizzle(videoCameraCapturer, captureSelector, NSSelectorFromString(@"swizzled_captureOutput:didOutputSampleBuffer:fromConnection:"));
            }
        }
    }
    
    NSLog(@"[TelegramCallTweak] Dynamic swizzler completed setup!");
}
