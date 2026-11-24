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
/// failure is reported as `NO` for the caller to recover from. On iOS, macOS
/// and tvOS 27 and later the start goes through `-playAndReturnError:`, which
/// reports most of those failures as errors instead of raising.
FOUNDATION_EXPORT BOOL PrimuseStartPlayerNode(AVAudioPlayerNode *node);

/// Connects two nodes and reports whether the connection was made.
///
/// `-[AVAudioEngine connect:to:format:]` raises an Objective-C exception when a
/// node refuses the format — an `AVAudioPlayerNode` wired straight to the
/// output with a source format it cannot render is enough. The exception
/// cannot be caught in Swift, so the connection is attempted here and a failure
/// comes back through `error`. On iOS, macOS and tvOS 27 and later the
/// connection goes through `-connect:to:format:error:`.
FOUNDATION_EXPORT BOOL PrimuseConnectNodes(
    AVAudioEngine *engine,
    AVAudioNode *source,
    AVAudioNode *destination,
    AVAudioFormat * _Nullable format,
    NSError * _Nullable * _Nullable error
);

/// `PrimuseConnectNodes` with explicit buses, for a mixer that takes several inputs.
/// Buses are `NSInteger` so Swift passes its `AVAudioNodeBus` (an `Int` there) as is.
FOUNDATION_EXPORT BOOL PrimuseConnectNodeBuses(
    AVAudioEngine *engine,
    AVAudioNode *source,
    NSInteger sourceBus,
    AVAudioNode *destination,
    NSInteger destinationBus,
    AVAudioFormat * _Nullable format,
    NSError * _Nullable * _Nullable error
);

/// `PrimuseConnectNodes` for one output feeding several inputs.
FOUNDATION_EXPORT BOOL PrimuseConnectNodeToPoints(
    AVAudioEngine *engine,
    AVAudioNode *source,
    NSArray<AVAudioConnectionPoint *> *destinations,
    AVAudioFormat * _Nullable format,
    NSError * _Nullable * _Nullable error
);

/// Installs an audio tap on `node` without letting an AVFAudio Objective-C
/// exception (e.g. detached node, duplicate tap, or invalid format) crash Swift.
FOUNDATION_EXPORT BOOL PrimuseInstallNodeTap(
    AVAudioNode *node,
    NSInteger bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat * _Nullable format,
    AVAudioNodeTapBlock tapBlock,
    NSError * _Nullable * _Nullable error
);

/// Removes an audio tap from `node` without letting an AVFAudio Objective-C
/// exception crash Swift when the engine was already torn down or the node
/// detached (`_AVAE_Check` in `-[AVAudioNode removeTapOnBus:]`).
FOUNDATION_EXPORT BOOL PrimuseRemoveNodeTap(
    AVAudioNode *node,
    NSInteger bus
);

NS_ASSUME_NONNULL_END
