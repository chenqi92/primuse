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

/// Starts the node and reports whether it is playing.
///
/// `-[AVAudioPlayerNode play]` raises an Objective-C exception when the engine
/// is no longer running by the time the node starts — an interruption or route
/// change that lands between the caller's check and this call is enough. The
/// exception cannot be caught in Swift, so the start is attempted here and a
/// failure is reported as `NO` for the caller to recover from.
FOUNDATION_EXPORT BOOL PrimuseStartPlayerNode(AVAudioPlayerNode *node);

NS_ASSUME_NONNULL_END
