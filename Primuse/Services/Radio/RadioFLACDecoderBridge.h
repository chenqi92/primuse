#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Sequential input used by live streams whose total size is unknown. The
/// callback blocks until it can return audio bytes, EOF, or an error.
typedef NSData * _Nullable (^RadioFLACReadBlock)(
    NSInteger maximumLength,
    BOOL *atEOF,
    NSError **error
);

@interface RadioFLACAudioReadResult : NSObject
@property(nonatomic, nullable) AVAudioPCMBuffer *buffer;
@end

/// Minimal pull decoder for native and Ogg FLAC live streams. Unlike file
/// decoders, it deliberately accepts a first frame whose sample number is not
/// zero because a listener can join a broadcast at any point.
@interface RadioFLACDecoderBridge : NSObject

- (nullable instancetype)initWithOggContainer:(BOOL)oggContainer
                                     readBlock:(RadioFLACReadBlock)readBlock
                                         error:(NSError **)error;

/// Returns one decoded PCM frame. A result whose buffer is nil represents a
/// clean end-of-stream; nil plus an NSError represents a decode failure.
- (nullable RadioFLACAudioReadResult *)readNextBufferWithError:(NSError **)error;

/// Marks the decoder cancelled. The owner must also unblock the read callback.
- (void)cancel;

@property(nonatomic, readonly) double sampleRate;
@property(nonatomic, readonly) NSInteger channelCount;
@property(nonatomic, readonly) NSInteger bitDepth;

@end

NS_ASSUME_NONNULL_END
