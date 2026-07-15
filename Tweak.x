#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

// --- File-Based Shared Preferences Manager ---

static NSString *getSharedPrefsFilePath() {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    
    // Resolve base app bundle ID dynamically by removing any extension suffix
    NSString *baseBundleId = bundleId;
    NSArray *parts = [bundleId componentsSeparatedByString:@"."];
    if (parts.count > 3) {
        // e.g. "app.swiftgram.ios.BroadcastUpload" -> "app.swiftgram.ios"
        NSMutableArray *subparts = [parts mutableCopy];
        [subparts removeLastObject];
        baseBundleId = [subparts componentsJoinedByString:@"."];
    }
    
    NSString *appGroupName = [NSString stringWithFormat:@"group.%@", baseBundleId];
    NSURL *groupURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:appGroupName];
    if (!groupURL) {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        return [docs stringByAppendingPathComponent:@"tweak_preferences.plist"];
    }
    
    NSString *dataDirectory = [groupURL.path stringByAppendingPathComponent:@"telegram-data"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dataDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    
    return [dataDirectory stringByAppendingPathComponent:@"tweak_preferences.plist"];
}

static BOOL readTweakSetting(NSString *key, BOOL defaultValue) {
    @try {
        NSString *path = getSharedPrefsFilePath();
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!dict || [dict objectForKey:key] == nil) {
            return defaultValue;
        }
        return [[dict objectForKey:key] boolValue];
    } @catch (NSException *exception) {
        return defaultValue;
    }
}

static void writeTweakSetting(NSString *key, BOOL value) {
    @try {
        NSString *path = getSharedPrefsFilePath();
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:path];
        if (!dict) {
            dict = [NSMutableDictionary dictionary];
        }
        [dict setObject:@(value) forKey:key];
        [dict writeToFile:path atomically:YES];
    } @catch (NSException *exception) {
        NSLog(@"[TelegramCallTweak] Exception saving setting: %@", exception.reason);
    }
}

// --- Helper storage for custom settings locally ---

static BOOL getForceBuiltInMicSetting() {
    return readTweakSetting(@"tweak_forceBuiltInMic", YES);
}

static void setForceBuiltInMicSetting(BOOL value) {
    writeTweakSetting(@"tweak_forceBuiltInMic", value);
}

static BOOL getShareAudioOnlySetting() {
    return readTweakSetting(@"tweak_shareAudioOnly", YES);
}

static void setShareAudioOnlySetting(BOOL value) {
    writeTweakSetting(@"tweak_shareAudioOnly", value);
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

// --- OngoingCallThreadLocalContextVideoCapturer Frame Blocker Hook ---

@interface OngoingCallThreadLocalContextVideoCapturerHook : NSObject
@end

@implementation OngoingCallThreadLocalContextVideoCapturerHook

static void (*gOriginalSubmitSampleBuffer)(id, SEL, CMSampleBufferRef, NSInteger, id) = NULL;

- (void)swizzled_submitSampleBuffer:(CMSampleBufferRef)sampleBuffer rotation:(NSInteger)rotation completion:(id)completion {
    if (getShareAudioOnlySetting()) {
        if (completion) {
            void (^completionBlock)(void) = completion;
            completionBlock();
        }
        return; // Drops screen sharing and camera video frames at the WebRTC engine layer
    }
    
    if (gOriginalSubmitSampleBuffer) {
        gOriginalSubmitSampleBuffer(self, @selector(submitSampleBuffer:rotation:completion:), sampleBuffer, rotation, completion);
    }
}
@end

// Window launch configuration alerts
@interface UIWindow (TweakHook)
@end
@implementation UIWindow (TweakHook)
- (void)swizzled_makeKeyAndVisible {
    [self swizzled_makeKeyAndVisible];
    
    // We only present preferences config alerts inside the main application process.
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleId hasSuffix:@".BroadcastUpload"]) {
         return;
    }
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *rootVC = self.rootViewController;
            if (rootVC) {
                NSString *micStatus = getForceBuiltInMicSetting() ? @"ON" : @"OFF";
                NSString *audioOnlyStatus = getShareAudioOnlySetting() ? @"ON" : @"OFF";
                
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Telegram Call Tweak"
                                                                               message:@"Configure Tweak Preferences (saved in Shared App Path)"
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

// --- Dynamic Dyld Image Loader Hook ---
static BOOL gOngoingCallVideoCapturerSwizzled = NO;

static void image_added(const struct mach_header *mh, intptr_t vmaddr_slide) {
    if (gOngoingCallVideoCapturerSwizzled) {
        return;
    }
    
    Class videoCapturerClass = NSClassFromString(@"OngoingCallThreadLocalContextVideoCapturer");
    if (videoCapturerClass) {
        SEL submitSelector = NSSelectorFromString(@"submitSampleBuffer:rotation:completion:");
        Method originalMethod = class_getInstanceMethod(videoCapturerClass, submitSelector);
        if (originalMethod) {
            gOriginalSubmitSampleBuffer = (void (*)(id, SEL, CMSampleBufferRef, NSInteger, id))method_getImplementation(originalMethod);
            
            Method swizzledMethod = class_getInstanceMethod([OngoingCallThreadLocalContextVideoCapturerHook class], @selector(swizzled_submitSampleBuffer:rotation:completion:));
            class_replaceMethod(videoCapturerClass,
                                submitSelector,
                                method_getImplementation(swizzledMethod),
                                method_getTypeEncoding(swizzledMethod));
            gOngoingCallVideoCapturerSwizzled = YES;
            NSLog(@"[TelegramCallTweak] Dynamic Image Load: Hooked OngoingCallThreadLocalContextVideoCapturer successfully!");
        }
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
    
    // Register dyld image callback to dynamically swizzle OngoingCallThreadLocalContextVideoCapturer when its framework is loaded
    _dyld_register_func_for_add_image(image_added);
    
    NSLog(@"[TelegramCallTweak] Dynamic swizzler completed setup!");
}
