#import <Foundation/Foundation.h>
#import <SFBAudioEngine/SFBPCMDecoding.h>

NS_ASSUME_NONNULL_BEGIN

/// Presents the shared FFmpeg bridge as an SFBAudioEngine PCM decoder, so the
/// tvOS player can play what SFBAudioEngine has no decoder for (WMA, DTS,
/// TrueHD, ATRAC, TAK ...) on the same AudioPlayer graph, with the same
/// pause, seek, progress and spectrum tap as every other local file.
///
/// SFBAudioEngine calls every method after `-initWithURL:error:` on its own
/// decoding thread, one call at a time.
@interface TVFFmpegPCMDecoder : NSObject <SFBPCMDecoding>

/// Opens `url` (a complete local file) and decodes the first frame, so a file
/// FFmpeg cannot play fails here rather than inside the player.
- (nullable instancetype)initWithURL:(NSURL *)url
                               error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
