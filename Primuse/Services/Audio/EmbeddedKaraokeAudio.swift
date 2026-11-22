import Darwin
import Foundation

public enum EmbeddedKaraokeAudio {
    /// Audio ordinals count only audio streams. An empty selection retains the song timeline as silence.
    public static func render(from url: URL, audioOrdinals: [Int], to output: URL) async throws {
        try Task.checkCancellation()
        guard url.isFileURL, output.isFileURL, output.pathExtension.lowercased() == "caf",
              url.resolvingSymlinksInPath().standardizedFileURL != output.resolvingSymlinksInPath().standardizedFileURL else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard audioOrdinals.allSatisfy({ $0 >= 0 }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }

        let key = output.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(output.lastPathComponent).standardizedFileURL
        let job = RenderJob()
        renders.begin(job, at: key)
        try await withTaskCancellationHandler {
            try await Task.detached(priority: Task.currentPriority) {
                let directory = output.deletingLastPathComponent()
                let temporary = directory.appendingPathComponent(".\(UUID().uuidString).caf")
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    try? FileManager.default.removeItem(at: temporary)
                    renders.remove(job, at: key)
                }
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try job.bridge.render(source: url, audioOrdinals: audioOrdinals.map(NSNumber.init(value:)), to: temporary)
                    try renders.publish(job, at: key, from: temporary, to: output)
                } catch {
                    guard renders.owns(job, at: key) else { throw CancellationError() }
                    throw error
                }
            }.value
        } onCancel: {
            renders.remove(job, at: key)
            job.bridge.cancel()
        }
    }

    private static let renders = OutputWrites()

    // The decoder runs on a single worker. Only its atomic cancellation flag is accessed concurrently.
    private final class RenderJob: @unchecked Sendable {
        let bridge = FFmpegKaraokeRenderJob()
    }

    private final class OutputWrites: @unchecked Sendable {
        private let lock = NSLock()
        private var current: [URL: RenderJob] = [:]

        func begin(_ job: RenderJob, at key: URL) {
            let previous = lock.withLock { current.updateValue(job, forKey: key) }
            previous?.bridge.cancel()
        }

        func remove(_ job: RenderJob, at key: URL) {
            lock.withLock {
                if current[key] === job { current.removeValue(forKey: key) }
            }
        }

        func owns(_ job: RenderJob, at key: URL) -> Bool {
            lock.withLock { current[key] === job }
        }

        func publish(_ job: RenderJob, at key: URL, from temporary: URL, to destination: URL) throws {
            try lock.withLock {
                guard current[key] === job else { throw CancellationError() }
                let result = Darwin.rename((temporary as NSURL).fileSystemRepresentation,
                                           (destination as NSURL).fileSystemRepresentation)
                guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
        }
    }
}
