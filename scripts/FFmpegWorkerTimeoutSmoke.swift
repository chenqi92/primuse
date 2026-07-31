import AVFoundation
import Darwin
import Foundation

enum AudioDecoderError: Error {
    case bufferAllocationFailed
    case converterCreationFailed
    case decodingFailed(String)
}

func plog(_ message: String, file: String = #file, line: Int = #line) {
    print("\(message) [\((file as NSString).lastPathComponent):\(line)]")
}

@main
struct FFmpegWorkerTimeoutSmoke {
    private static let expectedTimeoutRange = 14.5...17.5

    private struct ProcessMetrics {
        let threads: Int
        let fileDescriptors: Int
        let residentBytes: Int64
    }

    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        guard CommandLine.arguments.count == 7 else {
            fputs(
                "usage: FFmpegWorkerTimeoutSmoke timeout-fifo cancel-fifo probe-fifo "
                    + "queue-a-fifo queue-b-fifo valid-audio\n",
                stderr
            )
            exit(64)
        }

        let stalledURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let cancelledURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let probeURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let queuedAURL = URL(fileURLWithPath: CommandLine.arguments[4])
        let queuedBURL = URL(fileURLWithPath: CommandLine.arguments[5])
        let validURL = URL(fileURLWithPath: CommandLine.arguments[6])
        let writer = startStalledWriter(path: stalledURL.path, holdMicroseconds: 18_000_000)
        let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        )!

        let firstStart = Date()
        let firstError = await nextResult(
            decoder: FFmpegAudioDecoder(),
            url: stalledURL,
            outputFormat: outputFormat
        ).error
        let firstElapsed = Date().timeIntervalSince(firstStart)
        guard let firstURLError = firstError as? URLError,
              firstURLError.code == .timedOut,
              expectedTimeoutRange.contains(firstElapsed) else {
            fputs(
                "FAIL worker deadline elapsed=\(String(format: "%.3f", firstElapsed)) "
                    + "error=\(String(describing: firstError))\n",
                stderr
            )
            exit(1)
        }

        let metricsBeforeRetries = processMetrics()
        let retriesStart = Date()
        for attempt in 1...20 {
            let result = await nextResult(
                decoder: FFmpegAudioDecoder(),
                url: stalledURL,
                outputFormat: outputFormat
            )
            guard result.error != nil else {
                fputs("FAIL circuit retry \(attempt) unexpectedly decoded audio\n", stderr)
                exit(1)
            }
        }
        let retriesElapsed = Date().timeIntervalSince(retriesStart)
        guard retriesElapsed < 1 else {
            fputs(
                "FAIL circuit retries took \(String(format: "%.3f", retriesElapsed))s\n",
                stderr
            )
            exit(1)
        }
        try? await Task.sleep(for: .milliseconds(200))
        let metricsAfterRetries = processMetrics()
        let threadGrowth = metricsAfterRetries.threads - metricsBeforeRetries.threads
        let descriptorGrowth = metricsAfterRetries.fileDescriptors
            - metricsBeforeRetries.fileDescriptors
        let residentGrowth = metricsAfterRetries.residentBytes
            - metricsBeforeRetries.residentBytes
        guard threadGrowth <= 2,
              descriptorGrowth <= 2,
              residentGrowth <= 8 * 1_048_576 else {
            fputs(
                "FAIL circuit resource growth threads=\(threadGrowth) "
                    + "fds=\(descriptorGrowth) rss=\(residentGrowth)\n",
                stderr
            )
            exit(1)
        }

        await wait(for: writer)
        try? await Task.sleep(for: .milliseconds(250))
        let recovery = await nextResult(
            decoder: FFmpegAudioDecoder(),
            url: validURL,
            outputFormat: outputFormat
        )
        guard recovery.buffer?.frameLength ?? 0 > 0, recovery.error == nil else {
            fputs("FAIL circuit did not recover: \(String(describing: recovery.error))\n", stderr)
            exit(1)
        }
        try? await Task.sleep(for: .milliseconds(250))

        // A healthy request queued behind a long-but-cooperative operation
        // must receive a fresh execution budget once it actually owns the
        // lane. The second FIFO waits three more seconds before supplying a
        // valid DTS payload, so the total wall time exceeds the original
        // 16-second registration deadline while its execution time does not.
        let queuedAWriter = startStalledWriter(
            path: queuedAURL.path,
            holdMicroseconds: 14_000_000
        )
        let queuedATask = Task {
            await nextResult(
                decoder: FFmpegAudioDecoder(),
                url: queuedAURL,
                outputFormat: outputFormat
            )
        }
        try? await Task.sleep(for: .milliseconds(250))
        let queuedBWriter = startDelayedFileWriter(
            path: queuedBURL.path,
            sourceURL: validURL,
            delayMicroseconds: 3_000_000
        )
        let queuedStart = Date()
        let queuedBResult = await nextResult(
            decoder: FFmpegAudioDecoder(),
            url: queuedBURL,
            outputFormat: outputFormat
        )
        let queuedElapsed = Date().timeIntervalSince(queuedStart)
        let queuedAResult = await queuedATask.value
        await wait(for: queuedAWriter)
        await wait(for: queuedBWriter)
        guard queuedAResult.error != nil,
              queuedBResult.error == nil,
              queuedBResult.buffer?.frameLength ?? 0 > 0,
              (15.5...20.5).contains(queuedElapsed) else {
            fputs(
                "FAIL queued execution budget elapsed=\(String(format: "%.3f", queuedElapsed)) "
                    + "aError=\(String(describing: queuedAResult.error)) "
                    + "bError=\(String(describing: queuedBResult.error))\n",
                stderr
            )
            exit(1)
        }

        // Cancellation must open the same circuit as the watchdog when the
        // operation has already entered a vnode call. Later playback requests
        // should fail immediately until that worker really returns.
        let cancelledWriter = startStalledWriter(
            path: cancelledURL.path,
            holdMicroseconds: 2_000_000
        )
        let cancelledTask = Task {
            await nextResult(
                decoder: FFmpegAudioDecoder(),
                url: cancelledURL,
                outputFormat: outputFormat
            )
        }
        try? await Task.sleep(for: .milliseconds(250))
        let cancellationStart = Date()
        cancelledTask.cancel()
        let cancelledResult = await cancelledTask.value
        let cancellationElapsed = Date().timeIntervalSince(cancellationStart)
        guard cancelledResult.buffer == nil, cancellationElapsed < 1 else {
            fputs(
                "FAIL active cancellation elapsed=\(String(format: "%.3f", cancellationElapsed)) "
                    + "error=\(String(describing: cancelledResult.error))\n",
                stderr
            )
            exit(1)
        }
        let cancelledRetryStart = Date()
        let cancelledRetry = await nextResult(
            decoder: FFmpegAudioDecoder(),
            url: cancelledURL,
            outputFormat: outputFormat
        )
        let cancelledRetryElapsed = Date().timeIntervalSince(cancelledRetryStart)
        guard cancelledRetry.error != nil, cancelledRetryElapsed < 1 else {
            fputs("FAIL cancellation circuit did not reject retry immediately\n", stderr)
            exit(1)
        }
        await wait(for: cancelledWriter)
        try? await Task.sleep(for: .milliseconds(250))

        // A stuck optional metadata probe has its own bounded lane and must not
        // delay realtime playback reads.
        let probeWriter = startStalledWriter(
            path: probeURL.path,
            holdMicroseconds: 2_000_000
        )
        let probeTask = Task {
            try? await FFmpegAudioDecoder().fileInfo(for: probeURL)
        }
        try? await Task.sleep(for: .milliseconds(250))
        probeTask.cancel()
        let isolatedPlaybackStart = Date()
        let isolatedPlayback = await nextResult(
            decoder: FFmpegAudioDecoder(),
            url: validURL,
            outputFormat: outputFormat
        )
        let isolatedPlaybackElapsed = Date().timeIntervalSince(isolatedPlaybackStart)
        guard isolatedPlayback.buffer?.frameLength ?? 0 > 0,
              isolatedPlayback.error == nil,
              isolatedPlaybackElapsed < 1 else {
            fputs(
                "FAIL probe lane blocked playback elapsed=\(String(format: "%.3f", isolatedPlaybackElapsed))\n",
                stderr
            )
            exit(1)
        }
        _ = await probeTask.value
        await wait(for: probeWriter)
        // The probe initializer opens a WAV twice (prefix sniff, then demuxer).
        // Pair the second FIFO open so the intentionally empty fixture can
        // unwind and demonstrate that the circuit closes when the worker does.
        let probeUnblockWriter = startStalledWriter(
            path: probeURL.path,
            holdMicroseconds: 200_000
        )
        await wait(for: probeUnblockWriter)
        try? await Task.sleep(for: .milliseconds(250))
        let probeRecoveryDeadline = Date().addingTimeInterval(3)
        var probeRecoveryError: Error?
        while Date() < probeRecoveryDeadline {
            do {
                _ = try await FFmpegAudioDecoder().fileInfo(for: validURL)
                probeRecoveryError = nil
                break
            } catch {
                probeRecoveryError = error
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if let probeRecoveryError {
            fputs("FAIL probe circuit did not recover: \(probeRecoveryError)\n", stderr)
            exit(1)
        }

        print(
            "PASS FFmpeg worker timeout=\(String(format: "%.3f", firstElapsed))s "
                + "retries=20/\(String(format: "%.3f", retriesElapsed))s "
                + "threadDelta=\(threadGrowth) fdDelta=\(descriptorGrowth) "
                + "rssDelta=\(residentGrowth) cancelled=\(String(format: "%.3f", cancellationElapsed))s "
                + "queuedBudget=\(String(format: "%.3f", queuedElapsed))s "
                + "probeIsolation=\(String(format: "%.3f", isolatedPlaybackElapsed))s recovered=yes"
        )
    }

    private static func nextResult(
        decoder: FFmpegAudioDecoder,
        url: URL,
        outputFormat: AVAudioFormat
    ) async -> (buffer: AVAudioPCMBuffer?, error: Error?) {
        var iterator = decoder.decode(from: url, outputFormat: outputFormat).makeAsyncIterator()
        do {
            return (try await iterator.next(), nil)
        } catch {
            return (nil, error)
        }
    }

    private static func startStalledWriter(
        path: String,
        holdMicroseconds: useconds_t
    ) -> DispatchGroup {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let descriptor = open(path, O_WRONLY)
            if descriptor >= 0 {
                usleep(holdMicroseconds)
                close(descriptor)
            }
            group.leave()
        }
        return group
    }

    private static func startDelayedFileWriter(
        path: String,
        sourceURL: URL,
        delayMicroseconds: useconds_t
    ) -> DispatchGroup {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let descriptor = open(path, O_WRONLY)
            if descriptor >= 0 {
                usleep(delayMicroseconds)
                if let data = try? Data(contentsOf: sourceURL) {
                    data.withUnsafeBytes { bytes in
                        guard let baseAddress = bytes.baseAddress else { return }
                        var offset = 0
                        while offset < bytes.count {
                            let count = Darwin.write(
                                descriptor,
                                baseAddress.advanced(by: offset),
                                bytes.count - offset
                            )
                            guard count > 0 else { break }
                            offset += count
                        }
                    }
                }
                close(descriptor)
            }
            group.leave()
        }
        return group
    }

    private static func wait(for group: DispatchGroup) async {
        await withCheckedContinuation { continuation in
            group.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume()
            }
        }
    }

    private static func processMetrics() -> ProcessMetrics {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        let threadResult = task_threads(mach_task_self_, &threadList, &threadCount)
        if let threadList {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threadList)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            )
        }

        var taskInfo = mach_task_basic_info()
        var taskInfoCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let taskResult = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(taskInfoCount)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &taskInfoCount
                )
            }
        }

        let descriptors = (
            try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        ) ?? 0
        return ProcessMetrics(
            threads: threadResult == KERN_SUCCESS ? Int(threadCount) : 0,
            fileDescriptors: descriptors,
            residentBytes: taskResult == KERN_SUCCESS ? Int64(taskInfo.resident_size) : 0
        )
    }
}
