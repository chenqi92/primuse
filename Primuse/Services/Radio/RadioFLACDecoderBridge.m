#import "RadioFLACDecoderBridge.h"

#import <FLAC/stream_decoder.h>
#include <math.h>
#include <stdatomic.h>
#include <string.h>

static NSString *const RadioFLACDecoderErrorDomain =
    @"com.welape.yuanyin.radio-flac-decoder";

static NSError *RadioFLACError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:RadioFLACDecoderErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation RadioFLACAudioReadResult
@end

@interface RadioFLACDecoderBridge ()
- (FLAC__StreamDecoderReadStatus)fillBytes:(FLAC__byte *)buffer
                                     count:(size_t *)count;
- (FLAC__StreamDecoderWriteStatus)receiveFrame:(const FLAC__Frame *)frame
                                       samples:(const FLAC__int32 *const[])samples;
- (void)receiveMetadata:(const FLAC__StreamMetadata *)metadata;
- (void)receiveDecoderError:(FLAC__StreamDecoderErrorStatus)status;
- (NSError *)terminalErrorWithOperation:(NSString *)operation;
@end

static FLAC__StreamDecoderReadStatus RadioFLACRead(
    const FLAC__StreamDecoder *decoder,
    FLAC__byte buffer[],
    size_t *bytes,
    void *clientData
) {
    RadioFLACDecoderBridge *bridge = (__bridge RadioFLACDecoderBridge *)clientData;
    return [bridge fillBytes:buffer count:bytes];
}

static FLAC__StreamDecoderWriteStatus RadioFLACWrite(
    const FLAC__StreamDecoder *decoder,
    const FLAC__Frame *frame,
    const FLAC__int32 *const buffer[],
    void *clientData
) {
    RadioFLACDecoderBridge *bridge = (__bridge RadioFLACDecoderBridge *)clientData;
    return [bridge receiveFrame:frame samples:buffer];
}

static void RadioFLACMetadata(
    const FLAC__StreamDecoder *decoder,
    const FLAC__StreamMetadata *metadata,
    void *clientData
) {
    RadioFLACDecoderBridge *bridge = (__bridge RadioFLACDecoderBridge *)clientData;
    [bridge receiveMetadata:metadata];
}

static void RadioFLACDecodeError(
    const FLAC__StreamDecoder *decoder,
    FLAC__StreamDecoderErrorStatus status,
    void *clientData
) {
    RadioFLACDecoderBridge *bridge = (__bridge RadioFLACDecoderBridge *)clientData;
    [bridge receiveDecoderError:status];
}

@implementation RadioFLACDecoderBridge {
    FLAC__StreamDecoder *_decoder;
    RadioFLACReadBlock _readBlock;
    AVAudioPCMBuffer *_pendingBuffer;
    NSError *_readError;
    NSError *_decoderError;
    atomic_bool _cancelled;
    double _sampleRate;
    NSInteger _channelCount;
    NSInteger _bitDepth;
}

- (instancetype)initWithOggContainer:(BOOL)oggContainer
                            readBlock:(RadioFLACReadBlock)readBlock
                                error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    atomic_init(&_cancelled, false);
    _readBlock = [readBlock copy];
    _decoder = FLAC__stream_decoder_new();
    if (!_decoder) {
        if (error) *error = RadioFLACError(1, @"Unable to allocate the FLAC decoder.");
        return nil;
    }

    FLAC__stream_decoder_set_md5_checking(_decoder, false);
    if (oggContainer) {
        // Radio servers may roll over to another Ogg logical stream without
        // closing the HTTP response.
        FLAC__stream_decoder_set_decode_chained_stream(_decoder, true);
    }

    FLAC__StreamDecoderInitStatus status = oggContainer
        ? FLAC__stream_decoder_init_ogg_stream(
            _decoder,
            RadioFLACRead,
            NULL,
            NULL,
            NULL,
            NULL,
            RadioFLACWrite,
            RadioFLACMetadata,
            RadioFLACDecodeError,
            (__bridge void *)self
        )
        : FLAC__stream_decoder_init_stream(
            _decoder,
            RadioFLACRead,
            NULL,
            NULL,
            NULL,
            NULL,
            RadioFLACWrite,
            RadioFLACMetadata,
            RadioFLACDecodeError,
            (__bridge void *)self
        );
    if (status != FLAC__STREAM_DECODER_INIT_STATUS_OK) {
        NSString *detail = [NSString stringWithUTF8String:
            FLAC__StreamDecoderInitStatusString[status]] ?: @"unknown error";
        if (error) {
            *error = RadioFLACError(
                status,
                [NSString stringWithFormat:@"Unable to initialize the FLAC stream: %@", detail]
            );
        }
        FLAC__stream_decoder_delete(_decoder);
        _decoder = NULL;
        return nil;
    }

    if (!FLAC__stream_decoder_process_until_end_of_metadata(_decoder)) {
        if (error) *error = [self terminalErrorWithOperation:@"Reading FLAC metadata"];
        FLAC__stream_decoder_finish(_decoder);
        FLAC__stream_decoder_delete(_decoder);
        _decoder = NULL;
        return nil;
    }
    _decoderError = nil;
    return self;
}

- (void)dealloc {
    if (_decoder) {
        FLAC__stream_decoder_finish(_decoder);
        FLAC__stream_decoder_delete(_decoder);
    }
}

- (double)sampleRate { return _sampleRate; }
- (NSInteger)channelCount { return _channelCount; }
- (NSInteger)bitDepth { return _bitDepth; }

- (RadioFLACAudioReadResult *)readNextBufferWithError:(NSError **)error {
    if (!_decoder) {
        if (error) *error = RadioFLACError(2, @"The FLAC decoder is not open.");
        return nil;
    }

    _pendingBuffer = nil;
    while (!_pendingBuffer) {
        if (atomic_load_explicit(&_cancelled, memory_order_acquire)) {
            if (error) {
                *error = [NSError errorWithDomain:NSURLErrorDomain
                                              code:NSURLErrorCancelled
                                          userInfo:nil];
            }
            return nil;
        }

        FLAC__StreamDecoderState state = FLAC__stream_decoder_get_state(_decoder);
        if (state == FLAC__STREAM_DECODER_END_OF_STREAM) {
            return [[RadioFLACAudioReadResult alloc] init];
        }

        if (!FLAC__stream_decoder_process_single(_decoder)) {
            if (error) *error = [self terminalErrorWithOperation:@"Decoding FLAC audio"];
            return nil;
        }
    }
    RadioFLACAudioReadResult *result = [[RadioFLACAudioReadResult alloc] init];
    result.buffer = _pendingBuffer;
    return result;
}

- (void)cancel {
    atomic_store_explicit(&_cancelled, true, memory_order_release);
}

- (FLAC__StreamDecoderReadStatus)fillBytes:(FLAC__byte *)buffer
                                     count:(size_t *)count {
    if (!count || *count == 0 || atomic_load_explicit(&_cancelled, memory_order_acquire)) {
        if (count) *count = 0;
        return FLAC__STREAM_DECODER_READ_STATUS_ABORT;
    }

    BOOL atEOF = NO;
    NSError *error = nil;
    NSInteger maximumLength = (NSInteger)MIN(*count, (size_t)NSIntegerMax);
    NSData *data = _readBlock(maximumLength, &atEOF, &error);
    if (!data) {
        _readError = error ?: RadioFLACError(3, @"Unable to read the radio stream.");
        *count = 0;
        return FLAC__STREAM_DECODER_READ_STATUS_ABORT;
    }

    size_t copied = MIN(*count, data.length);
    if (copied > 0) {
        memcpy(buffer, data.bytes, copied);
        *count = copied;
        return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE;
    }

    *count = 0;
    if (atEOF) return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM;
    _readError = RadioFLACError(4, @"The radio stream returned no audio data.");
    return FLAC__STREAM_DECODER_READ_STATUS_ABORT;
}

- (FLAC__StreamDecoderWriteStatus)receiveFrame:(const FLAC__Frame *)frame
                                       samples:(const FLAC__int32 *const[])samples {
    if (!frame || !samples || atomic_load_explicit(&_cancelled, memory_order_acquire)) {
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }

    const unsigned channels = frame->header.channels;
    const unsigned frameCount = frame->header.blocksize;
    const unsigned bitDepth = frame->header.bits_per_sample;
    const unsigned sampleRate = frame->header.sample_rate;
    if (channels == 0 || channels > 32 || frameCount == 0 ||
        bitDepth == 0 || bitDepth > 32 || sampleRate == 0) {
        _decoderError = RadioFLACError(5, @"The FLAC stream has an invalid audio format.");
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }

    AVAudioFormat *format = [[AVAudioFormat alloc]
        initStandardFormatWithSampleRate:sampleRate channels:(AVAudioChannelCount)channels];
    AVAudioPCMBuffer *buffer = format ? [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)frameCount] : nil;
    if (!buffer || !buffer.floatChannelData) {
        _decoderError = RadioFLACError(6, @"Unable to allocate a FLAC audio buffer.");
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }

    const float scale = ldexpf(1.0f, 1 - (int)bitDepth);
    for (unsigned channel = 0; channel < channels; channel++) {
        float *destination = buffer.floatChannelData[channel];
        const FLAC__int32 *source = samples[channel];
        for (unsigned frameIndex = 0; frameIndex < frameCount; frameIndex++) {
            destination[frameIndex] = (float)source[frameIndex] * scale;
        }
    }
    buffer.frameLength = (AVAudioFrameCount)frameCount;
    _sampleRate = sampleRate;
    _channelCount = channels;
    _bitDepth = bitDepth;
    _decoderError = nil;
    _pendingBuffer = buffer;
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

- (void)receiveMetadata:(const FLAC__StreamMetadata *)metadata {
    if (!metadata || metadata->type != FLAC__METADATA_TYPE_STREAMINFO) return;
    _sampleRate = metadata->data.stream_info.sample_rate;
    _channelCount = metadata->data.stream_info.channels;
    _bitDepth = metadata->data.stream_info.bits_per_sample;
}

- (void)receiveDecoderError:(FLAC__StreamDecoderErrorStatus)status {
    NSString *detail = [NSString stringWithUTF8String:
        FLAC__StreamDecoderErrorStatusString[status]] ?: @"unknown error";
    _decoderError = RadioFLACError(
        100 + status,
        [NSString stringWithFormat:@"FLAC stream error: %@", detail]
    );
}

- (NSError *)terminalErrorWithOperation:(NSString *)operation {
    if (_readError) return _readError;
    if (_decoderError) return _decoderError;
    const char *state = _decoder
        ? FLAC__stream_decoder_get_resolved_state_string(_decoder)
        : NULL;
    NSString *detail = state ? [NSString stringWithUTF8String:state] : @"unknown error";
    return RadioFLACError(
        7,
        [NSString stringWithFormat:@"%@: %@", operation, detail ?: @"unknown error"]
    );
}

@end
