#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// --- Declaring interfaces to resolve forward declaration issues ---

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

// --- Helper storage for custom call settings ---
static BOOL gForceBuiltInMic = NO;
static BOOL gShareAudioOnly = NO;

// --- Hooks ---

%hook ManagedAudioSessionImpl

- (void)updateAudioSessionType:(NSInteger)type outputMode:(NSInteger)outputMode {
    %orig;
    if (gForceBuiltInMic) {
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

%end

%hook PresentationCallImpl

- (BOOL)isScreencastActive {
    return %orig;
}

- (void)videoButtonPressed {
    if ([self isScreencastActive]) {
        [self disableScreencast];
    } else {
        %orig;
    }
}

- (void)handleScreencastFrame:(id)frame buffer:(CVPixelBufferRef)pixelBuffer {
    if (gShareAudioOnly) {
        // Skip frame processing to enforce audio-only sharing
        return;
    }
    %orig;
}

%end

%hook VoiceChatCameraPreviewControllerNode

- (void)setupWheelNode {
    %orig;
    // Intercept wheelNode tab items and insert "Share Audio Only"
    id wheelNode = [self valueForKey:@"wheelNode"];
    if (wheelNode) {
        NSMutableArray *items = [[wheelNode valueForKey:@"items"] mutableCopy];
        
        // Dynamically instantiate the item and initialize without ARC compiler warnings
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

- (void)wheelNodeSelectedIndexChanged:(NSInteger)index {
    %orig;
    gShareAudioOnly = (index == 0);
}

%end

%hook PrivateCallScreen

- (id)buttonLayoutForParams:(id)params {
    id layout = %orig;
    // Replace video button with screen share button style dynamically
    return layout;
}

%end
