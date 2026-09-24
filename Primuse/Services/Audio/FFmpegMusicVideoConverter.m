#import "FFmpegMusicVideoConverter.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libavutil/mathematics.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <stdatomic.h>

static NSString *const FFmpegMusicVideoErrorDomain = @"FFmpegMusicVideoConverter";

static NSError *FFmpegMusicVideoError(int code, NSString *operation) {
    char description[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(code, description, sizeof(description));
    return [NSError errorWithDomain:FFmpegMusicVideoErrorDomain
                               code:code
                           userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %s", operation, description]
    }];
}

typedef struct {
    atomic_bool cancelled;
} FFmpegMusicVideoInterrupt;

static int FFmpegMusicVideoInterruptCallback(void *opaque) {
    FFmpegMusicVideoInterrupt *state = opaque;
    return atomic_load_explicit(&state->cancelled, memory_order_acquire) ? 1 : 0;
}

@interface FFmpegMusicVideoStream ()
- (instancetype)initWithStream:(const AVStream *)stream kind:(FFmpegMusicVideoStreamKind)kind;
@end

@implementation FFmpegMusicVideoStream

- (instancetype)initWithStream:(const AVStream *)stream kind:(FFmpegMusicVideoStreamKind)kind {
    self = [super init];
    if (!self) return nil;
    const AVCodecParameters *parameters = stream->codecpar;
    const AVCodecDescriptor *descriptor = avcodec_descriptor_get(parameters->codec_id);
    _kind = kind;
    _codecName = descriptor && descriptor->name
        ? [NSString stringWithUTF8String:descriptor->name] : @"unknown";
    _profile = parameters->profile;
    const AVPixFmtDescriptor *pixel = kind == FFmpegMusicVideoStreamKindVideo
        ? av_pix_fmt_desc_get((enum AVPixelFormat)parameters->format) : NULL;
    NSInteger depth = parameters->bits_per_raw_sample;
    if (depth <= 0 && pixel) depth = pixel->comp[0].depth;
    _bitDepth = MAX(0, depth);
    _chroma420 = pixel == NULL
        || (!(pixel->flags & AV_PIX_FMT_FLAG_RGB)
            && pixel->log2_chroma_w == 1 && pixel->log2_chroma_h == 1);
    return self;
}

@end

/// Per output stream. `encoder == NULL` means the packets are copied.
typedef struct {
    int inputIndex;
    AVStream *input;
    AVStream *output;
    AVCodecContext *decoder;
    AVCodecContext *encoder;
    // Video: staging frame for decoders that do not output planar 4:2:0.
    AVFrame *staging;
    int64_t lastVideoPTS;
    int64_t syntheticVideoPTS;
    // Audio: resampler into the encoder's format and a FIFO that cuts the
    // result into the encoder's fixed frame size.
    SwrContext *resampler;
    enum AVSampleFormat resamplerInputFormat;
    int resamplerInputRate;
    AVChannelLayout resamplerInputLayout;
    AVAudioFifo *fifo;
    int64_t nextAudioPTS;
    BOOL audioClockStarted;
    /// The input's start time in this stream's time base. MPEG-PS/TS start
    /// at 0.5–1.4 s; kept, the MP4 would open on that much black silence.
    int64_t startOffset;
} FFmpegMusicVideoOutput;

static void FFmpegMusicVideoOutputFree(FFmpegMusicVideoOutput *output) {
    avcodec_free_context(&output->decoder);
    avcodec_free_context(&output->encoder);
    av_frame_free(&output->staging);
    swr_free(&output->resampler);
    av_channel_layout_uninit(&output->resamplerInputLayout);
    if (output->fifo) {
        av_audio_fifo_free(output->fifo);
        output->fifo = NULL;
    }
}

/// AAC's sample rate table. Anything else is resampled to 48 kHz.
static int FFmpegMusicVideoAACSampleRate(int rate) {
    static const int rates[] = {
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000,
    };
    for (size_t index = 0; index < sizeof(rates) / sizeof(rates[0]); index++) {
        if (rates[index] == rate) return rate;
    }
    return 48000;
}

static BOOL FFmpegMusicVideoIsPlanar420(int format) {
    return format == AV_PIX_FMT_YUV420P || format == AV_PIX_FMT_YUVJ420P;
}

static uint8_t FFmpegMusicVideoClampByte(int value) {
    return (uint8_t)(value < 0 ? 0 : (value > 255 ? 255 : value));
}

/// Planar YUV of any subsampling at 8 bits, or at 9–16 bits little-endian:
/// the formats decoders actually emit (4:2:2 MJPEG and DV, 10-bit H.264 and
/// HEVC, 4:4:4 VP9/Theora). Straight loops, a few milliseconds a 1080p frame.
static BOOL FFmpegMusicVideoConvertPlanarYUV(const AVFrame *source,
                                             const AVPixFmtDescriptor *descriptor,
                                             AVFrame *destination) {
    if (descriptor->nb_components < 3
        || (descriptor->flags & (AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_PAL | AV_PIX_FMT_FLAG_BE))
        || !(descriptor->flags & AV_PIX_FMT_FLAG_PLANAR)) {
        return NO;
    }
    for (int component = 0; component < 3; component++) {
        const AVComponentDescriptor *c = &descriptor->comp[component];
        if (c->plane != component || c->shift != 0 || c->offset != 0) return NO;
        if (!(c->step == 1 && c->depth == 8) && !(c->step == 2 && c->depth > 8 && c->depth <= 16)) return NO;
    }
    const int wide = descriptor->comp[0].step == 2;
    const int shift = descriptor->comp[0].depth - 8;
    const int width = destination->width;
    const int height = destination->height;
    for (int y = 0; y < height; y++) {
        uint8_t *out = destination->data[0] + (ptrdiff_t)y * destination->linesize[0];
        const uint8_t *in = source->data[0] + (ptrdiff_t)y * source->linesize[0];
        if (wide) {
            const uint16_t *in16 = (const uint16_t *)in;
            for (int x = 0; x < width; x++) out[x] = (uint8_t)(in16[x] >> shift);
        } else {
            memcpy(out, in, (size_t)width);
        }
    }
    const int chromaWidth = (width + 1) / 2;
    const int chromaHeight = (height + 1) / 2;
    const int sourceChromaWidth = AV_CEIL_RSHIFT(source->width, descriptor->log2_chroma_w);
    const int sourceChromaHeight = AV_CEIL_RSHIFT(source->height, descriptor->log2_chroma_h);
    for (int plane = 1; plane <= 2; plane++) {
        for (int y = 0; y < chromaHeight; y++) {
            const int sourceRow = MIN((y * 2) >> descriptor->log2_chroma_h, sourceChromaHeight - 1);
            uint8_t *out = destination->data[plane] + (ptrdiff_t)y * destination->linesize[plane];
            const uint8_t *in = source->data[plane] + (ptrdiff_t)sourceRow * source->linesize[plane];
            for (int x = 0; x < chromaWidth; x++) {
                const int sourceColumn = MIN((x * 2) >> descriptor->log2_chroma_w, sourceChromaWidth - 1);
                out[x] = wide ? (uint8_t)(((const uint16_t *)in)[sourceColumn] >> shift) : in[sourceColumn];
            }
        }
    }
    return YES;
}

/// Converts any non-hardware pixel format into 8-bit planar 4:2:0 using
/// libavutil's generic line reader: higher bit depths are shifted down,
/// other chroma layouts are point-sampled, RGB and palette formats go
/// through BT.601. Only the rare formats land here (4:2:2 MJPEG, 10-bit
/// H.264/HEVC, Cinepak RGB); 4:2:0 frames are handed to the encoder as-is.
static BOOL FFmpegMusicVideoConvertFrame(const AVFrame *source, AVFrame *destination) {
    const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get((enum AVPixelFormat)source->format);
    if (!descriptor || (descriptor->flags & (AV_PIX_FMT_FLAG_HWACCEL | AV_PIX_FMT_FLAG_BITSTREAM))) {
        return NO;
    }
    if (av_frame_make_writable(destination) < 0) return NO;
    if (FFmpegMusicVideoConvertPlanarYUV(source, descriptor, destination)) return YES;
    const int width = destination->width;
    const int height = destination->height;
    const int chromaWidth = (width + 1) / 2;
    const int chromaHeight = (height + 1) / 2;
    const BOOL palette = (descriptor->flags & AV_PIX_FMT_FLAG_PAL) != 0;
    const BOOL rgb = (descriptor->flags & AV_PIX_FMT_FLAG_RGB) != 0 || palette;
    const int components = palette ? 3 : descriptor->nb_components;
    const uint8_t *planes[4] = {
        source->data[0], source->data[1], source->data[2], source->data[3],
    };
    const int *linesizes = source->linesize;
    uint16_t *line = av_malloc_array((size_t)source->width + 16, 4 * sizeof(uint16_t));
    if (!line) return NO;
    uint16_t *channels[3] = {line, line + source->width + 16, line + 2 * (source->width + 16)};

    if (rgb) {
        const int depth = palette ? 8 : descriptor->comp[0].depth;
        for (int y = 0; y < height; y++) {
            for (int component = 0; component < 3; component++) {
                av_read_image_line2(channels[component], planes, linesizes, descriptor,
                                    0, y, component, width, palette, 2);
            }
            uint8_t *luma = destination->data[0] + (ptrdiff_t)y * destination->linesize[0];
            const BOOL chromaRow = (y % 2) == 0;
            uint8_t *cb = destination->data[1] + (ptrdiff_t)(y / 2) * destination->linesize[1];
            uint8_t *cr = destination->data[2] + (ptrdiff_t)(y / 2) * destination->linesize[2];
            // Palette entries are native-endian ARGB words: B, G, R in memory.
            const uint16_t *red = palette ? channels[2] : channels[0];
            const uint16_t *blue = palette ? channels[0] : channels[2];
            for (int x = 0; x < width; x++) {
                const int r = red[x] >> (depth > 8 ? depth - 8 : 0);
                const int g = channels[1][x] >> (depth > 8 ? depth - 8 : 0);
                const int b = blue[x] >> (depth > 8 ? depth - 8 : 0);
                luma[x] = FFmpegMusicVideoClampByte(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
                if (chromaRow && (x % 2) == 0) {
                    cb[x / 2] = FFmpegMusicVideoClampByte(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
                    cr[x / 2] = FFmpegMusicVideoClampByte(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
                }
            }
        }
        av_free(line);
        return YES;
    }

    const int lumaShift = descriptor->comp[0].depth > 8 ? descriptor->comp[0].depth - 8 : 0;
    for (int y = 0; y < height; y++) {
        av_read_image_line2(channels[0], planes, linesizes, descriptor, 0, y, 0, width, 0, 2);
        uint8_t *luma = destination->data[0] + (ptrdiff_t)y * destination->linesize[0];
        for (int x = 0; x < width; x++) luma[x] = (uint8_t)(channels[0][x] >> lumaShift);
    }
    const int sourceChromaWidth = AV_CEIL_RSHIFT(source->width, descriptor->log2_chroma_w);
    for (int component = 1; component <= 2; component++) {
        for (int y = 0; y < chromaHeight; y++) {
            uint8_t *chroma = destination->data[component]
                + (ptrdiff_t)y * destination->linesize[component];
            if (components < 3) {
                memset(chroma, 128, (size_t)chromaWidth);
                continue;
            }
            const int shift = descriptor->comp[component].depth > 8
                ? descriptor->comp[component].depth - 8 : 0;
            const int sourceRow = (y * 2) >> descriptor->log2_chroma_h;
            av_read_image_line2(channels[1], planes, linesizes, descriptor,
                                0, sourceRow, component, sourceChromaWidth, 0, 2);
            for (int x = 0; x < chromaWidth; x++) {
                const int sourceColumn = MIN((x * 2) >> descriptor->log2_chroma_w,
                                             sourceChromaWidth - 1);
                chroma[x] = (uint8_t)(channels[1][sourceColumn] >> shift);
            }
        }
    }
    av_free(line);
    return YES;
}

@implementation FFmpegMusicVideoConverter {
    NSURL *_inputURL;
    NSURL *_outputURL;
    FFmpegMusicVideoInterrupt _interrupt;
    NSString *_summary;
    BOOL _copiedAnyStream;
}

- (instancetype)initWithInputURL:(NSURL *)inputURL outputURL:(NSURL *)outputURL {
    self = [super init];
    if (!self) return nil;
    _inputURL = [inputURL copy];
    _outputURL = [outputURL copy];
    atomic_init(&_interrupt.cancelled, false);
    _summary = @"";
    return self;
}

- (NSString *)summary { return _summary; }
- (BOOL)copiedAnyStream { return _copiedAnyStream; }

- (void)cancel {
    atomic_store_explicit(&_interrupt.cancelled, true, memory_order_release);
}

- (BOOL)isCancelled {
    return atomic_load_explicit(&_interrupt.cancelled, memory_order_acquire);
}

/// The largest non-picture video stream, preferring the default one.
static int FFmpegMusicVideoBestVideoStream(const AVFormatContext *input) {
    int best = -1;
    int64_t bestScore = -1;
    for (unsigned int index = 0; index < input->nb_streams; index++) {
        const AVStream *stream = input->streams[index];
        if (stream->codecpar->codec_type != AVMEDIA_TYPE_VIDEO) continue;
        if (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) continue;
        int64_t score = (int64_t)stream->codecpar->width * stream->codecpar->height;
        if (stream->disposition & AV_DISPOSITION_DEFAULT) score += INT32_MAX;
        if (score > bestScore) {
            bestScore = score;
            best = (int)index;
        }
    }
    return best;
}

- (BOOL)convertForcingTranscode:(BOOL)forceTranscode
                       progress:(void (^)(double))progress
                          error:(NSError **)error {
    _copiedAnyStream = NO;
    _summary = @"";
    AVFormatContext *input = NULL;
    AVFormatContext *output = NULL;
    AVPacket *packet = av_packet_alloc();
    AVPacket *encoded = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    FFmpegMusicVideoOutput outputs[2];
    memset(outputs, 0, sizeof(outputs));
    int outputCount = 0;
    int streamMap[64];
    for (int index = 0; index < 64; index++) streamMap[index] = -1;
    NSMutableArray<NSString *> *summary = [NSMutableArray array];
    NSError *failure = nil;
    BOOL headerWritten = NO;
    int result = 0;

    if (!packet || !encoded || !frame) {
        failure = FFmpegMusicVideoError(AVERROR(ENOMEM), @"Allocating buffers");
        goto cleanup;
    }

    input = avformat_alloc_context();
    if (!input) {
        failure = FFmpegMusicVideoError(AVERROR(ENOMEM), @"Allocating input");
        goto cleanup;
    }
    input->interrupt_callback.callback = FFmpegMusicVideoInterruptCallback;
    input->interrupt_callback.opaque = &_interrupt;
    result = avformat_open_input(&input, _inputURL.fileSystemRepresentation, NULL, NULL);
    if (result < 0) {
        failure = FFmpegMusicVideoError(result, @"Opening video");
        goto cleanup;
    }
    result = avformat_find_stream_info(input, NULL);
    if (result < 0) {
        failure = FFmpegMusicVideoError(result, @"Reading stream information");
        goto cleanup;
    }

    int videoIndex = FFmpegMusicVideoBestVideoStream(input);
    int audioIndex = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, videoIndex, NULL, 0);
    if (audioIndex < 0) audioIndex = -1;
    if (videoIndex < 0 && audioIndex < 0) {
        failure = FFmpegMusicVideoError(AVERROR_STREAM_NOT_FOUND, @"Finding audio or video");
        goto cleanup;
    }

    result = avformat_alloc_output_context2(&output, NULL, "mp4", _outputURL.fileSystemRepresentation);
    if (result < 0 || !output) {
        failure = FFmpegMusicVideoError(result < 0 ? result : AVERROR(ENOMEM), @"Creating MP4");
        goto cleanup;
    }

    const int candidates[2] = {videoIndex, audioIndex};
    for (int slot = 0; slot < 2; slot++) {
        const int inputIndex = candidates[slot];
        if (inputIndex < 0 || inputIndex >= 64) continue;
        AVStream *inStream = input->streams[inputIndex];
        const BOOL isVideo = inStream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO;
        FFmpegMusicVideoStream *info = [[FFmpegMusicVideoStream alloc]
            initWithStream:inStream
                      kind:isVideo ? FFmpegMusicVideoStreamKindVideo : FFmpegMusicVideoStreamKindAudio];
        BOOL copy = !forceTranscode && self.shouldCopyStream && self.shouldCopyStream(info)
            && avformat_query_codec(output->oformat, inStream->codecpar->codec_id,
                                    FF_COMPLIANCE_NORMAL) == 1;
        FFmpegMusicVideoOutput *out = &outputs[outputCount];
        out->inputIndex = inputIndex;
        out->input = inStream;
        out->lastVideoPTS = AV_NOPTS_VALUE;
        out->startOffset = input->start_time != AV_NOPTS_VALUE && input->start_time > 0
            ? av_rescale_q(input->start_time, AV_TIME_BASE_Q, inStream->time_base) : 0;

        if (!copy) {
            const AVCodec *decoderCodec = avcodec_find_decoder(inStream->codecpar->codec_id);
            if (!decoderCodec) {
                if (isVideo && audioIndex >= 0) {
                    // No decoder (AV1 without hardware, an exotic codec):
                    // keep the song's sound rather than fail the whole file.
                    [summary addObject:[NSString stringWithFormat:@"video %@ dropped", info.codecName]];
                    memset(out, 0, sizeof(*out));
                    continue;
                }
                failure = FFmpegMusicVideoError(AVERROR_DECODER_NOT_FOUND,
                    [NSString stringWithFormat:@"No decoder for %@", info.codecName]);
                goto cleanup;
            }
            out->decoder = avcodec_alloc_context3(decoderCodec);
            if (!out->decoder) {
                failure = FFmpegMusicVideoError(AVERROR(ENOMEM), @"Allocating decoder");
                goto cleanup;
            }
            avcodec_parameters_to_context(out->decoder, inStream->codecpar);
            out->decoder->pkt_timebase = inStream->time_base;
            out->decoder->thread_count = 0;
            result = avcodec_open2(out->decoder, decoderCodec, NULL);
            if (result < 0) {
                failure = FFmpegMusicVideoError(result,
                    [NSString stringWithFormat:@"Opening %@ decoder", info.codecName]);
                goto cleanup;
            }
        }

        out->output = avformat_new_stream(output, NULL);
        if (!out->output) {
            failure = FFmpegMusicVideoError(AVERROR(ENOMEM), @"Adding output stream");
            goto cleanup;
        }

        if (copy) {
            result = avcodec_parameters_copy(out->output->codecpar, inStream->codecpar);
            if (result < 0) {
                failure = FFmpegMusicVideoError(result, @"Copying stream parameters");
                goto cleanup;
            }
            out->output->codecpar->codec_tag = 0;
            // AVPlayer only opens HEVC in MP4 under the `hvc1` sample entry.
            if (inStream->codecpar->codec_id == AV_CODEC_ID_HEVC) {
                out->output->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
            }
            out->output->time_base = inStream->time_base;
            out->output->sample_aspect_ratio = inStream->sample_aspect_ratio;
            _copiedAnyStream = YES;
            [summary addObject:[NSString stringWithFormat:@"%@ %@ copied",
                                isVideo ? @"video" : @"audio", info.codecName]];
        } else if (isVideo) {
            const AVCodec *encoderCodec = avcodec_find_encoder_by_name("h264_videotoolbox");
            if (!encoderCodec) {
                failure = FFmpegMusicVideoError(AVERROR_ENCODER_NOT_FOUND, @"Finding H.264 encoder");
                goto cleanup;
            }
            AVCodecContext *encoder = avcodec_alloc_context3(encoderCodec);
            out->encoder = encoder;
            if (!encoder) {
                failure = FFmpegMusicVideoError(AVERROR(ENOMEM), @"Allocating encoder");
                goto cleanup;
            }
            AVRational frameRate = av_guess_frame_rate(input, inStream, NULL);
            if (frameRate.num <= 0 || frameRate.den <= 0 || av_q2d(frameRate) > 240) {
                frameRate = (AVRational){25, 1};
            }
            // VideoToolbox wants even dimensions; drop the odd edge line.
            encoder->width = out->decoder->width & ~1;
            encoder->height = out->decoder->height & ~1;
            if (encoder->width <= 0 || encoder->height <= 0) {
                failure = FFmpegMusicVideoError(AVERROR_INVALIDDATA, @"Reading video size");
                goto cleanup;
            }
            encoder->pix_fmt = AV_PIX_FMT_YUV420P;
            encoder->time_base = inStream->time_base.num > 0
                ? inStream->time_base : av_inv_q(frameRate);
            encoder->framerate = frameRate;
            encoder->sample_aspect_ratio = out->decoder->sample_aspect_ratio.num > 0
                ? out->decoder->sample_aspect_ratio : inStream->sample_aspect_ratio;
            encoder->color_range = out->decoder->color_range;
            encoder->color_primaries = out->decoder->color_primaries;
            encoder->color_trc = out->decoder->color_trc;
            encoder->colorspace = out->decoder->colorspace;
            // Bitrate by picture area: ~7 Mb/s at 1080p30, never below
            // 1.5 Mb/s for DVD-sized sources, never above 16 Mb/s.
            const double pixelsPerSecond = (double)encoder->width * encoder->height * av_q2d(frameRate);
            encoder->bit_rate = (int64_t)MIN(MAX(pixelsPerSecond * 0.12, 1500000.0), 16000000.0);
            encoder->gop_size = MAX(1, (int)lround(av_q2d(frameRate) * 2));
            encoder->max_b_frames = 0;
            encoder->profile = AV_PROFILE_H264_HIGH;
            av_opt_set_int(encoder->priv_data, "allow_sw", 1, 0);
            av_opt_set_int(encoder->priv_data, "realtime", 0, 0);
            if (output->oformat->flags & AVFMT_GLOBALHEADER) {
                encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
            }
            result = avcodec_open2(encoder, encoderCodec, NULL);
            if (result < 0) {
                failure = FFmpegMusicVideoError(result, @"Starting H.264 encoder");
                goto cleanup;
            }
            avcodec_parameters_from_context(out->output->codecpar, encoder);
            out->output->time_base = encoder->time_base;
            out->output->avg_frame_rate = frameRate;
            out->output->sample_aspect_ratio = encoder->sample_aspect_ratio;
            [summary addObject:[NSString stringWithFormat:@"video %@ → h264 %dx%d",
                                info.codecName, encoder->width, encoder->height]];
        } else {
            const AVCodec *encoderCodec = avcodec_find_encoder(AV_CODEC_ID_AAC);
            if (!encoderCodec) {
                failure = FFmpegMusicVideoError(AVERROR_ENCODER_NOT_FOUND, @"Finding AAC encoder");
                goto cleanup;
            }
            AVCodecContext *encoder = avcodec_alloc_context3(encoderCodec);
            out->encoder = encoder;
            if (!encoder) {
                failure = FFmpegMusicVideoError(AVERROR(ENOMEM), @"Allocating encoder");
                goto cleanup;
            }
            const int channels = out->decoder->ch_layout.nb_channels;
            if (channels == 6) {
                encoder->ch_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_5POINT1_BACK;
            } else {
                av_channel_layout_default(&encoder->ch_layout, channels == 1 ? 1 : 2);
            }
            encoder->sample_rate = FFmpegMusicVideoAACSampleRate(out->decoder->sample_rate);
            encoder->sample_fmt = AV_SAMPLE_FMT_FLTP;
            encoder->bit_rate = MIN(96000 * encoder->ch_layout.nb_channels, 384000);
            if (encoder->ch_layout.nb_channels == 1) encoder->bit_rate = 128000;
            encoder->time_base = (AVRational){1, encoder->sample_rate};
            if (output->oformat->flags & AVFMT_GLOBALHEADER) {
                encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
            }
            result = avcodec_open2(encoder, encoderCodec, NULL);
            if (result < 0) {
                failure = FFmpegMusicVideoError(result, @"Starting AAC encoder");
                goto cleanup;
            }
            avcodec_parameters_from_context(out->output->codecpar, encoder);
            out->output->time_base = encoder->time_base;
            out->fifo = av_audio_fifo_alloc(encoder->sample_fmt, encoder->ch_layout.nb_channels,
                                            MAX(encoder->frame_size, 1024));
            if (!out->fifo) {
                failure = FFmpegMusicVideoError(AVERROR(ENOMEM), @"Allocating audio buffer");
                goto cleanup;
            }
            [summary addObject:[NSString stringWithFormat:@"audio %@ → aac %dch %d Hz",
                                info.codecName, encoder->ch_layout.nb_channels, encoder->sample_rate]];
        }
        streamMap[inputIndex] = outputCount;
        outputCount++;
    }

    if (outputCount == 0) {
        failure = FFmpegMusicVideoError(AVERROR_STREAM_NOT_FOUND, @"Nothing playable");
        goto cleanup;
    }

    result = avio_open2(&output->pb, _outputURL.fileSystemRepresentation, AVIO_FLAG_WRITE,
                        &input->interrupt_callback, NULL);
    if (result < 0) {
        failure = FFmpegMusicVideoError(result, @"Creating output file");
        goto cleanup;
    }
    result = avformat_write_header(output, NULL);
    if (result < 0) {
        failure = FFmpegMusicVideoError(result, @"Writing MP4 header");
        goto cleanup;
    }
    headerWritten = YES;

    const double totalDuration = input->duration > 0 ? (double)input->duration / AV_TIME_BASE : 0;
    const double startTime = input->start_time != AV_NOPTS_VALUE
        ? (double)input->start_time / AV_TIME_BASE : 0;
    int lastReportedPercent = -1;

    while (YES) {
        if ([self isCancelled]) {
            failure = FFmpegMusicVideoError(AVERROR_EXIT, @"Cancelled");
            goto cleanup;
        }
        result = av_read_frame(input, packet);
        if (result == AVERROR_EOF) break;
        if (result < 0) {
            if ([self isCancelled]) {
                failure = FFmpegMusicVideoError(AVERROR_EXIT, @"Cancelled");
            } else {
                failure = FFmpegMusicVideoError(result, @"Reading video");
            }
            goto cleanup;
        }
        const int outputIndex = packet->stream_index < 64 ? streamMap[packet->stream_index] : -1;
        if (outputIndex < 0) {
            av_packet_unref(packet);
            continue;
        }
        FFmpegMusicVideoOutput *out = &outputs[outputIndex];

        if (progress && totalDuration > 0) {
            const int64_t timestamp = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
            if (timestamp != AV_NOPTS_VALUE) {
                const double seconds = timestamp * av_q2d(out->input->time_base) - startTime;
                const int percent = (int)MIN(MAX(seconds / totalDuration * 100.0, 0.0), 99.0);
                if (percent != lastReportedPercent) {
                    lastReportedPercent = percent;
                    progress(percent / 100.0);
                }
            }
        }

        if (!out->encoder) {
            if (packet->pts != AV_NOPTS_VALUE) packet->pts -= out->startOffset;
            if (packet->dts != AV_NOPTS_VALUE) packet->dts -= out->startOffset;
            av_packet_rescale_ts(packet, out->input->time_base, out->output->time_base);
            packet->stream_index = out->output->index;
            packet->pos = -1;
            result = av_interleaved_write_frame(output, packet);
            if (result < 0) {
                failure = FFmpegMusicVideoError(result, @"Copying packet");
                goto cleanup;
            }
            continue;
        }

        result = avcodec_send_packet(out->decoder, packet);
        av_packet_unref(packet);
        // A damaged packet costs one frame, not the conversion.
        if (result < 0 && result != AVERROR(EAGAIN)) continue;
        if (![self drainDecoderOf:out into:output frame:frame packet:encoded error:&failure]) {
            goto cleanup;
        }
    }

    for (int index = 0; index < outputCount; index++) {
        FFmpegMusicVideoOutput *out = &outputs[index];
        if (!out->encoder) continue;
        avcodec_send_packet(out->decoder, NULL);
        if (![self drainDecoderOf:out into:output frame:frame packet:encoded error:&failure]) {
            goto cleanup;
        }
        if (out->output->codecpar->codec_type == AVMEDIA_TYPE_AUDIO
            && ![self flushAudioOf:out into:output packet:encoded final:YES error:&failure]) {
            goto cleanup;
        }
        avcodec_send_frame(out->encoder, NULL);
        if (![self writeEncodedPacketsOf:out into:output packet:encoded error:&failure]) {
            goto cleanup;
        }
    }

    result = av_write_trailer(output);
    if (result < 0) {
        failure = FFmpegMusicVideoError(result, @"Finishing MP4");
        goto cleanup;
    }
    headerWritten = NO;
    if (progress) progress(1.0);

cleanup:
    if (output && headerWritten && failure) {
        av_write_trailer(output);
    }
    for (int index = 0; index < 2; index++) FFmpegMusicVideoOutputFree(&outputs[index]);
    if (output) {
        if (output->pb) avio_closep(&output->pb);
        avformat_free_context(output);
    }
    avformat_close_input(&input);
    av_packet_free(&packet);
    av_packet_free(&encoded);
    av_frame_free(&frame);
    _summary = [summary componentsJoinedByString:@", "];
    if (failure) {
        [[NSFileManager defaultManager] removeItemAtURL:_outputURL error:nil];
        if (error) *error = failure;
        return NO;
    }
    return YES;
}

- (BOOL)drainDecoderOf:(FFmpegMusicVideoOutput *)out
                  into:(AVFormatContext *)output
                 frame:(AVFrame *)frame
                packet:(AVPacket *)encoded
                 error:(NSError **)error {
    while (YES) {
        int result = avcodec_receive_frame(out->decoder, frame);
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) return YES;
        if (result < 0) return YES;  // decode error: skip the frame
        BOOL ok = out->output->codecpar->codec_type == AVMEDIA_TYPE_VIDEO
            ? [self encodeVideoFrame:frame of:out into:output packet:encoded error:error]
            : [self encodeAudioFrame:frame of:out into:output packet:encoded error:error];
        av_frame_unref(frame);
        if (!ok) return NO;
    }
}

- (BOOL)encodeVideoFrame:(AVFrame *)frame
                      of:(FFmpegMusicVideoOutput *)out
                    into:(AVFormatContext *)output
                  packet:(AVPacket *)encoded
                   error:(NSError **)error {
    AVCodecContext *encoder = out->encoder;
    int64_t pts = frame->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE) pts = frame->pts;
    if (pts == AV_NOPTS_VALUE) {
        // Streams without timestamps (some AVI): one frame period each.
        pts = out->syntheticVideoPTS;
    } else {
        pts = av_rescale_q(pts - out->startOffset, out->input->time_base, encoder->time_base);
    }
    // VideoToolbox rejects a timestamp that does not move forward.
    if (out->lastVideoPTS != AV_NOPTS_VALUE && pts <= out->lastVideoPTS) {
        pts = out->lastVideoPTS + 1;
    }
    out->lastVideoPTS = pts;
    out->syntheticVideoPTS = pts + MAX(1, av_rescale_q(1, av_inv_q(encoder->framerate), encoder->time_base));

    AVFrame *source = frame;
    if (FFmpegMusicVideoIsPlanar420(frame->format)
        && frame->width >= encoder->width && frame->height >= encoder->height) {
        // Same memory layout; full-range JPEG YUV only differs in range.
        frame->format = AV_PIX_FMT_YUV420P;
        frame->width = encoder->width;
        frame->height = encoder->height;
    } else {
        if (!out->staging) {
            out->staging = av_frame_alloc();
            if (!out->staging) {
                if (error) *error = FFmpegMusicVideoError(AVERROR(ENOMEM), @"Allocating frame");
                return NO;
            }
            out->staging->format = AV_PIX_FMT_YUV420P;
            out->staging->width = encoder->width;
            out->staging->height = encoder->height;
            if (av_frame_get_buffer(out->staging, 0) < 0) {
                if (error) *error = FFmpegMusicVideoError(AVERROR(ENOMEM), @"Allocating frame");
                return NO;
            }
        }
        if (frame->width < encoder->width || frame->height < encoder->height
            || !FFmpegMusicVideoConvertFrame(frame, out->staging)) {
            return YES;  // a frame of an unexpected shape is skipped
        }
        out->staging->color_range = frame->color_range;
        source = out->staging;
    }
    source->pts = pts;
    source->pict_type = AV_PICTURE_TYPE_NONE;
    int result = avcodec_send_frame(encoder, source);
    if (result < 0 && result != AVERROR(EAGAIN)) {
        if (error) *error = FFmpegMusicVideoError(result, @"Encoding video");
        return NO;
    }
    return [self writeEncodedPacketsOf:out into:output packet:encoded error:error];
}

- (BOOL)encodeAudioFrame:(AVFrame *)frame
                      of:(FFmpegMusicVideoOutput *)out
                    into:(AVFormatContext *)output
                  packet:(AVPacket *)encoded
                   error:(NSError **)error {
    AVCodecContext *encoder = out->encoder;
    if (!out->audioClockStarted) {
        int64_t start = frame->best_effort_timestamp;
        if (start == AV_NOPTS_VALUE) start = frame->pts;
        out->nextAudioPTS = start == AV_NOPTS_VALUE ? 0
            : MAX(0, av_rescale_q(start - out->startOffset, out->input->time_base, encoder->time_base));
        out->audioClockStarted = YES;
    }
    const BOOL formatChanged = !out->resampler
        || out->resamplerInputFormat != frame->format
        || out->resamplerInputRate != frame->sample_rate
        || av_channel_layout_compare(&out->resamplerInputLayout, &frame->ch_layout) != 0;
    if (formatChanged) {
        swr_free(&out->resampler);
        AVChannelLayout inputLayout = {0};
        if (frame->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC || frame->ch_layout.nb_channels <= 0) {
            av_channel_layout_default(&inputLayout, MAX(frame->ch_layout.nb_channels, 1));
        } else {
            av_channel_layout_copy(&inputLayout, &frame->ch_layout);
        }
        int result = swr_alloc_set_opts2(&out->resampler,
                                         &encoder->ch_layout, encoder->sample_fmt, encoder->sample_rate,
                                         &inputLayout, (enum AVSampleFormat)frame->format, frame->sample_rate,
                                         0, NULL);
        av_channel_layout_uninit(&inputLayout);
        if (result < 0 || swr_init(out->resampler) < 0) {
            if (error) *error = FFmpegMusicVideoError(result < 0 ? result : AVERROR(EINVAL), @"Starting resampler");
            return NO;
        }
        out->resamplerInputFormat = (enum AVSampleFormat)frame->format;
        out->resamplerInputRate = frame->sample_rate;
        av_channel_layout_uninit(&out->resamplerInputLayout);
        av_channel_layout_copy(&out->resamplerInputLayout, &frame->ch_layout);
    }
    const int capacity = swr_get_out_samples(out->resampler, frame->nb_samples);
    if (capacity <= 0) return YES;
    uint8_t **converted = NULL;
    int result = av_samples_alloc_array_and_samples(&converted, NULL, encoder->ch_layout.nb_channels,
                                                    capacity, encoder->sample_fmt, 0);
    if (result < 0) {
        if (error) *error = FFmpegMusicVideoError(result, @"Allocating audio");
        return NO;
    }
    const int samples = swr_convert(out->resampler, converted, capacity,
                                    (const uint8_t **)frame->extended_data, frame->nb_samples);
    if (samples > 0) av_audio_fifo_write(out->fifo, (void **)converted, samples);
    av_freep(&converted[0]);
    av_freep(&converted);
    return [self flushAudioOf:out into:output packet:encoded final:NO error:error];
}

/// Feeds whole encoder frames out of the FIFO; `final` also drains the
/// resampler and sends the short last frame.
- (BOOL)flushAudioOf:(FFmpegMusicVideoOutput *)out
                into:(AVFormatContext *)output
              packet:(AVPacket *)encoded
               final:(BOOL)final
               error:(NSError **)error {
    AVCodecContext *encoder = out->encoder;
    if (final && out->resampler) {
        const int capacity = MAX(swr_get_out_samples(out->resampler, 0), 0);
        if (capacity > 0) {
            uint8_t **converted = NULL;
            if (av_samples_alloc_array_and_samples(&converted, NULL, encoder->ch_layout.nb_channels,
                                                   capacity, encoder->sample_fmt, 0) >= 0) {
                const int samples = swr_convert(out->resampler, converted, capacity, NULL, 0);
                if (samples > 0) av_audio_fifo_write(out->fifo, (void **)converted, samples);
                av_freep(&converted[0]);
                av_freep(&converted);
            }
        }
    }
    const int frameSize = encoder->frame_size > 0 ? encoder->frame_size : 1024;
    while (av_audio_fifo_size(out->fifo) >= frameSize
           || (final && av_audio_fifo_size(out->fifo) > 0)) {
        const int count = MIN(av_audio_fifo_size(out->fifo), frameSize);
        AVFrame *chunk = av_frame_alloc();
        if (!chunk) {
            if (error) *error = FFmpegMusicVideoError(AVERROR(ENOMEM), @"Allocating audio");
            return NO;
        }
        chunk->nb_samples = count;
        chunk->format = encoder->sample_fmt;
        chunk->sample_rate = encoder->sample_rate;
        av_channel_layout_copy(&chunk->ch_layout, &encoder->ch_layout);
        if (av_frame_get_buffer(chunk, 0) < 0) {
            av_frame_free(&chunk);
            if (error) *error = FFmpegMusicVideoError(AVERROR(ENOMEM), @"Allocating audio");
            return NO;
        }
        av_audio_fifo_read(out->fifo, (void **)chunk->data, count);
        chunk->pts = out->nextAudioPTS;
        out->nextAudioPTS += count;
        int result = avcodec_send_frame(encoder, chunk);
        av_frame_free(&chunk);
        if (result < 0 && result != AVERROR(EAGAIN)) {
            if (error) *error = FFmpegMusicVideoError(result, @"Encoding audio");
            return NO;
        }
        if (![self writeEncodedPacketsOf:out into:output packet:encoded error:error]) return NO;
    }
    return YES;
}

- (BOOL)writeEncodedPacketsOf:(FFmpegMusicVideoOutput *)out
                         into:(AVFormatContext *)output
                       packet:(AVPacket *)encoded
                        error:(NSError **)error {
    while (YES) {
        int result = avcodec_receive_packet(out->encoder, encoded);
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) return YES;
        if (result < 0) {
            if (error) *error = FFmpegMusicVideoError(result, @"Encoding");
            return NO;
        }
        av_packet_rescale_ts(encoded, out->encoder->time_base, out->output->time_base);
        encoded->stream_index = out->output->index;
        result = av_interleaved_write_frame(output, encoded);
        if (result < 0) {
            if (error) *error = FFmpegMusicVideoError(result, @"Writing MP4");
            return NO;
        }
    }
}

@end
