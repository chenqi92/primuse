#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FFmpegMusicVideoStreamKind) {
    FFmpegMusicVideoStreamKindVideo = 0,
    FFmpegMusicVideoStreamKindAudio = 1,
};

/// One input stream as the copy-or-transcode decision sees it. The rules
/// themselves live in PrimuseKit (`MusicVideoCompatibilityPolicy`) so they
/// can be tested without FFmpeg.
@interface FFmpegMusicVideoStream : NSObject
@property(nonatomic, readonly) FFmpegMusicVideoStreamKind kind;
/// FFmpeg codec descriptor name: `h264`, `hevc`, `aac`, `mpeg2video`...
@property(nonatomic, readonly, copy) NSString *codecName;
/// `AV_PROFILE_*`; -99 when the container does not say.
@property(nonatomic, readonly) NSInteger profile;
/// Bits per component; 0 when unknown.
@property(nonatomic, readonly) NSInteger bitDepth;
/// 4:2:0 chroma, or no pixel format declared.
@property(nonatomic, readonly) BOOL chroma420;
@end

typedef BOOL (^FFmpegMusicVideoCopyDecision)(FFmpegMusicVideoStream *stream);

/// Rewrites a music video AVPlayer cannot open into an MP4 it can. The best
/// video and audio streams are kept; every other stream (subtitles, extra
/// audio, attached pictures) is dropped. A stream is copied when
/// `shouldCopyStream` allows it and re-encoded otherwise: video to H.264 by
/// VideoToolbox, audio to AAC. A video stream nothing here can decode is
/// dropped so the audio still plays.
@interface FFmpegMusicVideoConverter : NSObject
- (instancetype)initWithInputURL:(NSURL *)inputURL outputURL:(NSURL *)outputURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, copy, nullable) FFmpegMusicVideoCopyDecision shouldCopyStream;
/// What the last run did with each stream, for the log.
@property(nonatomic, readonly, copy) NSString *summary;
/// Whether the last run copied any stream unchanged.
@property(nonatomic, readonly) BOOL copiedAnyStream;

/// Blocking. `forceTranscode` ignores `shouldCopyStream`; it is the retry
/// for a copied stream the muxer or AVPlayer rejected. On failure the output
/// file is removed.
- (BOOL)convertForcingTranscode:(BOOL)forceTranscode
                       progress:(nullable void (^)(double fraction))progress
                          error:(NSError **)error
    NS_SWIFT_NAME(convert(forcingTranscode:progress:));

/// Thread-safe. Stops a running conversion at the next packet or I/O wait.
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
