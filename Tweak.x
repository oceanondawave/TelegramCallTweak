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
    return [defaults boolForKey:@"tweak_forceBuiltInMic"];
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
    return [defaults boolForKey:@"tweak_shareAudioOnly"];
}

static void setShareAudioOnlySetting(BOOL value) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:value forKey:@"tweak_shareAudioOnly"];
    [defaults synchronize];
}

// --- Helper input routing enforcer ---

static void enforceBuiltInMicInput(AVAudioSession *session) {
    if (!getForceBuiltInMicSetting()) {
        return;
    }
    
    // Safety check: Only override if the current active route actually has an active input stream populated.
    AVAudioSessionRouteDescription *currentRoute = session.currentRoute;
    if (currentRoute.inputs.count == 0) {
        NSLog(@"[TelegramCallTweak] Active inputs are empty. Audio session is in playback-only state (ringing/dialing). Skipping override.");
        return;
    }
    
    // Check if the current audio output is directed to an external accessory (Bluetooth, A2DP, AirPods, Headphones)
    BOOL hasExternalAccessoryOutput = NO;
    for (AVAudioSessionPortDescription *desc in currentRoute.outputs) {
        NSString *portType = desc.portType;
        if (![portType isEqualToString:AVAudioSessionPortBuiltInReceiver] &&
            ![portType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
            hasExternalAccessoryOutput = YES;
            break;
        }
    }
    
    // Check if there is a Bluetooth output device available in the system
    BOOL isBluetoothConnected = NO;
    for (AVAudioSessionPortDescription *port in session.currentRoute.outputs) {
         if ([port.portType rangeOfString:@"Bluetooth" options:NSCaseInsensitiveSearch].location != NSNotFound ||
             [port.portType rangeOfString:@"Headphones" options:NSCaseInsensitiveSearch].location != NSNotFound) {
             isBluetoothConnected = YES;
             break;
         }
    }
    if (!isBluetoothConnected) {
        for (AVAudioSessionPortDescription *port in [[AVAudioSession sharedInstance] availableInputs]) {
            if ([port.portType rangeOfString:@"Bluetooth" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                isBluetoothConnected = YES;
                break;
            }
        }
    }
    
    // If Bluetooth is connected but the output fell back to internal receiver/speaker:
    // We force option 32 (A2DP) on the category to bring output audio back to the Bluetooth headset!
    if (isBluetoothConnected && !hasExternalAccessoryOutput) {
        NSLog(@"[TelegramCallTweak] Bluetooth is connected but output fell back to internal. Forcing category options...");
        NSError *categoryError = nil;
        
        // Use Apple's direct setter to apply the options. This is safe inside the route change observer.
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                        mode:AVAudioSessionModeVideoChat
                     options:AVAudioSessionCategoryOptionAllowBluetoothA2DP
                       error:&categoryError];
        
        if (categoryError) {
             NSLog(@"[TelegramCallTweak] Error setting A2DP Category inside route change enforcer: %@", categoryError.localizedDescription);
        } else {
             NSLog(@"[TelegramCallTweak] Successfully forced A2DP Category Option.");
        }
    }
    
    // Force the microphone to built-in
    AVAudioSessionPortDescription *builtInMic = nil;
    for (AVAudioSessionPortDescription *port in session.availableInputs) {
        if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
            builtInMic = port;
            break;
        }
    }
    
    if (builtInMic) {
        BOOL isAlreadyMic = NO;
        for (AVAudioSessionPortDescription *input in currentRoute.inputs) {
            if ([input.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
                isAlreadyMic = YES;
                break;
            }
        }
        
        if (!isAlreadyMic) {
            NSError *error = nil;
            BOOL success = [session setPreferredInput:builtInMic error:&error];
            NSLog(@"[TelegramCallTweak] Forced input to Built-in Mic: %d (Error: %@)", success, error);
        } else {
            NSLog(@"[TelegramCallTweak] Built-in Mic is already the active input.");
        }
    }
}

// --- Hooking AVAudioSession Configuration Methods ---

@interface AVAudioSession (TweakCategoryHook)
@end

@implementation AVAudioSession (TweakCategoryHook)

// Trick Telegram's category option checks: Whenever Telegram queries categoryOptions, we return HFP allowed (value 37)
// to prevent it from entering a configuration rewrite loop.
- (AVAudioSessionCategoryOptions)swizzled_categoryOptions {
    AVAudioSessionCategoryOptions realOptions = [self swizzled_categoryOptions];
    if (getForceBuiltInMicSetting()) {
        if (realOptions & AVAudioSessionCategoryOptionAllowBluetoothA2DP) {
            return (realOptions | AVAudioSessionCategoryOptionAllowBluetooth | AVAudioSessionCategoryOptionDefaultToSpeaker);
        }
    }
    return realOptions;
}

@end

// --- Route Change Notification Observer ---
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
    }
    return self;
}
- (void)audioRouteChanged:(NSNotification *)notification {
    if (getForceBuiltInMicSetting()) {
        enforceBuiltInMicInput([AVAudioSession sharedInstance]);
    }
}
@end

static TweakAudioObserver *gAudioObserver = nil;

// --- Swizzled Video/Camera Methods ---

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

// Window launch configuration alerts
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
                    enforceBuiltInMicInput([AVAudioSession sharedInstance]);
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
    
    // We only hook categoryOptions getter to keep Telegram's checks happy. 
    Class avAudioSessionClass = NSClassFromString(@"AVAudioSession");
    if (avAudioSessionClass) {
        swizzle(avAudioSessionClass, @selector(categoryOptions), @selector(swizzled_categoryOptions));
        NSLog(@"[TelegramCallTweak] Hooked AVAudioSession category options successfully.");
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
