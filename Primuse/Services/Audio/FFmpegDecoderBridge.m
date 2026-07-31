#import "FFmpegDecoderBridge.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
#include <stdatomic.h>
#include <stdint.h>
#include <math.h>
#include <string.h>
#include <time.h>

static NSString *const FFmpegDecoderErrorDomain = @"com.welape.yuanyin.ffmpeg-decoder";
static const NSTimeInterval FFmpegDefaultIOTimeout = 15.0;

typedef struct {
    atomic_bool cancelled;
    atomic_bool timedOut;
    atomic_uint_fast64_t deadlineNanos;
} FFmpegInterruptState;

static uint64_t FFmpegMonotonicNanos(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}

static void FFmpegBeginInterruptibleOperation(FFmpegInterruptState *state,
                                               uint64_t timeoutNanos) {
    atomic_store_explicit(&state->timedOut, false, memory_order_release);
    if (atomic_load_explicit(&state->cancelled, memory_order_acquire)) {
        atomic_store_explicit(&state->deadlineNanos, 0, memory_order_release);
        return;
    }
    uint64_t now = FFmpegMonotonicNanos();
    uint64_t deadline = now > UINT64_MAX - timeoutNanos
        ? UINT64_MAX : now + timeoutNanos;
    atomic_store_explicit(&state->deadlineNanos, deadline, memory_order_release);
}

static int FFmpegInterruptCallback(void *opaque) {
    FFmpegInterruptState *state = opaque;
    if (!state) return 0;
    if (atomic_load_explicit(&state->cancelled, memory_order_acquire)) return 1;
    uint64_t deadline = atomic_load_explicit(&state->deadlineNanos, memory_order_acquire);
    uint64_t now = FFmpegMonotonicNanos();
    if (deadline > 0 && now >= deadline) {
        atomic_store_explicit(&state->timedOut, true, memory_order_release);
        return 1;
    }
    return 0;
}

static NSString *FFmpegErrorMessage(int code) {
    char buffer[AV_ERROR_MAX_STRING_SIZE] = {0};
    if (av_strerror(code, buffer, sizeof(buffer)) < 0) return @"Unknown FFmpeg error";
    NSString *message = [NSString stringWithUTF8String:buffer];
    return message ?: @"Unknown FFmpeg error";
}

static NSError *FFmpegError(int code, NSString *operation) {
    return [NSError errorWithDomain:FFmpegDecoderErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey:
                               [NSString stringWithFormat:@"%@: %@", operation, FFmpegErrorMessage(code)]}];
}

static NSError *FFmpegOperationError(int code,
                                     NSString *operation,
                                     FFmpegInterruptState *state) {
    if (state && atomic_load_explicit(&state->timedOut, memory_order_acquire)) {
        return [NSError errorWithDomain:NSURLErrorDomain
                                   code:NSURLErrorTimedOut
                               userInfo:@{NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat:@"%@ timed out", operation]}];
    }
    return FFmpegError(code, operation);
}

static AVAudioChannelLayout *FFmpegAudioChannelLayout(int channels) {
    AudioChannelLayoutTag tag;
    switch (channels) {
        case 1: tag = kAudioChannelLayoutTag_Mono; break;
        case 2: tag = kAudioChannelLayoutTag_Stereo; break;
        case 3: tag = kAudioChannelLayoutTag_MPEG_3_0_A; break;
        case 4: tag = kAudioChannelLayoutTag_Quadraphonic; break;
        case 5: tag = kAudioChannelLayoutTag_MPEG_5_0_A; break;
        case 6: tag = kAudioChannelLayoutTag_MPEG_5_1_A; break;
        case 7: tag = kAudioChannelLayoutTag_MPEG_6_1_A; break;
        case 8: tag = kAudioChannelLayoutTag_MPEG_7_1_C; break;
        default:
            if (channels <= 0 || channels > UINT16_MAX) return nil;
            tag = kAudioChannelLayoutTag_DiscreteInOrder | (AudioChannelLayoutTag)channels;
            break;
    }
    return [[AVAudioChannelLayout alloc] initWithLayoutTag:tag];
}

static BOOL FFmpegCodecIsDSD(enum AVCodecID codecID) {
    switch (codecID) {
        case AV_CODEC_ID_DSD_LSBF:
        case AV_CODEC_ID_DSD_MSBF:
        case AV_CODEC_ID_DSD_LSBF_PLANAR:
        case AV_CODEC_ID_DSD_MSBF_PLANAR:
        case AV_CODEC_ID_DST:
            return YES;
        default:
            return NO;
    }
}

/// Raw elementary streams such as MLP/TrueHD often omit both stream and
/// container duration. Their demuxers still expose packet timestamps and
/// durations, so scan packet headers (without decoding PCM) as an authoritative
/// fallback. A separate format context keeps the real decoder positioned at
/// the beginning of the file.
static NSTimeInterval FFmpegPacketDuration(NSURL *url,
                                           const AVInputFormat *forcedInputFormat,
                                           FFmpegInterruptState *interruptState,
                                           uint64_t timeoutNanos,
                                           int *readError) {
    if (readError) *readError = 0;
    AVFormatContext *context = avformat_alloc_context();
    if (!context) {
        if (readError) *readError = AVERROR(ENOMEM);
        return 0;
    }
    context->interrupt_callback.callback = FFmpegInterruptCallback;
    context->interrupt_callback.opaque = interruptState;
    FFmpegBeginInterruptibleOperation(interruptState, timeoutNanos);
    int result = avformat_open_input(&context, url.fileSystemRepresentation,
                                     forcedInputFormat, NULL);
    if (result < 0) {
        if (readError) *readError = result;
        avformat_close_input(&context);
        return 0;
    }
    FFmpegBeginInterruptibleOperation(interruptState, timeoutNanos);
    result = avformat_find_stream_info(context, NULL);
    if (result < 0) {
        if (readError) *readError = result;
        avformat_close_input(&context);
        return 0;
    }

    int streamIndex = av_find_best_stream(context, AVMEDIA_TYPE_AUDIO,
                                          -1, -1, NULL, 0);
    if (streamIndex < 0) {
        if (readError) *readError = streamIndex;
        avformat_close_input(&context);
        return 0;
    }

    AVStream *stream = context->streams[streamIndex];
    AVRational timeBase = stream->time_base;
    AVPacket *packet = av_packet_alloc();
    if (!packet) {
        if (readError) *readError = AVERROR(ENOMEM);
        avformat_close_input(&context);
        return 0;
    }

    int64_t earliestTimestamp = INT64_MAX;
    int64_t latestEndTimestamp = INT64_MIN;
    int64_t accumulatedDuration = 0;
    // This is a metadata probe, not realtime playback. Give the complete scan
    // one total budget so a long stream cannot extend its deadline forever by
    // yielding one packet just before every timeout.
    FFmpegBeginInterruptibleOperation(interruptState, timeoutNanos);
    while ((result = av_read_frame(context, packet)) >= 0) {
        if (packet->stream_index == streamIndex) {
            int64_t timestamp = packet->pts != AV_NOPTS_VALUE
                ? packet->pts : packet->dts;
            if (timestamp != AV_NOPTS_VALUE) {
                earliestTimestamp = MIN(earliestTimestamp, timestamp);
                int64_t endTimestamp = timestamp;
                if (packet->duration > 0 &&
                    timestamp <= INT64_MAX - packet->duration) {
                    endTimestamp += packet->duration;
                }
                latestEndTimestamp = MAX(latestEndTimestamp, endTimestamp);
            }
            if (packet->duration > 0 &&
                accumulatedDuration <= INT64_MAX - packet->duration) {
                accumulatedDuration += packet->duration;
            }
        }
        av_packet_unref(packet);
    }

    av_packet_free(&packet);
    avformat_close_input(&context);

    BOOL interrupted = atomic_load_explicit(&interruptState->timedOut, memory_order_acquire)
        || atomic_load_explicit(&interruptState->cancelled, memory_order_acquire);
    if (interrupted || (result < 0 && result != AVERROR_EOF)) {
        if (readError) *readError = result < 0 ? result : AVERROR_EXIT;
        return 0;
    }

    int64_t durationTicks = 0;
    if (earliestTimestamp != INT64_MAX && latestEndTimestamp != INT64_MIN &&
        latestEndTimestamp > earliestTimestamp) {
        durationTicks = latestEndTimestamp - earliestTimestamp;
    } else if (accumulatedDuration > 0) {
        durationTicks = accumulatedDuration;
    }
    NSTimeInterval duration = durationTicks * av_q2d(timeBase);
    return isfinite(duration) && duration > 0 ? duration : 0;
}

@implementation FFmpegAudioFileInfo
@end

@implementation FFmpegAudioReadResult
@end

@interface FFmpegDecoderBridge ()
+ (BOOL)URLContainsDTSSync:(NSURL *)url
            interruptState:(FFmpegInterruptState *)interruptState
               timeoutNanos:(uint64_t)timeoutNanos
                       error:(NSError **)error;
- (instancetype)initWithURL:(NSURL *)url
          scanPacketDuration:(BOOL)scanPacketDuration
                   ioTimeout:(NSTimeInterval)ioTimeout
                       error:(NSError **)error;
@end

static uint16_t FFmpegReadLittleEndian16(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t FFmpegReadLittleEndian32(const uint8_t *bytes) {
    return (uint32_t)bytes[0]
        | ((uint32_t)bytes[1] << 8)
        | ((uint32_t)bytes[2] << 16)
        | ((uint32_t)bytes[3] << 24);
}

/// DTS frames repeat the same four-byte sync word at frame boundaries. Requiring
/// two nearby instances of the same byte order avoids treating arbitrary image
/// or PCM bytes as a DTS stream merely because two unrelated variants happen to
/// appear somewhere in a large metadata prefix.
static BOOL FFmpegPayloadContainsDTSSync(const uint8_t *bytes, NSUInteger length) {
    if (!bytes || length < 8) return NO;
    static const uint8_t syncWords[][4] = {
        {0x7f, 0xfe, 0x80, 0x01},
        {0xfe, 0x7f, 0x01, 0x80},
        {0x1f, 0xff, 0xe8, 0x00},
        {0xff, 0x1f, 0x00, 0xe8},
    };
    static const NSUInteger minimumFrameSpacing = 64;
    static const NSUInteger maximumFrameSpacing = 32 * 1024;
    NSUInteger previousOffsets[sizeof(syncWords) / sizeof(syncWords[0])];
    for (NSUInteger index = 0; index < sizeof(previousOffsets) / sizeof(previousOffsets[0]); index++) {
        previousOffsets[index] = NSNotFound;
    }

    for (NSUInteger offset = 0; offset + 4 <= length; offset++) {
        for (NSUInteger word = 0; word < sizeof(syncWords) / sizeof(syncWords[0]); word++) {
            if (memcmp(bytes + offset, syncWords[word], 4) != 0) continue;
            NSUInteger previous = previousOffsets[word];
            if (previous != NSNotFound) {
                NSUInteger distance = offset - previous;
                if (distance >= minimumFrameSpacing && distance <= maximumFrameSpacing) {
                    return YES;
                }
            }
            previousOffsets[word] = offset;
            offset += 3;
            break;
        }
    }
    return NO;
}

/// Returns whether a RIFF/WAVE prefix is a plausible DTS-CD image. DTS-CD is
/// stored as a stereo 16-bit PCM carrier; scanning the whole file prefix used to
/// find false sync words in cover-art/metadata and even classified ordinary
/// multichannel PCM WAV files as DTS. Only the declared audio `data` chunk is
/// inspected now.
static BOOL FFmpegWAVEContainsDTSSync(const uint8_t *bytes, NSUInteger length) {
    if (!bytes || length < 12
        || memcmp(bytes, "RIFF", 4) != 0
        || memcmp(bytes + 8, "WAVE", 4) != 0) {
        return NO;
    }

    BOOL hasFormat = NO;
    uint16_t audioFormat = 0;
    uint16_t channelCount = 0;
    uint32_t sampleRate = 0;
    uint16_t bitDepth = 0;
    NSUInteger cursor = 12;
    while (cursor <= length - 8) {
        const uint8_t *chunk = bytes + cursor;
        uint32_t declaredSize = FFmpegReadLittleEndian32(chunk + 4);
        NSUInteger payloadStart = cursor + 8;
        NSUInteger available = length - payloadStart;
        NSUInteger payloadLength = MIN((NSUInteger)declaredSize, available);

        if (memcmp(chunk, "fmt ", 4) == 0 && payloadLength >= 16) {
            audioFormat = FFmpegReadLittleEndian16(bytes + payloadStart);
            channelCount = FFmpegReadLittleEndian16(bytes + payloadStart + 2);
            sampleRate = FFmpegReadLittleEndian32(bytes + payloadStart + 4);
            bitDepth = FFmpegReadLittleEndian16(bytes + payloadStart + 14);
            hasFormat = YES;
        } else if (memcmp(chunk, "data", 4) == 0) {
            // 0x0008 (WAVE_FORMAT_DTS) and 0x2001 (WAVE_FORMAT_DTS2) are
            // explicit DTS-in-WAVE tags emitted by common muxers. DTS-CD
            // images may instead claim to be ordinary stereo PCM (0x0001)
            // or extensible PCM (0xfffe), so keep the tighter carrier guard
            // for those ambiguous formats.
            BOOL isExplicitDTS = audioFormat == 0x0008 || audioFormat == 0x2001;
            BOOL isPCMCarrier = audioFormat == 1 || audioFormat == 0xfffe;
            BOOL plausiblePCMCarrier = isPCMCarrier
                && channelCount == 2
                && bitDepth == 16;
            BOOL plausibleDTSCD = hasFormat
                && (isExplicitDTS || plausiblePCMCarrier)
                && sampleRate >= 32000
                && sampleRate <= 96000;
            return plausibleDTSCD
                && FFmpegPayloadContainsDTSSync(bytes + payloadStart, payloadLength);
        }

        uint64_t paddedSize = (uint64_t)declaredSize + (declaredSize & 1u);
        uint64_t next = (uint64_t)payloadStart + paddedSize;
        if (next > length || next > NSUIntegerMax) break;
        cursor = (NSUInteger)next;
    }
    return NO;
}

@implementation FFmpegDecoderBridge {
    AVFormatContext *_formatContext;
    AVCodecContext *_codecContext;
    AVPacket *_packet;
    AVFrame *_frame;
    SwrContext *_resampler;
    AVChannelLayout _resamplerInputLayout;
    enum AVSampleFormat _resamplerInputFormat;
    int _resamplerInputRate;
    NSInteger _audioStreamIndex;
    BOOL _inputEnded;
    BOOL _flushSent;
    BOOL _decoderEnded;
    BOOL _packetPending;
    FFmpegAudioFileInfo *_fileInfo;
    FFmpegInterruptState _interruptState;
    uint64_t _ioTimeoutNanos;
}

+ (BOOL)dataContainsDTSSync:(NSData *)data {
    if (data.length < 8) return NO;
    const uint8_t *bytes = data.bytes;
    if (data.length >= 12
        && memcmp(bytes, "RIFF", 4) == 0
        && memcmp(bytes + 8, "WAVE", 4) == 0) {
        return FFmpegWAVEContainsDTSSync(bytes, data.length);
    }
    // Preserve support for raw/mislabeled DTS payloads without a WAVE header.
    return FFmpegPayloadContainsDTSSync(bytes, data.length);
}

+ (NSNumber *)DTSSyncResultForURL:(NSURL *)url error:(NSError **)error {
    FFmpegInterruptState interruptState;
    atomic_init(&interruptState.cancelled, false);
    atomic_init(&interruptState.timedOut, false);
    atomic_init(&interruptState.deadlineNanos, 0);
    uint64_t timeoutNanos = (uint64_t)llround(
        FFmpegDefaultIOTimeout * 1000000000.0
    );
    BOOL result = [self URLContainsDTSSync:url
                           interruptState:&interruptState
                              timeoutNanos:timeoutNanos
                                      error:error];
    return error && *error ? nil : @(result);
}

+ (BOOL)URLContainsDTSSync:(NSURL *)url
            interruptState:(FFmpegInterruptState *)interruptState
               timeoutNanos:(uint64_t)timeoutNanos
                       error:(NSError **)error {
    if (!url.isFileURL) return NO;
    AVIOInterruptCB interrupt = {
        .callback = FFmpegInterruptCallback,
        .opaque = interruptState,
    };
    AVIOContext *input = NULL;
    FFmpegBeginInterruptibleOperation(interruptState, timeoutNanos);
    int openResult = avio_open2(
        &input, url.fileSystemRepresentation, AVIO_FLAG_READ, &interrupt, NULL
    );
    if (openResult < 0 || !input) {
        if (error) *error = FFmpegOperationError(
            openResult < 0 ? openResult : AVERROR(EIO),
            @"Opening audio header",
            interruptState
        );
        avio_closep(&input);
        return NO;
    }

    const int prefixLimit = 256 * 1024;
    NSMutableData *prefix = [NSMutableData dataWithLength:(NSUInteger)prefixLimit];
    int totalRead = 0;
    int readResult = 0;
    while (totalRead < prefixLimit) {
        readResult = avio_read_partial(
            input,
            (uint8_t *)prefix.mutableBytes + totalRead,
            prefixLimit - totalRead
        );
        if (readResult <= 0) break;
        totalRead += readResult;
    }
    avio_closep(&input);
    BOOL interrupted = atomic_load_explicit(&interruptState->timedOut, memory_order_acquire)
        || atomic_load_explicit(&interruptState->cancelled, memory_order_acquire);
    if (interrupted || (readResult < 0 && readResult != AVERROR_EOF)) {
        if (error) *error = FFmpegOperationError(
            readResult < 0 ? readResult : AVERROR_EXIT,
            @"Reading audio header",
            interruptState
        );
        return NO;
    }
    prefix.length = (NSUInteger)MAX(0, totalRead);
    return [self dataContainsDTSSync:prefix];
}

+ (NSNumber *)decodeSupportForURL:(NSURL *)url error:(NSError **)error {
    if (!url.isFileURL) return @NO;
    FFmpegDecoderBridge *decoder = [[FFmpegDecoderBridge alloc] initWithURL:url error:error];
    if (!decoder) return nil;
    return @YES;
}

+ (FFmpegAudioFileInfo *)probeURL:(NSURL *)url error:(NSError **)error {
    FFmpegDecoderBridge *decoder = [[FFmpegDecoderBridge alloc]
        initWithURL:url
        scanPacketDuration:YES
        ioTimeout:FFmpegDefaultIOTimeout
        error:error];
    return decoder.fileInfo;
}

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    return [self initWithURL:url ioTimeout:FFmpegDefaultIOTimeout error:error];
}

- (instancetype)initWithURL:(NSURL *)url
                   ioTimeout:(NSTimeInterval)ioTimeout
                       error:(NSError **)error {
    return [self initWithURL:url
          scanPacketDuration:NO
                   ioTimeout:ioTimeout
                       error:error];
}

- (instancetype)initWithURL:(NSURL *)url
          scanPacketDuration:(BOOL)scanPacketDuration
                   ioTimeout:(NSTimeInterval)ioTimeout
                       error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    NSTimeInterval boundedTimeout = isfinite(ioTimeout)
        ? MIN(MAX(ioTimeout, 0.1), 3600.0)
        : FFmpegDefaultIOTimeout;
    _ioTimeoutNanos = (uint64_t)llround(boundedTimeout * 1000000000.0);
    atomic_init(&_interruptState.cancelled, false);
    atomic_init(&_interruptState.timedOut, false);
    atomic_init(&_interruptState.deadlineNanos, 0);
    _audioStreamIndex = -1;
    _resamplerInputFormat = AV_SAMPLE_FMT_NONE;
    av_channel_layout_uninit(&_resamplerInputLayout);

    const AVInputFormat *forcedInputFormat = NULL;
    NSError *headerError = nil;
    BOOL containsDTSSync = NO;
    if ([[url.pathExtension lowercaseString] isEqualToString:@"wav"]) {
        containsDTSSync = [[self class] URLContainsDTSSync:url
                                           interruptState:&_interruptState
                                              timeoutNanos:_ioTimeoutNanos
                                                      error:&headerError];
    }
    if (headerError) {
        if (error) *error = headerError;
        [self closeDecoder];
        return nil;
    }
    if (containsDTSSync) {
        // DTS-CD images are formally PCM WAV files. Force the raw DTS demuxer;
        // its parser scans through the RIFF prefix to the first valid sync word.
        forcedInputFormat = av_find_input_format("dts");
    }
    if (atomic_load_explicit(&_interruptState.timedOut, memory_order_acquire) ||
        atomic_load_explicit(&_interruptState.cancelled, memory_order_acquire)) {
        if (error) *error = FFmpegOperationError(
            AVERROR_EXIT, @"Reading audio header", &_interruptState
        );
        [self closeDecoder];
        return nil;
    }

    _formatContext = avformat_alloc_context();
    if (!_formatContext) {
        if (error) *error = FFmpegError(AVERROR(ENOMEM), @"Unable to allocate input context");
        [self closeDecoder];
        return nil;
    }
    _formatContext->interrupt_callback.callback = FFmpegInterruptCallback;
    _formatContext->interrupt_callback.opaque = &_interruptState;
    FFmpegBeginInterruptibleOperation(&_interruptState, _ioTimeoutNanos);
    int result = avformat_open_input(&_formatContext, url.fileSystemRepresentation,
                                     forcedInputFormat, NULL);
    if (result < 0) {
        if (error) *error = FFmpegOperationError(
            result, @"Opening audio file", &_interruptState
        );
        [self closeDecoder];
        return nil;
    }
    FFmpegBeginInterruptibleOperation(&_interruptState, _ioTimeoutNanos);
    result = avformat_find_stream_info(_formatContext, NULL);
    if (result < 0) {
        if (error) *error = FFmpegOperationError(
            result, @"Reading stream information", &_interruptState
        );
        [self closeDecoder];
        return nil;
    }

    const AVCodec *codec = NULL;
    result = av_find_best_stream(_formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    if (result < 0 || !codec) {
        if (error) *error = FFmpegError(result < 0 ? result : AVERROR_DECODER_NOT_FOUND,
                                        @"No supported audio stream");
        [self closeDecoder];
        return nil;
    }
    _audioStreamIndex = result;
    AVStream *stream = _formatContext->streams[_audioStreamIndex];
    _codecContext = avcodec_alloc_context3(codec);
    if (!_codecContext) {
        if (error) *error = FFmpegError(AVERROR(ENOMEM), @"Unable to allocate decoder");
        [self closeDecoder];
        return nil;
    }
    result = avcodec_parameters_to_context(_codecContext, stream->codecpar);
    if (result < 0) {
        if (error) *error = FFmpegError(result, @"Unable to configure decoder");
        [self closeDecoder];
        return nil;
    }
    _codecContext->request_sample_fmt = AV_SAMPLE_FMT_FLTP;
    result = avcodec_open2(_codecContext, codec, NULL);
    if (result < 0) {
        if (error) *error = FFmpegError(result, @"Unable to start decoder");
        [self closeDecoder];
        return nil;
    }

    _packet = av_packet_alloc();
    _frame = av_frame_alloc();
    if (!_packet || !_frame) {
        if (error) *error = FFmpegError(AVERROR(ENOMEM), @"Unable to allocate decode buffers");
        [self closeDecoder];
        return nil;
    }

    _fileInfo = [[FFmpegAudioFileInfo alloc] init];
    _fileInfo.sampleRate = _codecContext->sample_rate > 0
        ? _codecContext->sample_rate : stream->codecpar->sample_rate;
    _fileInfo.channelCount = _codecContext->ch_layout.nb_channels > 0
        ? _codecContext->ch_layout.nb_channels : stream->codecpar->ch_layout.nb_channels;
    int bitDepth = _codecContext->bits_per_raw_sample;
    if (bitDepth <= 0) bitDepth = _codecContext->bits_per_coded_sample;
    // Several lossless decoders output into a 32-bit sample container even
    // when the source is 24-bit. The codec parameters retain the encoded bit
    // depth, whereas the decoder context may leave it unset.
    if (bitDepth <= 0) bitDepth = stream->codecpar->bits_per_raw_sample;
    if (bitDepth <= 0) bitDepth = stream->codecpar->bits_per_coded_sample;
    if (FFmpegCodecIsDSD(_codecContext->codec_id)) bitDepth = 1;
    _fileInfo.bitDepth = MAX(0, bitDepth);
    int64_t bitRate = _codecContext->bit_rate > 0
        ? _codecContext->bit_rate : stream->codecpar->bit_rate;
    if (bitRate <= 0) bitRate = _formatContext->bit_rate;
    _fileInfo.bitRateKbps = bitRate > 0 ? (NSInteger)(bitRate / 1000) : 0;
    const AVCodecDescriptor *descriptor = avcodec_descriptor_get(_codecContext->codec_id);
    const char *codecName = descriptor ? descriptor->name : codec->name;
    _fileInfo.codecName = codecName ? [NSString stringWithUTF8String:codecName] : @"unknown";
    const char *formatName = _formatContext->iformat ? _formatContext->iformat->name : NULL;
    _fileInfo.formatName = formatName ? [NSString stringWithUTF8String:formatName] : @"unknown";
    _fileInfo.lossless = descriptor && (descriptor->props & AV_CODEC_PROP_LOSSLESS);
    _fileInfo.DSD = FFmpegCodecIsDSD(_codecContext->codec_id);

    if (stream->duration != AV_NOPTS_VALUE && stream->duration > 0) {
        _fileInfo.duration = stream->duration * av_q2d(stream->time_base);
    } else if (_formatContext->duration != AV_NOPTS_VALUE && _formatContext->duration > 0) {
        _fileInfo.duration = (NSTimeInterval)_formatContext->duration / AV_TIME_BASE;
    } else if (_fileInfo.bitRateKbps > 0) {
        NSNumber *fileSize = nil;
        [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
        if (fileSize.longLongValue > 0) {
            _fileInfo.duration = (NSTimeInterval)fileSize.longLongValue * 8.0 /
                ((NSTimeInterval)_fileInfo.bitRateKbps * 1000.0);
        }
    }
    if (scanPacketDuration &&
        (!isfinite(_fileInfo.duration) || _fileInfo.duration <= 0)) {
        int packetDurationError = 0;
        _fileInfo.duration = FFmpegPacketDuration(
            url, forcedInputFormat, &_interruptState, _ioTimeoutNanos,
            &packetDurationError
        );
        if (packetDurationError < 0) {
            if (error) *error = FFmpegOperationError(
                packetDurationError,
                @"Reading packet timeline",
                &_interruptState
            );
            [self closeDecoder];
            return nil;
        }
    }
    return self;
}

- (void)dealloc { [self closeDecoder]; }
- (FFmpegAudioFileInfo *)fileInfo { return _fileInfo; }

- (FFmpegAudioReadResult *)readNextBufferWithError:(NSError **)error {
    if (_decoderEnded) {
        FFmpegAudioReadResult *ended = [[FFmpegAudioReadResult alloc] init];
        return ended;
    }

    FFmpegBeginInterruptibleOperation(&_interruptState, _ioTimeoutNanos);
    while (YES) {
        int result = avcodec_receive_frame(_codecContext, _frame);
        if (result == 0) {
            FFmpegAudioReadResult *readResult = [self PCMBufferForFrame:_frame error:error];
            av_frame_unref(_frame);
            return readResult;
        }
        if (result == AVERROR_EOF) {
            _decoderEnded = YES;
            FFmpegAudioReadResult *ended = [[FFmpegAudioReadResult alloc] init];
            return ended;
        }
        if (result != AVERROR(EAGAIN)) {
            if (error) *error = FFmpegError(result, @"Unable to receive decoded audio");
            return nil;
        }

        if (_inputEnded) {
            if (!_flushSent) {
                result = avcodec_send_packet(_codecContext, NULL);
                _flushSent = YES;
                if (result < 0 && result != AVERROR_EOF) {
                    if (error) *error = FFmpegError(result, @"Unable to flush decoder");
                    return nil;
                }
                continue;
            }
            _decoderEnded = YES;
            FFmpegAudioReadResult *ended = [[FFmpegAudioReadResult alloc] init];
            return ended;
        }

        if (_packetPending) {
            result = avcodec_send_packet(_codecContext, _packet);
            if (result == AVERROR(EAGAIN)) {
                // The decoder still has output to drain. Keep ownership of
                // this packet and retry it after the next receive call.
                continue;
            }
            av_packet_unref(_packet);
            _packetPending = NO;
            if (result == 0) continue;
            if (result == AVERROR(ENOMEM) || result == AVERROR(EINVAL)) {
                if (error) *error = FFmpegError(result, @"Unable to submit audio packet");
                return nil;
            }
            // A corrupt packet is skipped; continue reading the stream.
        }

        while ((result = av_read_frame(_formatContext, _packet)) >= 0) {
            // A packet is concrete forward progress. Give the next blocking
            // read a fresh idle window instead of imposing a total-track cap.
            FFmpegBeginInterruptibleOperation(&_interruptState, _ioTimeoutNanos);
            if (_packet->stream_index != _audioStreamIndex) {
                av_packet_unref(_packet);
                continue;
            }
            result = avcodec_send_packet(_codecContext, _packet);
            if (result == AVERROR(EAGAIN)) {
                _packetPending = YES;
                break;
            }
            av_packet_unref(_packet);
            if (result == 0) break;
            // Corrupt packets are skipped so a damaged frame doesn't abort a
            // whole album image. Fatal allocator/configuration failures escape.
            if (result == AVERROR(ENOMEM) || result == AVERROR(EINVAL)) {
                if (error) *error = FFmpegError(result, @"Unable to submit audio packet");
                return nil;
            }
        }
        if (result == AVERROR_EOF) _inputEnded = YES;
        else if (result < 0 && result != AVERROR(EAGAIN)) {
            if (error) *error = FFmpegOperationError(
                result, @"Reading audio packet", &_interruptState
            );
            return nil;
        }
    }
}

- (FFmpegAudioReadResult *)PCMBufferForFrame:(AVFrame *)frame error:(NSError **)error {
    int sampleRate = frame->sample_rate > 0 ? frame->sample_rate : _codecContext->sample_rate;
    AVChannelLayout inputLayout = frame->ch_layout;
    AVChannelLayout fallbackLayout = {0};
    if (inputLayout.nb_channels <= 0 || inputLayout.order == AV_CHANNEL_ORDER_UNSPEC) {
        int channels = _codecContext->ch_layout.nb_channels > 0
            ? _codecContext->ch_layout.nb_channels : 2;
        av_channel_layout_default(&fallbackLayout, channels);
        inputLayout = fallbackLayout;
    }

    // Primuse's playback graph is stereo. Converting multichannel PCM to a
    // stereo layout here lets libswresample apply one explicit, deterministic
    // matrix instead of handing 5.1/7.1 to AVAudioConverter's platform-default
    // mapping (which has dropped center/dialogue on some routes).
    const BOOL downmixToStereo = inputLayout.nb_channels > 2;
    AVChannelLayout outputLayout = {0};
    int layoutResult = 0;
    if (downmixToStereo) {
        av_channel_layout_default(&outputLayout, 2);
    } else {
        layoutResult = av_channel_layout_copy(&outputLayout, &inputLayout);
    }
    if (layoutResult < 0 || outputLayout.nb_channels <= 0) {
        av_channel_layout_uninit(&fallbackLayout);
        av_channel_layout_uninit(&outputLayout);
        if (error) *error = FFmpegError(layoutResult < 0 ? layoutResult : AVERROR(EINVAL),
                                        @"Unable to configure PCM output layout");
        return nil;
    }

    enum AVSampleFormat inputFormat = (enum AVSampleFormat)frame->format;
    BOOL layoutChanged = _resamplerInputLayout.nb_channels <= 0 ||
        av_channel_layout_compare(&_resamplerInputLayout, &inputLayout) != 0;
    if (!_resampler || inputFormat != _resamplerInputFormat ||
        sampleRate != _resamplerInputRate || layoutChanged) {
        swr_free(&_resampler);
        av_channel_layout_uninit(&_resamplerInputLayout);
        av_channel_layout_copy(&_resamplerInputLayout, &inputLayout);
        int result = swr_alloc_set_opts2(&_resampler,
                                         &outputLayout, AV_SAMPLE_FMT_FLTP, sampleRate,
                                         &inputLayout, inputFormat, sampleRate,
                                         0, NULL);
        // `swr_alloc_set_opts2` builds FFmpeg's standard, normalized matrix for
        // this explicit input/output layout. Do not install a second manual
        // matrix here: the simulator FFmpeg slice corrupted long 5.1 DTS frame
        // ownership after repeated conversions, later crashing in
        // `av_frame_unref`. The standard matrix still folds centre/surround
        // channels into stereo; the centre-only smoke fixture guards that.
        if (result >= 0) result = swr_init(_resampler);
        if (result < 0) {
            av_channel_layout_uninit(&fallbackLayout);
            av_channel_layout_uninit(&outputLayout);
            if (error) *error = FFmpegError(result, @"Unable to configure PCM converter");
            return nil;
        }
        _resamplerInputFormat = inputFormat;
        _resamplerInputRate = sampleRate;
    }

    int channels = outputLayout.nb_channels;
    int capacity = swr_get_out_samples(_resampler, frame->nb_samples);
    if (capacity < frame->nb_samples) capacity = frame->nb_samples;
    AVAudioChannelLayout *channelLayout = FFmpegAudioChannelLayout(channels);
    AVAudioFormat *format = channelLayout ? [[AVAudioFormat alloc]
        initWithCommonFormat:AVAudioPCMFormatFloat32
                  sampleRate:sampleRate
                 interleaved:NO
                channelLayout:channelLayout] : nil;
    if (!format) {
        av_channel_layout_uninit(&fallbackLayout);
        av_channel_layout_uninit(&outputLayout);
        if (error) *error = FFmpegError(AVERROR(EINVAL), @"Unsupported PCM channel layout");
        return nil;
    }
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)capacity];
    if (!buffer || !buffer.floatChannelData) {
        av_channel_layout_uninit(&fallbackLayout);
        av_channel_layout_uninit(&outputLayout);
        if (error) *error = FFmpegError(AVERROR(ENOMEM), @"Unable to allocate PCM buffer");
        return nil;
    }

    uint8_t **outputData = av_calloc((size_t)channels, sizeof(*outputData));
    if (!outputData) {
        av_channel_layout_uninit(&fallbackLayout);
        av_channel_layout_uninit(&outputLayout);
        if (error) *error = FFmpegError(AVERROR(ENOMEM), @"Unable to allocate PCM planes");
        return nil;
    }
    for (int channel = 0; channel < channels; channel++) {
        outputData[channel] = (uint8_t *)buffer.floatChannelData[channel];
    }
    const uint8_t **inputData = (const uint8_t **)frame->extended_data;
    int converted = swr_convert(_resampler, outputData, capacity,
                                inputData, frame->nb_samples);
    av_free(outputData);
    av_channel_layout_uninit(&fallbackLayout);
    av_channel_layout_uninit(&outputLayout);
    if (converted < 0) {
        if (error) *error = FFmpegError(converted, @"Unable to convert decoded PCM");
        return nil;
    }
    buffer.frameLength = (AVAudioFrameCount)converted;

    FFmpegAudioReadResult *result = [[FFmpegAudioReadResult alloc] init];
    result.buffer = buffer;
    int64_t timestamp = frame->best_effort_timestamp;
    if (timestamp != AV_NOPTS_VALUE) {
        result.presentationTime = timestamp *
            av_q2d(_formatContext->streams[_audioStreamIndex]->time_base);
        result.hasPresentationTime = YES;
    }
    return result;
}

- (BOOL)seekToTime:(NSTimeInterval)time error:(NSError **)error {
    if (!_formatContext || _audioStreamIndex < 0 || !isfinite(time)) return NO;
    AVStream *stream = _formatContext->streams[_audioStreamIndex];
    int64_t timestamp = av_rescale_q((int64_t)llround(MAX(0, time) * AV_TIME_BASE),
                                    AV_TIME_BASE_Q, stream->time_base);
    FFmpegBeginInterruptibleOperation(&_interruptState, _ioTimeoutNanos);
    int result = avformat_seek_file(_formatContext, (int)_audioStreamIndex,
                                    INT64_MIN, timestamp, timestamp,
                                    AVSEEK_FLAG_BACKWARD);
    if (result < 0) {
        if (error) *error = FFmpegOperationError(
            result, @"Seeking audio stream", &_interruptState
        );
        return NO;
    }
    avcodec_flush_buffers(_codecContext);
    if (_resampler) swr_close(_resampler);
    if (_resampler) swr_init(_resampler);
    _inputEnded = NO;
    _flushSent = NO;
    _decoderEnded = NO;
    if (_packetPending) av_packet_unref(_packet);
    _packetPending = NO;
    return YES;
}

- (void)cancel {
    atomic_store_explicit(&_interruptState.cancelled, true, memory_order_release);
}

- (void)closeDecoder {
    swr_free(&_resampler);
    av_channel_layout_uninit(&_resamplerInputLayout);
    av_frame_free(&_frame);
    av_packet_free(&_packet);
    avcodec_free_context(&_codecContext);
    avformat_close_input(&_formatContext);
}

@end
