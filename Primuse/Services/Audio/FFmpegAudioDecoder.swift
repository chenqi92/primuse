import AVFoundation
import Foundation
import PrimuseKit

/// FFmpeg-based audio decoder for formats not natively supported by iOS
/// Requires FFmpeg-iOS package: https://github.com/kewlbear/FFmpeg-iOS
///
/// This decoder wraps the FFmpeg C API to decode:
/// APE, DSD (DSF/DFF), OGG Vorbis, Opus, WMA, WavPack
///
/// The implementation uses:
/// - avformat_open_input / avformat_find_stream_info for container parsing
/// - avcodec_find_decoder / avcodec_open2 for codec initialization
/// - av_read_frame / avcodec_send_packet / avcodec_receive_frame for decoding
/// - swr_alloc_set_opts2 / swr_convert for resampling to Float32 PCM
final class FFmpegAudioDecoder: PrimuseAudioDecoder {
    private let supportedExtensions: Set<String> = ["ape", "dsf", "dff", "ogg", "opus", "wma", "wv"]

    func canDecode(url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    func fileInfo(for url: URL) async throws -> AudioFileInfo {
        // Use FFmpeg to probe file info
        // This requires the FFmpeg C API bridge
        return try await probeFileInfo(url: url)
    }

    func decode(from url: URL, outputFormat: AVAudioFormat) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.decodeFile(url: url, outputFormat: outputFormat, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - FFmpeg C API Bridge

    /// Probes file metadata using FFmpeg
    /// Uses avformat_open_input + avformat_find_stream_info
    private func probeFileInfo(url: URL) async throws -> AudioFileInfo {
        // Bridge to FFmpeg C API
        // In production, this would call into the FFmpeg C functions via a bridging header
        //
        // Pseudocode:
        // var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
        // avformat_open_input(&fmtCtx, url.path, nil, nil)
        // avformat_find_stream_info(fmtCtx, nil)
        // let audioStreamIndex = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        // let codecParams = fmtCtx?.pointee.streams[audioStreamIndex]?.pointee.codecpar
        // let duration = Double(fmtCtx?.pointee.duration ?? 0) / Double(AV_TIME_BASE)
        // avformat_close_input(&fmtCtx)

        throw AudioDecoderError.unsupportedFormat(
            "FFmpeg bridge not yet compiled. Install FFmpeg-iOS package and add bridging header."
        )
    }

    /// Decodes audio file using FFmpeg and yields PCM buffers
    ///
    /// Pipeline:
    /// 1. avformat_open_input → open container
    /// 2. avformat_find_stream_info → detect streams
    /// 3. avcodec_find_decoder → find audio codec
    /// 4. avcodec_open2 → open codec
    /// 5. Decode loop: av_read_frame → avcodec_send_packet → avcodec_receive_frame
    /// 6. swr_convert → resample to output format (Float32 planar)
    /// 7. Pack into AVAudioPCMBuffer and yield
    private func decodeFile(
        url: URL,
        outputFormat: AVAudioFormat,
        continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation
    ) async throws {
        // This is the FFmpeg C API decode implementation
        // Requires a bridging header (Primuse-Bridging-Header.h) with:
        //
        // #include <libavformat/avformat.h>
        // #include <libavcodec/avcodec.h>
        // #include <libswresample/swresample.h>
        // #include <libavutil/opt.h>
        //
        // Full implementation outline:
        //
        // 1. Open input
        //    var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
        //    guard avformat_open_input(&fmtCtx, url.path, nil, nil) == 0 else { throw ... }
        //    defer { avformat_close_input(&fmtCtx) }
        //
        // 2. Find stream info
        //    guard avformat_find_stream_info(fmtCtx, nil) >= 0 else { throw ... }
        //
        // 3. Find audio stream
        //    var codecPtr: UnsafePointer<AVCodec>?
        //    let streamIdx = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_AUDIO, -1, -1, &codecPtr, 0)
        //    guard streamIdx >= 0, let codec = codecPtr else { throw ... }
        //
        // 4. Open codec
        //    let codecCtx = avcodec_alloc_context3(codec)
        //    defer { avcodec_free_context(&codecCtx) }
        //    avcodec_parameters_to_context(codecCtx, fmtCtx!.pointee.streams[streamIdx]!.pointee.codecpar)
        //    guard avcodec_open2(codecCtx, codec, nil) == 0 else { throw ... }
        //
        // 5. Setup resampler (SwrContext)
        //    let swrCtx = swr_alloc()
        //    defer { swr_free(&swrCtx) }
        //    // Set input options from codecCtx
        //    // Set output to Float32, outputFormat.sampleRate, outputFormat.channelCount
        //    swr_init(swrCtx)
        //
        // 6. Decode loop
        //    let packet = av_packet_alloc()
        //    let frame = av_frame_alloc()
        //    defer { av_packet_free(&packet); av_frame_free(&frame) }
        //
        //    while av_read_frame(fmtCtx, packet) >= 0 {
        //        guard packet.pointee.stream_index == streamIdx else { av_packet_unref(packet); continue }
        //        avcodec_send_packet(codecCtx, packet)
        //        while avcodec_receive_frame(codecCtx, frame) == 0 {
        //            // Resample frame to output format
        //            let outputSamples = swr_get_out_samples(swrCtx, frame.pointee.nb_samples)
        //            // Allocate AVAudioPCMBuffer
        //            // swr_convert(swrCtx, outputBufferPtrs, outputSamples, frame.pointee.data, frame.pointee.nb_samples)
        //            // Pack into AVAudioPCMBuffer and yield via continuation
        //        }
        //        av_packet_unref(packet)
        //    }
        //
        //    // Flush decoder
        //    avcodec_send_packet(codecCtx, nil)
        //    while avcodec_receive_frame(codecCtx, frame) == 0 { ... }

        continuation.finish(throwing: AudioDecoderError.unsupportedFormat(
            "FFmpeg bridge requires compilation. Add FFmpeg-iOS dependency and bridging header."
        ))
    }
}
