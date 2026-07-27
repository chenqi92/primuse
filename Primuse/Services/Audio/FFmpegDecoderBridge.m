#import "FFmpegDecoderBridge.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
#include <math.h>
#include <string.h>

static NSString *const FFmpegDecoderErrorDomain = @"com.welape.yuanyin.ffmpeg-decoder";

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

@implementation FFmpegAudioFileInfo
@end

@implementation FFmpegAudioReadResult
@end

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
    FFmpegAudioFileInfo *_fileInfo;
}

+ (BOOL)dataContainsDTSSync:(NSData *)data {
    if (data.length < 4) return NO;
    static const uint8_t syncWords[][4] = {
        {0x7f, 0xfe, 0x80, 0x01},
        {0xfe, 0x7f, 0x01, 0x80},
        {0x1f, 0xff, 0xe8, 0x00},
        {0xff, 0x1f, 0x00, 0xe8},
    };
    const uint8_t *bytes = data.bytes;
    NSUInteger matches = 0;
    for (NSUInteger offset = 0; offset + 4 <= data.length; offset++) {
        for (NSUInteger word = 0; word < sizeof(syncWords) / sizeof(syncWords[0]); word++) {
            if (memcmp(bytes + offset, syncWords[word], 4) == 0) {
                if (++matches >= 2) return YES;
                offset += 3;
                break;
            }
        }
    }
    return NO;
}

+ (BOOL)URLContainsDTSSync:(NSURL *)url {
    if (!url.isFileURL) return NO;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!handle) return NO;
    NSData *prefix = [handle readDataUpToLength:256 * 1024 error:nil];
    [handle closeFile];
    return [self dataContainsDTSSync:prefix];
}

+ (BOOL)canDecodeURL:(NSURL *)url {
    if (!url.isFileURL) return NO;
    NSError *error = nil;
    FFmpegDecoderBridge *decoder = [[FFmpegDecoderBridge alloc] initWithURL:url error:&error];
    return decoder != nil && error == nil;
}

+ (FFmpegAudioFileInfo *)probeURL:(NSURL *)url error:(NSError **)error {
    FFmpegDecoderBridge *decoder = [[FFmpegDecoderBridge alloc] initWithURL:url error:error];
    return decoder.fileInfo;
}

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    _audioStreamIndex = -1;
    _resamplerInputFormat = AV_SAMPLE_FMT_NONE;
    av_channel_layout_uninit(&_resamplerInputLayout);

    const AVInputFormat *forcedInputFormat = NULL;
    if ([[url.pathExtension lowercaseString] isEqualToString:@"wav"] &&
        [[self class] URLContainsDTSSync:url]) {
        // DTS-CD images are formally PCM WAV files. Force the raw DTS demuxer;
        // its parser scans through the RIFF prefix to the first valid sync word.
        forcedInputFormat = av_find_input_format("dts");
    }

    int result = avformat_open_input(&_formatContext, url.fileSystemRepresentation,
                                     forcedInputFormat, NULL);
    if (result < 0) {
        if (error) *error = FFmpegError(result, @"Unable to open audio file");
        [self closeDecoder];
        return nil;
    }
    result = avformat_find_stream_info(_formatContext, NULL);
    if (result < 0) {
        if (error) *error = FFmpegError(result, @"Unable to read stream information");
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
    return self;
}

- (void)dealloc { [self closeDecoder]; }
- (FFmpegAudioFileInfo *)fileInfo { return _fileInfo; }

- (FFmpegAudioReadResult *)readNextBufferWithError:(NSError **)error {
    if (_decoderEnded) {
        FFmpegAudioReadResult *ended = [[FFmpegAudioReadResult alloc] init];
        return ended;
    }

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

        while ((result = av_read_frame(_formatContext, _packet)) >= 0) {
            if (_packet->stream_index != _audioStreamIndex) {
                av_packet_unref(_packet);
                continue;
            }
            result = avcodec_send_packet(_codecContext, _packet);
            av_packet_unref(_packet);
            if (result == 0 || result == AVERROR(EAGAIN)) break;
            // Corrupt packets are skipped so a damaged frame doesn't abort a
            // whole album image. Fatal allocator/configuration failures escape.
            if (result == AVERROR(ENOMEM) || result == AVERROR(EINVAL)) {
                if (error) *error = FFmpegError(result, @"Unable to submit audio packet");
                return nil;
            }
        }
        if (result == AVERROR_EOF) _inputEnded = YES;
        else if (result < 0 && result != AVERROR(EAGAIN)) {
            if (error) *error = FFmpegError(result, @"Unable to read audio packet");
            return nil;
        }
    }
}

- (FFmpegAudioReadResult *)PCMBufferForFrame:(AVFrame *)frame error:(NSError **)error {
    int sampleRate = frame->sample_rate > 0 ? frame->sample_rate : _codecContext->sample_rate;
    AVChannelLayout inputLayout = frame->ch_layout;
    AVChannelLayout fallbackLayout = {0};
    if (inputLayout.nb_channels <= 0) {
        int channels = _codecContext->ch_layout.nb_channels > 0
            ? _codecContext->ch_layout.nb_channels : 2;
        av_channel_layout_default(&fallbackLayout, channels);
        inputLayout = fallbackLayout;
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
                                         &inputLayout, AV_SAMPLE_FMT_FLTP, sampleRate,
                                         &inputLayout, inputFormat, sampleRate,
                                         0, NULL);
        if (result >= 0) result = swr_init(_resampler);
        if (result < 0) {
            av_channel_layout_uninit(&fallbackLayout);
            if (error) *error = FFmpegError(result, @"Unable to configure PCM converter");
            return nil;
        }
        _resamplerInputFormat = inputFormat;
        _resamplerInputRate = sampleRate;
    }

    int channels = inputLayout.nb_channels;
    int capacity = swr_get_out_samples(_resampler, frame->nb_samples);
    if (capacity < frame->nb_samples) capacity = frame->nb_samples;
    AVAudioFormat *format = [[AVAudioFormat alloc]
        initStandardFormatWithSampleRate:sampleRate
                                channels:(AVAudioChannelCount)channels];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)capacity];
    if (!buffer || !buffer.floatChannelData) {
        av_channel_layout_uninit(&fallbackLayout);
        if (error) *error = FFmpegError(AVERROR(ENOMEM), @"Unable to allocate PCM buffer");
        return nil;
    }

    uint8_t **outputData = av_calloc((size_t)channels, sizeof(*outputData));
    if (!outputData) {
        av_channel_layout_uninit(&fallbackLayout);
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
    }
    return result;
}

- (BOOL)seekToTime:(NSTimeInterval)time error:(NSError **)error {
    if (!_formatContext || _audioStreamIndex < 0 || !isfinite(time)) return NO;
    AVStream *stream = _formatContext->streams[_audioStreamIndex];
    int64_t timestamp = av_rescale_q((int64_t)llround(MAX(0, time) * AV_TIME_BASE),
                                    AV_TIME_BASE_Q, stream->time_base);
    int result = avformat_seek_file(_formatContext, (int)_audioStreamIndex,
                                    INT64_MIN, timestamp, timestamp,
                                    AVSEEK_FLAG_BACKWARD);
    if (result < 0) {
        if (error) *error = FFmpegError(result, @"Unable to seek audio stream");
        return NO;
    }
    avcodec_flush_buffers(_codecContext);
    if (_resampler) swr_close(_resampler);
    if (_resampler) swr_init(_resampler);
    _inputEnded = NO;
    _flushSent = NO;
    _decoderEnded = NO;
    return YES;
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
