#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#import "../Primuse/Services/Audio/FFmpegDecoderBridge.h"

static BOOL BufferContainsSignal(AVAudioPCMBuffer *buffer) {
    if (!buffer || buffer.frameLength == 0 || !buffer.floatChannelData) return NO;
    const AVAudioFrameCount frames = MIN(buffer.frameLength, 4096);
    for (AVAudioChannelCount channel = 0; channel < buffer.format.channelCount; channel++) {
        const float *samples = buffer.floatChannelData[channel];
        for (AVAudioFrameCount frame = 0; frame < frames; frame++) {
            if (fabsf(samples[frame]) > 0.000001f) return YES;
        }
    }
    return NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: FFmpegBridgeSmoke audio-file [...]\n");
            return 64;
        }

        BOOL allPassed = YES;
        for (int index = 1; index < argc; index++) {
            NSString *path = [NSString stringWithUTF8String:argv[index]];
            NSURL *url = [NSURL fileURLWithPath:path];
            NSError *error = nil;
            FFmpegAudioFileInfo *probe = [FFmpegDecoderBridge probeURL:url error:&error];
            if (!probe) {
                fprintf(stderr, "FAIL probe %s: %s\n", argv[index], error.localizedDescription.UTF8String);
                allPassed = NO;
                continue;
            }
            if (!isfinite(probe.duration) || probe.duration <= 0) {
                fprintf(stderr, "FAIL metadata %s: codec=%s duration=%.6f\n",
                        argv[index], probe.codecName.UTF8String, probe.duration);
                allPassed = NO;
                continue;
            }

            FFmpegDecoderBridge *decoder = [[FFmpegDecoderBridge alloc] initWithURL:url error:&error];
            BOOL foundSignal = NO;
            NSInteger decodedFrames = 0;
            for (NSInteger attempt = 0; decoder && attempt < 64; attempt++) {
                FFmpegAudioReadResult *result = [decoder readNextBufferWithError:&error];
                if (!result || !result.buffer) break;
                decodedFrames += result.buffer.frameLength;
                foundSignal = foundSignal || BufferContainsSignal(result.buffer);
                if (foundSignal && decodedFrames >= 4096) break;
            }

            if (!decoder || error || decodedFrames == 0 || !foundSignal) {
                fprintf(stderr, "FAIL decode %s: codec=%s frames=%ld error=%s\n",
                        argv[index], probe.codecName.UTF8String, (long)decodedFrames,
                        error.localizedDescription.UTF8String ?: "none");
                allPassed = NO;
                continue;
            }

            printf("PASS %s codec=%s container=%s duration=%.6f sr=%.0f ch=%ld depth=%ld frames=%ld\n",
                   url.lastPathComponent.UTF8String,
                   probe.codecName.UTF8String,
                   probe.formatName.UTF8String,
                   probe.duration,
                   probe.sampleRate,
                   (long)probe.channelCount,
                   (long)probe.bitDepth,
                   (long)decodedFrames);
        }
        return allPassed ? 0 : 1;
    }
}
