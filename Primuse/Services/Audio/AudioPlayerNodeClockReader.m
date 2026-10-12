#import "AudioPlayerNodeClockReader.h"

AVAudioTime * _Nullable PrimusePlayerTimeForNode(AVAudioPlayerNode *node) {
    @try {
        AVAudioTime *nodeTime = node.lastRenderTime;
        if (nodeTime == nil || !nodeTime.isSampleTimeValid) {
            return nil;
        }

        AVAudioTime *playerTime = [node playerTimeForNodeTime:nodeTime];
        if (playerTime == nil || !playerTime.isSampleTimeValid) {
            return nil;
        }
        return playerTime;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

BOOL PrimusePlayerNodeHasRenderTime(AVAudioPlayerNode *node) {
    @try {
        return node.lastRenderTime != nil;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

BOOL PrimuseStartPlayerNode(AVAudioPlayerNode *node) {
    @try {
#ifdef __IPHONE_27_0  // only the 27 SDKs declare -playAndReturnError:
        if (@available(iOS 27.0, macOS 27.0, tvOS 27.0, *)) {
            // The 27 systems report a stopped engine or a disconnected node as
            // an error. A node that was never attached still raises, so the
            // @try stays. After a failed start `isPlaying` can still read YES;
            // only the return value says whether the node started.
            NSError *error = nil;
            if (![node playAndReturnError:&error]) {
                NSLog(@"⚠️ AVAudioPlayerNode play failed: %@", error);
                return NO;
            }
            return node.isPlaying;
        }
#endif
        [node play];
        return node.isPlaying;
    } @catch (NSException *exception) {
        NSLog(@"⚠️ AVAudioPlayerNode play raised %@: %@", exception.name, exception.reason);
        return NO;
    }
}

BOOL PrimuseConnectNodes(
    AVAudioEngine *engine,
    AVAudioNode *source,
    AVAudioNode *destination,
    AVAudioFormat * _Nullable format,
    NSError * _Nullable * _Nullable error
) {
    @try {
#ifdef __IPHONE_27_0  // only the 27 SDKs declare -connect:to:format:error:
        if (@available(iOS 27.0, macOS 27.0, tvOS 27.0, *)) {
            NSError *connectError = nil;
            if (![engine connect:source to:destination format:format error:&connectError]) {
                NSLog(@"⚠️ AVAudioEngine connect failed: %@", connectError);
                if (error != NULL) {
                    *error = connectError ?: [NSError errorWithDomain:@"PrimuseAudioEngine"
                                                                 code:1
                                                             userInfo:nil];
                }
                return NO;
            }
            return YES;
        }
#endif
        [engine connect:source to:destination format:format];
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"⚠️ AVAudioEngine connect raised %@: %@", exception.name, exception.reason);
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"PrimuseAudioEngine"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: exception.name,
            }];
        }
        return NO;
    }
}
