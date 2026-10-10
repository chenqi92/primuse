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
