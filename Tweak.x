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
    AVAudioSessionPortDescription *builtInMic = nil;
    for (AVAudioSessionPortDescription *port in session.availableInputs) {
        if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
            builtInMic = port;
            break;
        }
    }
    if (builtInMic) {
        NSError *err = nil;
        [session setPreferredInput:builtInMic error:&err];
        NSLog(@"[TelegramCallTweak] Enforced Built-in Mic input. Status: %@", err ? err.localizedDescription : @"Success");
    }
}

// --- Hooking AVAudioSession Configuration Methods ---

@interface AVAudioSession (TweakCategoryHook)
@end

@implementation AVAudioSession (TweakCategoryHook)

- (BOOL)swizzled_setCategory:(AVAudioSessionCategory)category mode:(AVAudioSessionMode)mode options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    if (getForceBuiltInMicSetting()) {
        NSLog(@"[TelegramCallTweak] Intercepted setCategory:mode:options: Category=%@, Mode=%@, Options=%lu", category, mode, (unsigned long)options);
        
        // Strip AVAudioSessionCategoryOptionAllowBluetooth (value 4) to prevent HFP session from taking over
        AVAudioSessionCategoryOptions modifiedOptions = options;
        modifiedOptions &= ~AVAudioSessionCategoryOptionAllowBluetooth; // Remove HFP
        modifiedOptions |= AVAudioSessionCategoryOptionAllowBluetoothA2DP; // Force high-quality media output
        modifiedOptions |= AVAudioSessionCategoryOptionDefaultToSpeaker;
        
        AVAudioSessionMode modifiedMode = mode;
        if ([mode isEqualToString:AVAudioSessionModeVoiceChat]) {
            modifiedMode = AVAudioSessionModeVideoChat; // Use VideoChat layout to allow route splitting
        }
        
        NSLog(@"[TelegramCallTweak] Modified parameters: Mode=%@, Options=%lu", modifiedMode, (unsigned long)modifiedOptions);
        
        BOOL success = [self swizzled_setCategory:category mode:modifiedMode options:modifiedOptions error:outError];
        enforceBuiltInMicInput(self);
        return success;
    }
    return [self swizzled_setCategory:category mode:mode options:options error:outError];
}

- (BOOL)swizzled_setCategory:(AVAudioSessionCategory)category withOptions:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    if (getForceBuiltInMicSetting()) {
        NSLog(@"[TelegramCallTweak] Intercepted setCategory:withOptions: Category=%@, Options=%lu", category, (unsigned long)options);
        
        // Strip AVAudioSessionCategoryOptionAllowBluetooth (value 4)
        AVAudioSessionCategoryOptions modifiedOptions = options;
        modifiedOptions &= ~AVAudioSessionCategoryOptionAllowBluetooth;
        modifiedOptions |= AVAudioSessionCategoryOptionAllowBluetoothA2DP;
        modifiedOptions |= AVAudioSessionCategoryOptionDefaultToSpeaker;
        
        NSLog(@"[TelegramCallTweak] Modified Options: %lu", (unsigned long)modifiedOptions);
        
        BOOL success = [self swizzled_setCategory:category withOptions:modifiedOptions error:outError];
        enforceBuiltInMicInput(self);
        return success;
    }
    return [self swizzled_setCategory:category withOptions:options error:outError];
}

- (BOOL)swizzled_setMode:(AVAudioSessionMode)mode error:(NSError **)outError {
    if (getForceBuiltInMicSetting()) {
        NSLog(@"[TelegramCallTweak] Intercepted setMode: Mode=%@", mode);
        AVAudioSessionMode modifiedMode = mode;
        if ([mode isEqualToString:AVAudioSessionModeVoiceChat]) {
            modifiedMode = AVAudioSessionModeVideoChat;
        }
        BOOL success = [self swizzled_setMode:modifiedMode error:outError];
        enforceBuiltInMicInput(self);
        return success;
    }
    return [self swizzled_setMode:mode error:outError];
}

@end

// --- Route Change Notification observer (as backup) ---
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
        dispatch_async(dispatch_get_main_queue(), ^{
            enforceBuiltInMicInput([AVAudioSession sharedInstance]);
        });
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
    
    // Hook AVAudioSession setCategory / setMode methods directly
    Class avAudioSessionClass = NSClassFromString(@"AVAudioSession");
    if (avAudioSessionClass) {
        swizzle(avAudioSessionClass, @selector(setCategory:mode:options:error:), @selector(swizzled_setCategory:mode:options:error:));
        swizzle(avAudioSessionClass, @selector(setCategory:withOptions:error:), @selector(swizzled_setCategory:withOptions:error:));
        swizzle(avAudioSessionClass, @selector(setMode:error:), @selector(swizzled_setMode:error:));
        NSLog(@"[TelegramCallTweak] Hooked AVAudioSession category and mode switches successfully.");
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
