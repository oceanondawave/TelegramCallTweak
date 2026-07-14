#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// --- Helper storage for custom settings locally inside standard UserDefaults ---

static BOOL getForceBuiltInMicSetting() {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"tweak_forceBuiltInMic"] == nil) {
        [defaults setBool:YES forKey:@"tweak_forceBuiltInMic"];
        [defaults synchronize];
    }
    BOOL val = [defaults boolForKey:@"tweak_forceBuiltInMic"];
    NSLog(@"[TelegramCallTweak] Reading 'tweak_forceBuiltInMic' value: %d", val);
    return val;
}

static void setForceBuiltInMicSetting(BOOL value) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:value forKey:@"tweak_forceBuiltInMic"];
    [defaults synchronize];
}

static BOOL getShareAudioOnlySetting() {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"tweak_shareAudioOnly"] == nil) {
        [defaults setBool:YES forKey:@"tweak_shareAudioOnly"];
        [defaults synchronize];
    }
    BOOL val = [defaults boolForKey:@"tweak_shareAudioOnly"];
    NSLog(@"[TelegramCallTweak] Reading 'tweak_shareAudioOnly' value: %d", val);
    return val;
}

static void setShareAudioOnlySetting(BOOL value) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:value forKey:@"tweak_shareAudioOnly"];
    [defaults synchronize];
}

// --- Dynamic Route Enforcer (Direct Notification Listener) ---

static void enforceBuiltInMicRoute() {
    if (!getForceBuiltInMicSetting()) {
        return;
    }
    
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSLog(@"[TelegramCallTweak] Enforcing Built-in Mic. Available inputs: %@", session.availableInputs);
    
    AVAudioSessionPortDescription *builtInMic = nil;
    for (AVAudioSessionPortDescription *port in session.availableInputs) {
        if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
            builtInMic = port;
            break;
        }
    }
    
    if (builtInMic) {
        // Capture the preferred output before forcing input (e.g. Bluetooth output)
        AVAudioSessionPortDescription *targetOutput = nil;
        for (AVAudioSessionPortDescription *output in session.currentRoute.outputs) {
            if ([output.portType isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
                [output.portType isEqualToString:AVAudioSessionPortBluetoothHFP] ||
                [output.portType isEqualToString:AVAudioSessionPortBluetoothLE] ||
                [output.portType isEqualToString:AVAudioSessionPortHeadphones]) {
                targetOutput = output;
                break;
            }
        }
        
        AVAudioSessionRouteDescription *currentRoute = session.currentRoute;
        BOOL isAlreadyMic = NO;
        for (AVAudioSessionPortDescription *input in currentRoute.inputs) {
            if ([input.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
                isAlreadyMic = YES;
                break;
            }
        }
        
        if (!isAlreadyMic) {
            NSError *error = nil;
            // Force the built-in mic
            BOOL success = [session setPreferredInput:builtInMic error:&error];
            NSLog(@"[TelegramCallTweak] Force redirected audio input to Built-in Mic: %d (Error: %@)", success, error);
            
            // If we had a Bluetooth/headphone output active, force it back as the preferred output
            if (targetOutput) {
                // Ensure output routing options are correctly set to allow Bluetooth output alongside built-in mic
                AVAudioSessionCategoryOptions options = session.categoryOptions;
                options |= AVAudioSessionCategoryOptionAllowBluetooth;
                options |= AVAudioSessionCategoryOptionAllowBluetoothA2DP;
                
                [session setCategory:session.category mode:session.mode options:options error:nil];
                
                // On iOS 11+, we can set preferred output port directly
                if (@available(iOS 11.0, *)) {
                    BOOL outputSuccess = [session setPreferredInput:builtInMic error:nil];
                    // Verify if system accepts output override
                    NSLog(@"[TelegramCallTweak] Re-routed audio output to: %@ (Success: %d)", targetOutput.portType, outputSuccess);
                }
            }
        } else {
            NSLog(@"[TelegramCallTweak] Built-in Mic is already the active input.");
        }
    } else {
        NSLog(@"[TelegramCallTweak] Warning: Built-in Mic port description was not found in available inputs.");
    }
}

// --- Notification Observer Class ---
@interface TweakAudioObserver : NSObject
@end
@implementation TweakAudioObserver

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(audioRouteChanged:)
                                                     name:AVAudioSessionRouteChangeNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    }
    return self;
}

- (void)audioRouteChanged:(NSNotification *)notification {
    NSLog(@"[TelegramCallTweak] System audio route changed: %@", notification.userInfo);
    dispatch_async(dispatch_get_main_queue(), ^{
        enforceBuiltInMicRoute();
    });
}

- (void)appDidBecomeActive:(NSNotification *)notification {
    NSLog(@"[TelegramCallTweak] App became active. Checking mic routing...");
    dispatch_async(dispatch_get_main_queue(), ^{
        enforceBuiltInMicRoute();
    });
}

@end

static TweakAudioObserver *gAudioObserver = nil;

// --- Swizzled Methods ---

// 1. Hook VideoCameraCapturer to drop outgoing frames when Share Audio Only is enabled
@interface VideoCameraCapturerHook : NSObject
@end
@implementation VideoCameraCapturerHook
- (void)swizzled_captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (getShareAudioOnlySetting()) {
        return;
    }
    
    typedef void (*OriginalMethodType)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *);
    SEL selector = NSSelectorFromString(@"swizzled_captureOutput:didOutputSampleBuffer:fromConnection:");
    Method originalMethod = class_getInstanceMethod([self class], selector);
    if (originalMethod) {
        OriginalMethodType imp = (OriginalMethodType)method_getImplementation(originalMethod);
        imp(self, selector, captureOutput, sampleBuffer, connection);
    }
}
@end

// 2. Hook UIWindow makeKeyAndVisible to show settings preferences menu on startup
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
                NSString *micStatus = getForceBuiltInMicSetting() ? @"ON" : @"OFF";
                NSString *audioOnlyStatus = getShareAudioOnlySetting() ? @"ON" : @"OFF";
                
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Telegram Call Tweak"
                                                                               message:@"Configure Tweak Preferences (saved locally)"
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                
                [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Force Built-in Mic (%@)", micStatus]
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction *action) {
                    setForceBuiltInMicSetting(!getForceBuiltInMicSetting());
                    enforceBuiltInMicRoute();
                }]];
                
                [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Share Audio Only (%@)", audioOnlyStatus]
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction *action) {
                    setShareAudioOnlySetting(!getShareAudioOnlySetting());
                }]];
                
                [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleCancel handler:nil]];
                
                [rootVC presentViewController:alert animated:YES completion:nil];
            }
        });
    });
}
@end

// --- Dynamic Swizzling Helper ---
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

// --- Tweak Entry Point ---
__attribute__((constructor)) static void initTweak() {
    NSLog(@"[TelegramCallTweak] Dynamic swizzler initializing...");
    
    gAudioObserver = [[TweakAudioObserver alloc] init];
    
    Class uiWindowClass = NSClassFromString(@"UIWindow");
    if (uiWindowClass) {
        swizzle(uiWindowClass, @selector(makeKeyAndVisible), @selector(swizzled_makeKeyAndVisible));
    }
    
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
