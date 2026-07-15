#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <vector>
#import <pthread.h>

// --- DYLD Interpose Macro Definition ---
#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static const struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
            __attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

// --- Forward Declarations of Helper Preferences Functions ---
static BOOL getForceBuiltInMicSetting();
static void setForceBuiltInMicSetting(BOOL value);
static BOOL getShareAudioOnlySetting();
static void setShareAudioOnlySetting(BOOL value);
static float getMicVolumeSetting();
static void setMicVolumeSetting(float value);
static float getMediaVolumeSetting();
static void setMediaVolumeSetting(float value);
static void enforceBuiltInMicInput(AVAudioSession *session);

// --- Shared Audio Queue Structure ---
static std::vector<int16_t> gScreenAudioBuffer;
static pthread_mutex_t gAudioMutex = PTHREAD_MUTEX_INITIALIZER;

// --- Instantly Adjustable Volumes (in-memory) ---
static float gMicVolume = 1.0f;
static float gMediaVolume = 1.0f;

// --- File-Based Shared Preferences Manager ---

static NSString *getSharedPrefsFilePath() {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    
    NSString *baseBundleId = bundleId;
    NSArray *parts = [bundleId componentsSeparatedByString:@"."];
    if (parts.count > 3) {
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

static NSDictionary *readPrefsDict() {
    NSString *path = getSharedPrefsFilePath();
    return [NSDictionary dictionaryWithContentsOfFile:path] ?: [NSDictionary dictionary];
}

static BOOL readTweakSetting(NSString *key, BOOL defaultValue) {
    @try {
        NSDictionary *dict = readPrefsDict();
        if ([dict objectForKey:key] == nil) {
            return defaultValue;
        }
        return [[dict objectForKey:key] boolValue];
    } @catch (NSException *exception) {
        return defaultValue;
    }
}

static float readTweakFloatSetting(NSString *key, float defaultValue) {
    @try {
        NSDictionary *dict = readPrefsDict();
        if ([dict objectForKey:key] == nil) {
            return defaultValue;
        }
        return [[dict objectForKey:key] floatValue];
    } @catch (NSException *exception) {
        return defaultValue;
    }
}

static void writeTweakSetting(NSString *key, id value) {
    @try {
        NSString *path = getSharedPrefsFilePath();
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:path];
        if (!dict) {
            dict = [NSMutableDictionary dictionary];
        }
        [dict setObject:value forKey:key];
        [dict writeToFile:path atomically:YES];
    } @catch (NSException *exception) {
        NSLog(@"[TelegramCallTweak] Exception saving setting: %@", exception.reason);
    }
}

static BOOL getForceBuiltInMicSetting() {
    return readTweakSetting(@"tweak_forceBuiltInMic", YES);
}

static void setForceBuiltInMicSetting(BOOL value) {
    writeTweakSetting(@"tweak_forceBuiltInMic", @(value));
}

static BOOL getShareAudioOnlySetting() {
    return readTweakSetting(@"tweak_shareAudioOnly", YES);
}

static void setShareAudioOnlySetting(BOOL value) {
    writeTweakSetting(@"tweak_shareAudioOnly", @(value));
}

static float getMediaVolumeSetting() {
    return readTweakFloatSetting(@"tweak_mediaVolume", 1.0f);
}

static void setMediaVolumeSetting(float value) {
    writeTweakSetting(@"tweak_mediaVolume", @(value));
}

static float getMicVolumeSetting() {
    return readTweakFloatSetting(@"tweak_micVolume", 1.0f);
}

static void setMicVolumeSetting(float value) {
    writeTweakSetting(@"tweak_micVolume", @(value));
}

// --- Helper input routing enforcer ---

static void enforceBuiltInMicInput(AVAudioSession *session) {
    if (!getForceBuiltInMicSetting()) {
        return;
    }
    
    AVAudioSessionRouteDescription *currentRoute = session.currentRoute;
    if (currentRoute.inputs.count == 0) {
        return;
    }
    
    BOOL hasExternalAccessoryOutput = NO;
    for (AVAudioSessionPortDescription *desc in currentRoute.outputs) {
        NSString *portType = desc.portType;
        if (![portType isEqualToString:AVAudioSessionPortBuiltInReceiver] &&
            ![portType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
            hasExternalAccessoryOutput = YES;
            break;
        }
    }
    
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
    
    if (isBluetoothConnected && !hasExternalAccessoryOutput) {
        NSError *categoryError = nil;
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                        mode:AVAudioSessionModeVideoChat
                     options:AVAudioSessionCategoryOptionAllowBluetoothA2DP
                       error:&categoryError];
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
            [session setPreferredInput:builtInMic error:&error];
        }
    }
}

// --- Hooking AVAudioSession Configuration Methods ---

@interface AVAudioSession (TweakCategoryHook)
@end

@implementation AVAudioSession (TweakCategoryHook)

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

// --- Helper pixel buffer clearing routine (with fast memset_pattern4 and Alpha Opaque support) ---

static void clearPixelBufferToBlack(CVPixelBufferRef pixelBuffer) {
    if (!pixelBuffer) {
        return;
    }
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    size_t planeCount = CVPixelBufferGetPlaneCount(pixelBuffer);
    if (planeCount > 0) {
        void *yDest = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
        size_t yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
        size_t yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
        if (yDest) {
            memset(yDest, 0, yBytesPerRow * yHeight);
        }
        
        if (planeCount > 1) {
            void *uvDest = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
            size_t uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);
            size_t uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
            if (uvDest) {
                memset(uvDest, 128, uvBytesPerRow * uvHeight);
            }
        }
    } else {
        void *dest = CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t height = CVPixelBufferGetHeight(pixelBuffer);
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
        
        if (dest) {
            uint32_t blackPattern = 0xFF000000;
            memset_pattern4(dest, &blackPattern, bytesPerRow * height);
        }
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

// --- OngoingCallThreadLocalContextVideoCapturer Frame Blocker Hook ---

@interface OngoingCallThreadLocalContextVideoCapturerHook : NSObject
@end

@implementation OngoingCallThreadLocalContextVideoCapturerHook

static void (*gOriginalSubmitSampleBuffer)(id, SEL, CMSampleBufferRef, NSInteger, id) = NULL;

- (void)swizzled_submitSampleBuffer:(CMSampleBufferRef)sampleBuffer rotation:(NSInteger)rotation completion:(id)completion {
    if (getShareAudioOnlySetting() && sampleBuffer) {
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (format) {
            CMMediaType mediaType = CMFormatDescriptionGetMediaType(format);
            if (mediaType == kCMMediaType_Video) {
                CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                if (pixelBuffer) {
                    clearPixelBufferToBlack(pixelBuffer);
                }
            }
        }
    }
    
    if (gOriginalSubmitSampleBuffer) {
        gOriginalSubmitSampleBuffer(self, @selector(submitSampleBuffer:rotation:completion:), sampleBuffer, rotation, completion);
    }
}
@end

// --- AudioUnitRender Interpose Hook for System Audio Mixing ---

static void mixScreenAudioIntoBufferList(AudioBufferList *ioData, UInt32 inNumberFrames) {
    pthread_mutex_lock(&gAudioMutex);
    if (gScreenAudioBuffer.empty()) {
        pthread_mutex_unlock(&gAudioMutex);
        return;
    }
    
    size_t samplesToTake = inNumberFrames;
    if (gScreenAudioBuffer.size() < samplesToTake) {
        samplesToTake = gScreenAudioBuffer.size();
    }
    
    float currentMicVolume = gMicVolume;
    float currentMediaVolume = gMediaVolume;
    
    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        AudioBuffer *audioBuffer = &ioData->mBuffers[b];
        int16_t *dest = (int16_t *)audioBuffer->mData;
        if (!dest) continue;
        
        UInt32 channels = audioBuffer->mNumberChannels;
        if (channels == 0) channels = 1;
        
        for (size_t i = 0; i < samplesToTake; i++) {
            float srcSample = (float)gScreenAudioBuffer[i] * currentMediaVolume;
            
            for (UInt32 c = 0; c < channels; c++) {
                float micSample = (float)dest[i * channels + c] * currentMicVolume;
                float mixedVal = micSample + srcSample;
                
                if (mixedVal > 32767.0f) mixedVal = 32767.0f;
                if (mixedVal < -32768.0f) mixedVal = -32768.0f;
                dest[i * channels + c] = (int16_t)mixedVal;
            }
        }
    }
    
    gScreenAudioBuffer.erase(gScreenAudioBuffer.begin(), gScreenAudioBuffer.begin() + samplesToTake);
    pthread_mutex_unlock(&gAudioMutex);
}

static OSStatus swizzled_AudioUnitRender(AudioUnit inUnit,
                                         AudioUnitRenderActionFlags *ioActionFlags,
                                         const AudioTimeStamp *inTimeStamp,
                                         UInt32 inBusNumber,
                                         UInt32 inNumberFrames,
                                         AudioBufferList *ioData) {
    OSStatus status = AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    if (status == noErr && inBusNumber == 1 && ioData != NULL) {
        mixScreenAudioIntoBufferList(ioData, inNumberFrames);
    }
    return status;
}

DYLD_INTERPOSE(swizzled_AudioUnitRender, AudioUnitRender)

// --- Hooking OngoingCallThreadLocalContextWebrtc addExternalAudioData: ---

@interface OngoingCallThreadLocalContextWebrtcHook : NSObject
@end

@implementation OngoingCallThreadLocalContextWebrtcHook

static void (*gOriginalAddExternalAudioData)(id, SEL, NSData *) = NULL;

- (void)swizzled_addExternalAudioData:(NSData *)data {
    if (gOriginalAddExternalAudioData) {
         gOriginalAddExternalAudioData(self, @selector(addExternalAudioData:), data);
    }
    
    if (data && data.length > 0) {
        pthread_mutex_lock(&gAudioMutex);
        const int16_t *samples = (const int16_t *)data.bytes;
        size_t count = data.length / sizeof(int16_t);
        gScreenAudioBuffer.insert(gScreenAudioBuffer.end(), samples, samples + count);
        
        size_t maxSamples = 7200;
        if (gScreenAudioBuffer.size() > maxSamples) {
             gScreenAudioBuffer.erase(gScreenAudioBuffer.begin(), gScreenAudioBuffer.begin() + (gScreenAudioBuffer.size() - maxSamples));
        }
        pthread_mutex_unlock(&gAudioMutex);
    }
}
@end

@interface UIViewController (TweakSettingsHook)
- (void)openCallTweakSettingsModally;
@end

// --- Grouped Settings View Controller (inheriting safely from standard UIViewController) ---
@interface TweakSettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISwitch *forceMicSwitch;
@property (nonatomic, strong) UISwitch *audioOnlySwitch;
@property (nonatomic, strong) UISlider *micSlider;
@property (nonatomic, strong) UISlider *mediaSlider;
@property (nonatomic, strong) UILabel *micLabel;
@property (nonatomic, strong) UILabel *mediaLabel;
@end

@implementation TweakSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Call Tweak Settings";
    
    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = [UIColor systemBackgroundColor];
        self.navigationController.navigationBar.barTintColor = [UIColor systemBackgroundColor];
    } else {
        self.view.backgroundColor = [UIColor whiteColor];
    }
    
    UIBarButtonItem *closeBtn = [[UIBarButtonItem alloc] initWithTitle:@"Done"
                                                                 style:UIBarButtonItemStyleDone
                                                                target:self
                                                                action:@selector(dismissSelf)];
    self.navigationItem.rightBarButtonItem = closeBtn;
    
    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    
    // GitHub credit footer
    UIView *footerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 60)];
    UIButton *githubBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    githubBtn.frame = CGRectMake(0, 12, self.view.bounds.size.width, 36);
    [githubBtn setTitle:@"🐙  @oceanondawave" forState:UIControlStateNormal];
    githubBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    if (@available(iOS 13.0, *)) {
        [githubBtn setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    } else {
        [githubBtn setTitleColor:[UIColor grayColor] forState:UIControlStateNormal];
    }
    [githubBtn addTarget:self action:@selector(openGitHub) forControlEvents:UIControlEventTouchUpInside];
    [footerView addSubview:githubBtn];
    _tableView.tableFooterView = footerView;
    
    [self.view addSubview:_tableView];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)openGitHub {
    NSURL *url = [NSURL URLWithString:@"https://github.com/oceanondawave"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 2) {
        return 1;
    }
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        return @"Preferences";
    } else if (section == 1) {
        return @"Volume Levels";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Force Built-in Mic";
            _forceMicSwitch = [[UISwitch alloc] init];
            _forceMicSwitch.on = getForceBuiltInMicSetting();
            [_forceMicSwitch addTarget:self action:@selector(forceMicToggled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = _forceMicSwitch;
        } else {
            cell.textLabel.text = @"Share Audio Only";
            _audioOnlySwitch = [[UISwitch alloc] init];
            _audioOnlySwitch.on = getShareAudioOnlySetting();
            [_audioOnlySwitch addTarget:self action:@selector(audioOnlyToggled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = _audioOnlySwitch;
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            _micLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 5, 200, 18)];
            _micLabel.font = [UIFont systemFontOfSize:11];
            _micLabel.textColor = [UIColor grayColor];
            _micLabel.text = [NSString stringWithFormat:@"Microphone Voice Volume (%.0f%%)", gMicVolume * 100];
            [cell.contentView addSubview:_micLabel];
            
            _micSlider = [[UISlider alloc] initWithFrame:CGRectMake(15, 22, self.view.frame.size.width - 30, 20)];
            _micSlider.minimumValue = 0.0f;
            _micSlider.maximumValue = 2.0f;
            _micSlider.value = gMicVolume;
            [_micSlider addTarget:self action:@selector(micSliderChanged:) forControlEvents:UIControlEventValueChanged];
            [cell.contentView addSubview:_micSlider];
        } else {
            _mediaLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 5, 200, 18)];
            _mediaLabel.font = [UIFont systemFontOfSize:11];
            _mediaLabel.textColor = [UIColor grayColor];
            _mediaLabel.text = [NSString stringWithFormat:@"Screen Media Volume (%.0f%%)", gMediaVolume * 100];
            [cell.contentView addSubview:_mediaLabel];
            
            _mediaSlider = [[UISlider alloc] initWithFrame:CGRectMake(15, 22, self.view.frame.size.width - 30, 20)];
            _mediaSlider.minimumValue = 0.0f;
            _mediaSlider.maximumValue = 2.0f;
            _mediaSlider.value = gMediaVolume;
            [_mediaSlider addTarget:self action:@selector(mediaSliderChanged:) forControlEvents:UIControlEventValueChanged];
            [cell.contentView addSubview:_mediaSlider];
        }
    } else {
        cell.textLabel.text = @"Reset Volumes to 100%";
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 2) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        
        gMicVolume = 1.0f;
        gMediaVolume = 1.0f;
        setMicVolumeSetting(1.0f);
        setMediaVolumeSetting(1.0f);
        
        _micLabel.text = @"Microphone Voice Volume (100%)";
        _mediaLabel.text = @"Screen Media Volume (100%)";
        [_micSlider setValue:1.0f animated:YES];
        [_mediaSlider setValue:1.0f animated:YES];
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        return 48.0f;
    }
    return 44.0f;
}

- (void)forceMicToggled:(UISwitch *)sender {
    setForceBuiltInMicSetting(sender.on);
    enforceBuiltInMicInput([AVAudioSession sharedInstance]);
}

- (void)audioOnlyToggled:(UISwitch *)sender {
    setShareAudioOnlySetting(sender.on);
}

- (void)micSliderChanged:(UISlider *)sender {
    gMicVolume = sender.value;
    _micLabel.text = [NSString stringWithFormat:@"Microphone Voice Volume (%.0f%%)", gMicVolume * 100];
    setMicVolumeSetting(gMicVolume);
}

- (void)mediaSliderChanged:(UISlider *)sender {
    gMediaVolume = sender.value;
    _mediaLabel.text = [NSString stringWithFormat:@"Screen Media Volume (%.0f%%)", gMediaVolume * 100];
    setMediaVolumeSetting(gMediaVolume);
}

@end

// --- UIViewController Hook to safely display a floating responsive button on the top-right just below Edit ---

@implementation UIViewController (TweakSettingsHook)

- (void)openCallTweakSettingsModally {
    TweakSettingsViewController *settingsVC = [[TweakSettingsViewController alloc] init];
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:settingsVC];
    
    if (@available(iOS 13.0, *)) {
        navController.modalPresentationStyle = UIModalPresentationPageSheet; // Bottom-sliding card style
    } else {
        navController.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    
    [self presentViewController:navController animated:YES completion:nil];
}

static void (*gOriginalViewDidLayoutSubviews)(UIViewController *, SEL) = NULL;

- (void)swizzled_viewDidLayoutSubviews {
    if (gOriginalViewDidLayoutSubviews) {
        gOriginalViewDidLayoutSubviews(self, @selector(viewDidLayoutSubviews));
    }
    
    NSString *className = NSStringFromClass([self class]);
    
    // DEBUG: log every unique class to find the real settings controller name
    static NSMutableSet *loggedClasses = nil;
    if (!loggedClasses) loggedClasses = [NSMutableSet new];
    if (![loggedClasses containsObject:className]) {
        [loggedClasses addObject:className];
        NSLog(@"[TelegramCallTweak] viewDidLayoutSubviews class: %@", className);
    }
    
    // Inject EXCLUSIVELY on PeerInfoScreenImpl
    if ([className rangeOfString:@"PeerInfoScreenImpl" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        
        // Only hide if pushed onto a navigation stack (i.e. Edit Profile or other sub-pages)
        // Note: Swiftgram uses a custom TabBarControllerImpl, NOT UITabBarController,
        // so self.tabBarController is always nil here — do NOT use isModal check!
        BOOL hasBackButton = (self.navigationController && self.navigationController.viewControllers.count > 1);
        
        if (hasBackButton) {
            UIButton *existingBtn = [self.view viewWithTag:98432];
            if (existingBtn) {
                existingBtn.hidden = YES;
            }
            return;
        }
        
        CGFloat navBarBottom = 0;
        if (self.navigationController && !self.navigationController.navigationBarHidden) {
            navBarBottom = self.navigationController.navigationBar.frame.origin.y + self.navigationController.navigationBar.frame.size.height;
        }
        if (navBarBottom == 0) {
            navBarBottom = ([UIScreen mainScreen].bounds.size.height >= 812.0f) ? 103.0f : 64.0f;
        }
        
        CGFloat btnWidth = 85.0f;
        CGFloat btnHeight = 32.0f;
        CGFloat rightMargin = 16.0f;
        CGFloat topSpacing = 36.0f; // Beautiful spacing gap with comfortable breathing room below Edit button line
        
        CGFloat btnX = self.view.frame.size.width - btnWidth - rightMargin;
        CGFloat btnY = navBarBottom + topSpacing;
        
        UIButton *existingBtn = [self.view viewWithTag:98432];
        if (existingBtn) {
            existingBtn.frame = CGRectMake(btnX, btnY, btnWidth, btnHeight);
            existingBtn.hidden = NO;
            existingBtn.alpha = 1.0f;
            [self.view bringSubviewToFront:existingBtn];
            return;
        }
        
        // Create a gorgeous floating pill button that matches modern iOS layout guidelines
        UIButton *floatingButton = [UIButton buttonWithType:UIButtonTypeSystem];
        floatingButton.tag = 98432;
        floatingButton.frame = CGRectMake(btnX, btnY, btnWidth, btnHeight);
        
        // Setup title & icon
        [floatingButton setTitle:@"📞 Tweak" forState:UIControlStateNormal];
        floatingButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        
        // Rounded pill shape
        floatingButton.layer.cornerRadius = btnHeight / 2.0f;
        
        // Premium background styling
        if (@available(iOS 13.0, *)) {
            floatingButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
            [floatingButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
            
            // Add soft native cell border/shadow
            floatingButton.layer.borderWidth = 0.5f;
            floatingButton.layer.borderColor = [UIColor separatorColor].CGColor;
        } else {
            floatingButton.backgroundColor = [UIColor whiteColor];
            [floatingButton setTitleColor:[UIColor blueColor] forState:UIControlStateNormal];
            
            floatingButton.layer.borderWidth = 0.5f;
            floatingButton.layer.borderColor = [UIColor lightGrayColor].CGColor;
        }
        
        [floatingButton addTarget:self action:@selector(openCallTweakSettingsModally) forControlEvents:UIControlEventTouchUpInside];
        
        [self.view addSubview:floatingButton];
        [self.view bringSubviewToFront:floatingButton];
    }
}

@end

// --- Dynamic Swizzling Helper ---
static void swizzle(Class clazz, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(clazz, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(clazz, swizzledSelector);
    
    if (!originalMethod || !swizzledMethod) {
        return;
    }
    
    BOOL didAddMethod = class_addMethod(clazz,
                                        originalSelector,
                                        method_getImplementation(swizzledMethod),
                                        method_getTypeEncoding(swizzledMethod));
    
    if (didAddMethod) {
        class_replaceMethod(clazz,
                            swizzledSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

// --- Dynamic Dyld Image Loader Hook ---
static BOOL gOngoingCallVideoCapturerSwizzled = NO;
static BOOL gOngoingCallWebrtcSwizzled = NO;

static void image_added(const struct mach_header *mh, intptr_t slide) {
    if (!gOngoingCallVideoCapturerSwizzled) {
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
    
    if (!gOngoingCallWebrtcSwizzled) {
        Class ongoingCallWebrtcClass = NSClassFromString(@"OngoingCallThreadLocalContextWebrtc");
        if (ongoingCallWebrtcClass) {
            SEL addAudioSelector = NSSelectorFromString(@"addExternalAudioData:");
            Method originalMethod = class_getInstanceMethod(ongoingCallWebrtcClass, addAudioSelector);
            if (originalMethod) {
                gOriginalAddExternalAudioData = (void (*)(id, SEL, NSData *))method_getImplementation(originalMethod);
                
                Method swizzledMethod = class_getInstanceMethod([OngoingCallThreadLocalContextWebrtcHook class], @selector(swizzled_addExternalAudioData:));
                class_replaceMethod(ongoingCallWebrtcClass,
                                    addAudioSelector,
                                    method_getImplementation(swizzledMethod),
                                    method_getTypeEncoding(swizzledMethod));
                gOngoingCallWebrtcSwizzled = YES;
                NSLog(@"[TelegramCallTweak] Dynamic Image Load: Hooked OngoingCallThreadLocalContextWebrtc successfully!");
            }
        }
    }
}

// --- Tweak Entry Point ---
__attribute__((constructor)) static void initTweak() {
    NSLog(@"[TelegramCallTweak] Dynamic swizzler initializing...");
    
    gAudioObserver = [[TweakAudioObserver alloc] init];
    
    // Hook UIViewController viewDidLayoutSubviews to build floating top-right button once layout is ready
    Class uiViewControllerClass = NSClassFromString(@"UIViewController");
    if (uiViewControllerClass) {
        SEL viewDidLayoutSubviewsSel = @selector(viewDidLayoutSubviews);
        Method originalMethod = class_getInstanceMethod(uiViewControllerClass, viewDidLayoutSubviewsSel);
        if (originalMethod) {
            gOriginalViewDidLayoutSubviews = (void (*)(UIViewController *, SEL))method_getImplementation(originalMethod);
            
            Method swizzledMethod = class_getInstanceMethod([UIViewController class], @selector(swizzled_viewDidLayoutSubviews));
            class_replaceMethod(uiViewControllerClass,
                                viewDidLayoutSubviewsSel,
                                method_getImplementation(swizzledMethod),
                                method_getTypeEncoding(swizzledMethod));
            
            NSLog(@"[TelegramCallTweak] Successfully swizzled UIViewController viewDidLayoutSubviews for settings cell injection.");
        }
    }
    
    Class avAudioSessionClass = NSClassFromString(@"AVAudioSession");
    if (avAudioSessionClass) {
        swizzle(avAudioSessionClass, @selector(categoryOptions), @selector(swizzled_categoryOptions));
        NSLog(@"[TelegramCallTweak] Hooked AVAudioSession category options successfully.");
    }
    
    // Load volume preferences into memory
    gMicVolume = getMicVolumeSetting();
    gMediaVolume = getMediaVolumeSetting();
    
    _dyld_register_func_for_add_image(image_added);
    
    NSLog(@"[TelegramCallTweak] Dynamic swizzler completed setup!");
}
