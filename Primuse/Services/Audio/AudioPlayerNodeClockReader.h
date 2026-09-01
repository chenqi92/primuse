#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads AVAudioPlayerNode's render clock without allowing an Objective-C
/// exception raised by AVFAudio to cross into Swift.
FOUNDATION_EXPORT AVAudioTime * _Nullable PrimusePlayerTimeForNode(
    AVAudioPlayerNode *node
);

/// Reports whether the node has rendered without allowing AVFAudio exceptions
/// to cross into Swift diagnostic code.
FOUNDATION_EXPORT BOOL PrimusePlayerNodeHasRenderTime(AVAudioPlayerNode *node);

NS_ASSUME_NONNULL_END
