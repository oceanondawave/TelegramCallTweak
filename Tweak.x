#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// --- Function Pointer Types for Original System Implementations ---

typedef BOOL (*SetCategoryWithOptionsIMP)(id, SEL, AVAudioSessionCategory, AVAudioSessionCategoryOptions, NSError **);
typedef BOOL (*SetCategoryWithModeOptionsIMP)(id, SEL, AVAudioSessionCategory, AVAudioSessionMode, AVAudioSessionCategoryOptions, NSError **);
typedef BOOL (*SetModeIMP)(id, SEL, AVAudioSessionMode, NSError **);
typedef AVAudioSessionCategoryOptions (*CategoryOptionsIMP)(id, SEL);

static SetCategoryWithOptionsIMP gOriginalSetCategoryWithOptions = NULL;
static SetCategoryWithModeOptionsIMP gOriginalSetCategoryWithModeOptions = NULL;
static SetModeIMP gOriginalSetMode = NULL;
static CategoryOptionsIMP gOriginalCategoryOptions = NULL;

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
    
    AVAudioSessionRouteDescription *currentRoute = session.currentRoute;
    if (currentRoute.inputs.count == 0) {
        NSLog(@"[TelegramCallTweak] Active inputs are empty. Audio session is in playback-only state (ringing/dialing). Skipping override.");
        return;
    }
    
    // Safety check: Only override when the active output is NOT the built-in receiver or speaker.
    // If the active output is an external accessory (Bluetooth headset, A2DP output, AirPods, headphones), we force the built-in mic.
    // This safely prevents dialing mute because during dialing/ringing, the route output is directed to internal channels.
    BOOL hasExternalAccessoryOutput = NO;
    for (AVAudioSessionPortDescription *desc in currentRoute.outputs) {
        NSString *portType = desc.portType;
        if (![portType isEqualToString:AVAudioSessionPortBuiltInReceiver] &&
            ![portType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
            hasExternalAccessoryOutput = YES;
            break;
        }
    }
    
    if (!hasExternalAccessoryOutput) {
        NSLog(@"[TelegramCallTweak] Active output is internal receiver/speaker. Skipping override to prevent dialing mute.");
        return;
    }
    
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
    AVAudioSessionCategoryOptions realOptions = gOriginalCategoryOptions ? gOriginalCategoryOptions(self, _cmd) : [self swizzled_categoryOptions];
    if (getForceBuiltInMicSetting()) {
        // If we internally configured 32, trick Telegram's checks into thinking it is 37 (HFP + A2DP + Speaker)
        if (realOptions == AVAudioSessionCategoryOptionAllowBluetoothA2DP) {
            return (AVAudioSessionCategoryOptionAllowBluetooth | AVAudioSessionCategoryOptionAllowBluetoothA2DP | AVAudioSessionCategoryOptionDefaultToSpeaker);
        }
    }
    return realOptions;
}

- (BOOL)swizzled_setCategory:(AVAudioSessionCategory)category mode:(AVAudioSessionMode)mode options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    if (getForceBuiltInMicSetting()) {
        NSLog(@"[TelegramCallTweak] Intercepted setCategory:mode:options: Category=%@, Mode=%@, Options=%lu", category, mode, (unsigned long)options);
        
        AVAudioSessionCategoryOptions modifiedOptions = options;
        AVAudioSessionCategory modifiedCategory = category;
        AVAudioSessionMode modifiedMode = mode;
        
        if ([category isEqualToString:AVAudioSessionCategoryPlayAndRecord] || [mode isEqualToString:AVAudioSessionModeVoiceChat] || [mode isEqualToString:AVAudioSessionModeVideoChat]) {
            modifiedCategory = AVAudioSessionCategoryPlayAndRecord;
            modifiedMode = AVAudioSessionModeVideoChat;
            modifiedOptions = AVAudioSessionCategoryOptionAllowBluetoothA2DP;
        }
        
        BOOL success = NO;
        if (gOriginalSetCategoryWithModeOptions) {
            success = gOriginalSetCategoryWithModeOptions(self, @selector(setCategory:mode:options:error:), modifiedCategory, modifiedMode, modifiedOptions, outError);
        } else {
            success = [self swizzled_setCategory:modifiedCategory mode:modifiedMode options:modifiedOptions error:outError];
        }
        enforceBuiltInMicInput(self);
        return success;
    }
    
    if (gOriginalSetCategoryWithModeOptions) {
         return gOriginalSetCategoryWithModeOptions(self, @selector(setCategory:mode:options:error:), category, mode, options, outError);
    }
    return [self swizzled_setCategory:category mode:mode options:options error:outError];
}

- (BOOL)swizzled_setCategory:(AVAudioSessionCategory)category options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    if (getForceBuiltInMicSetting()) {
        NSLog(@"[TelegramCallTweak] Intercepted setCategory:options: Category=%@, Options=%lu", category, (unsigned long)options);
        
        AVAudioSessionCategoryOptions modifiedOptions = options;
        AVAudioSessionCategory modifiedCategory = category;
        
        if ([category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
            modifiedCategory = AVAudioSessionCategoryPlayAndRecord;
            modifiedOptions = AVAudioSessionCategoryOptionAllowBluetoothA2DP;
        }
        
        BOOL success = NO;
        if (gOriginalSetCategoryWithOptions) {
            success = gOriginalSetCategoryWithOptions(self, @selector(setCategory:options:error:), modifiedCategory, modifiedOptions, outError);
        } else {
            success = [self swizzled_setCategory:modifiedCategory options:modifiedOptions error:outError];
        }
        enforceBuiltInMicInput(self);
        return success;
    }
    
    if (gOriginalSetCategoryWithOptions) {
        return gOriginalSetCategoryWithOptions(self, @selector(setCategory:options:error:), category, options, outError);
    }
    return [self swizzled_setCategory:category options:options error:outError];
}

- (BOOL)swizzled_setMode:(AVAudioSessionMode)mode error:(NSError **)outError {
    if (getForceBuiltInMicSetting()) {
        NSLog(@"[TelegramCallTweak] Intercepted setMode: Mode=%@", mode);
        
        AVAudioSessionMode modifiedMode = mode;
        if ([mode isEqualToString:AVAudioSessionModeVoiceChat] || [mode isEqualToString:AVAudioSessionModeVideoChat]) {
            modifiedMode = AVAudioSessionModeVideoChat; // VideoChat mode allows split input/output
            
            // Force the audio session to PlayAndRecord + VideoChat + AllowBluetoothA2DP
            if (gOriginalSetCategoryWithModeOptions) {
                NSError *categoryError = nil;
                gOriginalSetCategoryWithModeOptions(self, @selector(setCategory:mode:options:error:), AVAudioSessionCategoryPlayAndRecord, AVAudioSessionModeVideoChat, AVAudioSessionCategoryOptionAllowBluetoothA2DP, &categoryError);
                if (categoryError) {
                    NSLog(@"[TelegramCallTweak] Error setting category inside setMode: %@", categoryError.localizedDescription);
                }
            }
        }
        
        BOOL success = NO;
        if (gOriginalSetMode) {
            success = gOriginalSetMode(self, @selector(setMode:error:), modifiedMode, outError);
        } else {
            success = [self swizzled_setMode:modifiedMode error:outError];
        }
        enforceBuiltInMicInput(self);
        return success;
    }
    
    if (gOriginalSetMode) {
        return gOriginalSetMode(self, @selector(setMode:error:), mode, outError);
    }
    return [self swizzled_setMode:mode error:outError];
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
    
    // Save original implementations of AVAudioSession methods BEFORE swizzling them
    Class avAudioSessionClass = NSClassFromString(@"AVAudioSession");
    if (avAudioSessionClass) {
        Method m1 = class_getInstanceMethod(avAudioSessionClass, @selector(setCategory:options:error:));
        if (m1) gOriginalSetCategoryWithOptions = (SetCategoryWithOptionsIMP)method_getImplementation(m1);
        
        Method m2 = class_getInstanceMethod(avAudioSessionClass, @selector(setCategory:mode:options:error:));
        if (m2) gOriginalSetCategoryWithModeOptions = (SetCategoryWithModeOptionsIMP)method_getImplementation(m2);
        
        Method m3 = class_getInstanceMethod(avAudioSessionClass, @selector(setMode:error:));
        if (m3) gOriginalSetMode = (SetModeIMP)method_getImplementation(m3);
        
        Method m4 = class_getInstanceMethod(avAudioSessionClass, @selector(categoryOptions));
        if (m4) gOriginalCategoryOptions = (CategoryOptionsIMP)method_getImplementation(m4);
        
        // Swizzle implementations
        swizzle(avAudioSessionClass, @selector(setCategory:mode:options:error:), @selector(swizzled_setCategory:mode:options:error:));
        swizzle(avAudioSessionClass, @selector(setCategory:options:error:), @selector(swizzled_setCategory:options:error:));
        swizzle(avAudioSessionClass, @selector(setMode:error:), @selector(swizzled_setMode:error:));
        swizzle(avAudioSessionClass, @selector(categoryOptions), @selector(swizzled_categoryOptions));
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
