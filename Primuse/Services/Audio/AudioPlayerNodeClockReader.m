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
