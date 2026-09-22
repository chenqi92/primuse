#import "TVFFmpegPCMDecoder.h"
#import "../../Primuse/Services/Audio/FFmpegDecoderBridge.h"

#include <math.h>
#include <string.h>

static NSString *const TVFFmpegPCMDecoderErrorDomain = @"com.welape.yuanyin.tv-ffmpeg-decoder";

typedef NS_ENUM(NSInteger, TVFFmpegPCMDecoderErrorCode) {
    TVFFmpegPCMDecoderErrorNoAudio = 1,
    TVFFmpegPCMDecoderErrorNotOpen = 2,
    TVFFmpegPCMDecoderErrorUnsupportedBuffer = 3,
    TVFFmpegPCMDecoderErrorConversion = 4,
};

static NSError *TVFFmpegPCMDecoderMakeError(TVFFmpegPCMDecoderErrorCode code, NSString *message) {
    return [NSError errorWithDomain:TVFFmpegPCMDecoderErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// The bridge always emits deinterleaved float PCM. Compare only what the
/// copy loop depends on; AVAudioFormat equality also weighs channel-layout
/// objects that SFBAudioEngine's converter may hand back rebuilt.
static BOOL TVFFmpegPCMFormatsMatch(AVAudioFormat *lhs, AVAudioFormat *rhs) {
    return lhs.commonFormat == AVAudioPCMFormatFloat32
        && rhs.commonFormat == AVAudioPCMFormatFloat32
        && !lhs.isInterleaved
        && !rhs.isInterleaved
        && lhs.channelCount == rhs.channelCount
        && lhs.sampleRate == rhs.sampleRate;
}

@implementation TVFFmpegPCMDecoder {
    NSURL *_url;
    SFBInputSource *_inputSource;
    FFmpegDecoderBridge *_bridge;
    AVAudioFormat *_processingFormat;
    BOOL _lossless;
    AVAudioFramePosition _framePosition;
    BOOL _frameLengthResolved;
    AVAudioFramePosition _frameLength;
    // Only created when a later frame changes rate or channel count.
    AVAudioConverter *_converter;
    // Decoded audio not yet handed to the player, starting at `_pendingOffset`.
    AVAudioPCMBuffer *_pending;
    AVAudioFrameCount _pendingOffset;
    BOOL _endOfStream;
    BOOL _hasSeekTarget;
    NSTimeInterval _seekTarget;
    // After a restart from the beginning, the exact number of frames to drop.
    AVAudioFramePosition _framesToDiscard;
}

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _url = [url copy];
    // Not read from: FFmpeg opens the file itself. SFBAudioDecoding requires
    // one, and SFBAudioEngine uses it to describe the decoder.
    _inputSource = [SFBInputSource inputSourceForURL:url flags:0 error:error];
    if (!_inputSource || ![self openReturningError:error]) return nil;
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %p: %@>",
            NSStringFromClass([self class]), self, _url.lastPathComponent];
}

#pragma mark - SFBAudioDecoding

- (SFBInputSource *)inputSource { return _inputSource; }
- (AVAudioFormat *)sourceFormat { return _processingFormat; }
- (AVAudioFormat *)processingFormat { return _processingFormat; }
- (BOOL)decodingIsLossless { return _lossless; }
- (NSDictionary<SFBAudioDecodingPropertiesKey, SFBAudioDecodingPropertiesValue> *)properties { return @{}; }
- (BOOL)isOpen { return _bridge != nil; }
// A demuxer that cannot seek falls back to decoding forward from the start.
- (BOOL)supportsSeeking { return YES; }

- (BOOL)openReturningError:(NSError **)error {
    if (_bridge) return YES;
    FFmpegDecoderBridge *bridge = [[FFmpegDecoderBridge alloc] initWithURL:_url error:error];
    if (!bridge) return NO;
    _bridge = bridge;
    _lossless = bridge.fileInfo.lossless;
    _converter = nil;
    _endOfStream = NO;
    _hasSeekTarget = NO;
    _framesToDiscard = 0;
    _framePosition = 0;
    // The bridge settles its PCM layout per decoded frame, so the first
    // frame, not the container header, defines the processing format.
    if (![self loadPendingReturningError:error]) {
        if (_endOfStream && error) {
            *error = TVFFmpegPCMDecoderMakeError(TVFFmpegPCMDecoderErrorNoAudio,
                                                 @"The file contains no decodable audio");
        }
        _bridge = nil;
        return NO;
    }
    return YES;
}

- (BOOL)closeReturningError:(NSError **)error {
    _bridge = nil;
    _converter = nil;
    _pending = nil;
    _pendingOffset = 0;
    return YES;
}

- (BOOL)decodeIntoBuffer:(AVAudioBuffer *)buffer error:(NSError **)error {
    if (![buffer isKindOfClass:[AVAudioPCMBuffer class]]) {
        if (error) *error = TVFFmpegPCMDecoderMakeError(TVFFmpegPCMDecoderErrorUnsupportedBuffer,
                                                        @"Only PCM buffers are supported");
        return NO;
    }
    AVAudioPCMBuffer *pcmBuffer = (AVAudioPCMBuffer *)buffer;
    return [self decodeIntoBuffer:pcmBuffer frameLength:pcmBuffer.frameCapacity error:error];
}

#pragma mark - SFBPCMDecoding

- (AVAudioFramePosition)framePosition { return _framePosition; }

// SFBAudioEngine refuses to seek without a length. Raw elementary streams
// (MLP/TrueHD, some DTS) carry no container duration, so those are measured
// once from packet headers, on the decoding thread that first asks.
- (AVAudioFramePosition)frameLength {
    @synchronized (self) {
        if (!_frameLengthResolved) {
            NSTimeInterval duration = _bridge.fileInfo.duration;
            if (!(isfinite(duration) && duration > 0)) {
                duration = [FFmpegDecoderBridge probeURL:_url error:NULL].duration;
            }
            _frameLength = isfinite(duration) && duration > 0
                ? (AVAudioFramePosition)llround(duration * _processingFormat.sampleRate)
                : SFBUnknownFrameLength;
            _frameLengthResolved = YES;
        }
        return _frameLength;
    }
}

- (BOOL)decodeIntoBuffer:(AVAudioPCMBuffer *)buffer
             frameLength:(AVAudioFrameCount)frameLength
                   error:(NSError **)error {
    if (!_bridge) {
        if (error) *error = TVFFmpegPCMDecoderMakeError(TVFFmpegPCMDecoderErrorNotOpen,
                                                        @"The decoder is not open");
        return NO;
    }
    if (!TVFFmpegPCMFormatsMatch(buffer.format, _processingFormat) || !buffer.floatChannelData) {
        if (error) *error = TVFFmpegPCMDecoderMakeError(TVFFmpegPCMDecoderErrorUnsupportedBuffer,
                                                        @"The buffer does not match the processing format");
        return NO;
    }

    // SFBAudioEngine treats a buffer returned short as the end of the
    // stream, so keep decoding until it is full or the file really ends.
    const AVAudioFrameCount wanted = MIN(frameLength, buffer.frameCapacity);
    const AVAudioChannelCount channels = _processingFormat.channelCount;
    float *const *destination = buffer.floatChannelData;
    AVAudioFrameCount written = 0;
    buffer.frameLength = 0;
    while (written < wanted) {
        if (!_pending || _pendingOffset >= _pending.frameLength) {
            if (_endOfStream) break;
            if (![self loadPendingReturningError:error]) {
                if (_endOfStream) break;
                return NO;
            }
        }
        const AVAudioFrameCount count = MIN(wanted - written, _pending.frameLength - _pendingOffset);
        float *const *source = _pending.floatChannelData;
        for (AVAudioChannelCount channel = 0; channel < channels; channel++) {
            memcpy(destination[channel] + written,
                   source[channel] + _pendingOffset,
                   (size_t)count * sizeof(float));
        }
        written += count;
        _pendingOffset += count;
    }
    buffer.frameLength = written;
    _framePosition += written;
    return YES;
}

- (BOOL)seekToFrame:(AVAudioFramePosition)frame error:(NSError **)error {
    if (!_bridge) {
        if (error) *error = TVFFmpegPCMDecoderMakeError(TVFFmpegPCMDecoderErrorNotOpen,
                                                        @"The decoder is not open");
        return NO;
    }
    const AVAudioFramePosition target = MAX(frame, (AVAudioFramePosition)0);
    const NSTimeInterval targetTime = (NSTimeInterval)target / _processingFormat.sampleRate;
    _pending = nil;
    _pendingOffset = 0;
    _endOfStream = NO;
    _framesToDiscard = 0;
    [_converter reset];
    if ([_bridge seekToTime:targetTime error:NULL]) {
        // The demuxer lands on the packet at or before the target; the
        // samples in front of it are trimmed by timestamp as they decode.
        _hasSeekTarget = targetTime > 0;
        _seekTarget = targetTime;
    } else {
        // Some raw streams cannot seek in the demuxer. Start over and count
        // decoded frames up to the target instead.
        FFmpegDecoderBridge *reopened = [[FFmpegDecoderBridge alloc] initWithURL:_url error:error];
        if (!reopened) return NO;
        _bridge = reopened;
        _converter = nil;
        _hasSeekTarget = NO;
        _framesToDiscard = target;
    }
    _framePosition = target;
    return YES;
}

#pragma mark - Decoding

/// Decodes the next non-empty chunk into `_pending`, converted to the
/// processing format and trimmed to a pending seek target. Returns NO at the
/// end of the stream (with `_endOfStream` set and `error` untouched) or on a
/// decoding failure.
- (BOOL)loadPendingReturningError:(NSError **)error {
    _pending = nil;
    _pendingOffset = 0;
    while (YES) {
        FFmpegAudioReadResult *result = [_bridge readNextBufferWithError:error];
        if (!result) return NO;
        AVAudioPCMBuffer *decoded = result.buffer;
        if (!decoded) {
            _endOfStream = YES;
            return NO;
        }
        if (decoded.frameLength == 0) continue;
        if (!_processingFormat) _processingFormat = decoded.format;

        AVAudioPCMBuffer *chunk = decoded;
        if (!TVFFmpegPCMFormatsMatch(decoded.format, _processingFormat)) {
            chunk = [self convertBuffer:decoded error:error];
            if (!chunk) return NO;
            if (chunk.frameLength == 0) continue;
        }

        AVAudioFrameCount offset = 0;
        if (_framesToDiscard > 0) {
            if (_framesToDiscard >= chunk.frameLength) {
                _framesToDiscard -= chunk.frameLength;
                continue;
            }
            offset = (AVAudioFrameCount)_framesToDiscard;
            _framesToDiscard = 0;
        } else if (_hasSeekTarget && result.hasPresentationTime) {
            const double sampleRate = _processingFormat.sampleRate;
            const NSTimeInterval start = result.presentationTime;
            const NSTimeInterval end = start + (NSTimeInterval)chunk.frameLength / sampleRate;
            if (end <= _seekTarget) continue;
            if (start < _seekTarget) {
                const double skip = floor((_seekTarget - start) * sampleRate);
                offset = (AVAudioFrameCount)MIN(skip, (double)(chunk.frameLength - 1));
            }
        }
        // Without timestamps the demuxer seek stands as is, like on iOS.
        _hasSeekTarget = NO;
        _pending = chunk;
        _pendingOffset = offset;
        return YES;
    }
}

- (nullable AVAudioPCMBuffer *)convertBuffer:(AVAudioPCMBuffer *)input error:(NSError **)error {
    if (!_converter || ![_converter.inputFormat isEqual:input.format]) {
        _converter = [[AVAudioConverter alloc] initFromFormat:input.format toFormat:_processingFormat];
        if (!_converter) {
            if (error) *error = TVFFmpegPCMDecoderMakeError(TVFFmpegPCMDecoderErrorConversion,
                                                            @"Unable to convert the decoded audio");
            return nil;
        }
    }
    const double ratio = _processingFormat.sampleRate / input.format.sampleRate;
    const AVAudioFrameCount capacity = (AVAudioFrameCount)ceil(input.frameLength * ratio) + 64;
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_processingFormat
                                                             frameCapacity:capacity];
    if (!output) {
        if (error) *error = TVFFmpegPCMDecoderMakeError(TVFFmpegPCMDecoderErrorConversion,
                                                        @"Unable to allocate converted audio");
        return nil;
    }
    __block BOOL supplied = NO;
    NSError *conversionError = nil;
    AVAudioConverterOutputStatus status = [_converter
        convertToBuffer:output
                  error:&conversionError
     withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount packetCount,
                                         AVAudioConverterInputStatus *outStatus) {
        if (supplied) {
            *outStatus = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }
        supplied = YES;
        *outStatus = AVAudioConverterInputStatus_HaveData;
        return input;
    }];
    if (status == AVAudioConverterOutputStatus_Error) {
        if (error) {
            *error = conversionError ?: TVFFmpegPCMDecoderMakeError(TVFFmpegPCMDecoderErrorConversion,
                                                                    @"Unable to convert the decoded audio");
        }
        return nil;
    }
    return output;
}

@end
