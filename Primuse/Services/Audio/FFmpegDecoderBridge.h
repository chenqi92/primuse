#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FFmpegAudioFileInfo : NSObject
@property(nonatomic) NSTimeInterval duration;
@property(nonatomic) double sampleRate;
@property(nonatomic) NSInteger channelCount;
@property(nonatomic) NSInteger bitDepth;
@property(nonatomic) NSInteger bitRateKbps;
@property(nonatomic, copy) NSString *codecName;
@property(nonatomic, copy) NSString *formatName;
@property(nonatomic) BOOL lossless;
@property(nonatomic) BOOL DSD;
@end

@interface FFmpegAudioReadResult : NSObject
@property(nonatomic, nullable) AVAudioPCMBuffer *buffer;
@property(nonatomic) NSTimeInterval presentationTime;
@property(nonatomic) BOOL hasPresentationTime;
@end

/// Objective-C ownership layer over FFmpeg. The bridge exposes only Foundation
/// and AVFoundation values to Swift, keeping all AVFormat/AVCodec/Swr lifetime
/// rules and pointer arithmetic on one serial decoder task.
@interface FFmpegDecoderBridge : NSObject
+ (BOOL)dataContainsDTSSync:(NSData *)data;
+ (nullable NSNumber *)DTSSyncResultForURL:(NSURL *)url error:(NSError **)error;
+ (nullable NSNumber *)decodeSupportForURL:(NSURL *)url error:(NSError **)error;
+ (nullable FFmpegAudioFileInfo *)probeURL:(NSURL *)url error:(NSError **)error;
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
/// Opens a decoder with a bounded FFmpeg I/O operation timeout. The default
/// initializer uses the playback-safe timeout chosen by the bridge.
- (nullable instancetype)initWithURL:(NSURL *)url
                           ioTimeout:(NSTimeInterval)ioTimeout
                               error:(NSError **)error;
- (nullable FFmpegAudioReadResult *)readNextBufferWithError:(NSError **)error;
- (BOOL)seekToTime:(NSTimeInterval)time error:(NSError **)error;
/// Interrupts an in-flight open/read/seek operation. Safe to call from a
/// different thread when the Swift stream is cancelled.
- (void)cancel;
@property(nonatomic, readonly) FFmpegAudioFileInfo *fileInfo;
@end

NS_ASSUME_NONNULL_END
