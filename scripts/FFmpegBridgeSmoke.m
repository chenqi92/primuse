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

            if ([url.pathExtension.lowercaseString isEqualToString:@"wav"]) {
                NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:&error];
                NSData *prefix = [handle readDataUpToLength:256 * 1024 error:&error];
                [handle closeFile];
                BOOL detectedDTS = prefix && [FFmpegDecoderBridge dataContainsDTSSync:prefix];
                BOOL decodedAsDTS = [probe.codecName.lowercaseString containsString:@"dts"];
                if (error || detectedDTS != decodedAsDTS) {
                    fprintf(stderr, "FAIL WAV content routing %s: detectedDTS=%s codec=%s error=%s\n",
                            argv[index], detectedDTS ? "yes" : "no",
                            probe.codecName.UTF8String,
                            error.localizedDescription.UTF8String ?: "none");
                    allPassed = NO;
                    continue;
                }
            }

            FFmpegDecoderBridge *decoder = [[FFmpegDecoderBridge alloc] initWithURL:url error:&error];
            BOOL foundSignal = NO;
            BOOL reachedEnd = NO;
            NSInteger decodedFrames = 0;
            AVAudioChannelCount decodedChannels = 0;
            for (NSInteger attempt = 0; decoder && attempt < 500000; attempt++) {
                FFmpegAudioReadResult *result = [decoder readNextBufferWithError:&error];
                if (!result || !result.buffer) {
                    reachedEnd = result != nil && error == nil;
                    break;
                }
                if (decodedChannels == 0) decodedChannels = result.buffer.format.channelCount;
                decodedFrames += result.buffer.frameLength;
                foundSignal = foundSignal || BufferContainsSignal(result.buffer);
            }

            if (!decoder || error || !reachedEnd || decodedFrames == 0 || !foundSignal) {
                fprintf(stderr, "FAIL decode %s: codec=%s frames=%ld eof=%s error=%s\n",
                        argv[index], probe.codecName.UTF8String, (long)decodedFrames,
                        reachedEnd ? "yes" : "no",
                        error.localizedDescription.UTF8String ?: "none");
                allPassed = NO;
                continue;
            }
            if (probe.channelCount > 2 && decodedChannels != 2) {
                fprintf(stderr, "FAIL downmix %s: sourceChannels=%ld decodedChannels=%u\n",
                        argv[index], (long)probe.channelCount, decodedChannels);
                allPassed = NO;
                continue;
            }

            printf("PASS %s codec=%s container=%s duration=%.6f sr=%.0f srcCh=%ld outCh=%u depth=%ld frames=%ld\n",
                   url.lastPathComponent.UTF8String,
                   probe.codecName.UTF8String,
                   probe.formatName.UTF8String,
                   probe.duration,
                   probe.sampleRate,
                   (long)probe.channelCount,
                   decodedChannels,
                   (long)probe.bitDepth,
                   (long)decodedFrames);
        }
        return allPassed ? 0 : 1;
    }
}
