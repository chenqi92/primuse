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
@end

/// Objective-C ownership layer over FFmpeg. The bridge exposes only Foundation
/// and AVFoundation values to Swift, keeping all AVFormat/AVCodec/Swr lifetime
/// rules and pointer arithmetic on one serial decoder task.
@interface FFmpegDecoderBridge : NSObject
+ (BOOL)dataContainsDTSSync:(NSData *)data;
+ (BOOL)canDecodeURL:(NSURL *)url;
+ (nullable FFmpegAudioFileInfo *)probeURL:(NSURL *)url error:(NSError **)error;
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (nullable FFmpegAudioReadResult *)readNextBufferWithError:(NSError **)error;
- (BOOL)seekToTime:(NSTimeInterval)time error:(NSError **)error;
@property(nonatomic, readonly) FFmpegAudioFileInfo *fileInfo;
@end

NS_ASSUME_NONNULL_END
