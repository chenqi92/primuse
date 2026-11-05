import Darwin
import Foundation

/// Downloads owns the files; cache paths are disposable compatibility links.
/// The private index uses an identity stored on each file so Files/Finder renames
/// and moves within Downloads do not change the corresponding library item.
public final class OfflineDownloadFileStore: NSObject, NSFilePresenter, @unchecked Sendable {
    public enum Kind: String, Codable, Sendable { case original, compact }

    private struct Artifact: Codable {
        var id: String
        var relativePath: String
        var hasDisplayName: Bool
    }

    private struct Index: Codable {
        var artifacts: [String: [String: Artifact]] = [:]
        var externallyRemoved: Set<String> = []
    }

    private struct Mutation: Codable {
        let path: String
        let artifacts: [String: Artifact]?
        let externallyRemoved: Bool
    }

    public let directory: URL
    private let indexURL: URL
    private let lock = NSLock()
    private var index = Index()
    private var loaded = false
    private var journalChanges = 0
    private var journalURL: URL { indexURL.appendingPathExtension("journal") }
    private var observer: (@Sendable () -> Void)?
    private var observing = false
    private static let identityAttribute = "com.welape.primuse.download-id"

    public var presentedItemURL: URL? { directory }
    public let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    public init(directory: URL, indexURL: URL) {
        self.directory = directory
        self.indexURL = indexURL
        super.init()
    }

    deinit {
        if observing { NSFileCoordinator.removeFilePresenter(self) }
    }

    public func startObserving(_ onChange: @escaping @Sendable () -> Void) {
        lock.lock()
        observer = onChange
        let shouldStart = !observing
        observing = true
        lock.unlock()
        if shouldStart { NSFileCoordinator.addFilePresenter(self) }
    }

    public func presentedSubitemDidChange(at url: URL) { notifyChange() }
    public func presentedItemDidChange() { notifyChange() }
    public func presentedItemDidMove(to newURL: URL) { notifyChange() }
    public func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { notifyChange() }
    public func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
        notifyChange()
    }
    public func accommodatePresentedSubitemDeletion(
        at url: URL, completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(nil)
        notifyChange()
    }

    private func notifyChange() {
        lock.lock()
        let callback = observer
        lock.unlock()
        callback?()
    }

    public func prepareDirectory() throws {
        try locked {
            try load()
            try prepare(directory)
        }
    }

    public func fileURL(for path: String, kind: Kind) -> URL? {
        try? locked {
            try load()
            guard let artifact = index.artifacts[path]?[kind.rawValue],
                  let url = safeURL(artifact.relativePath),
                  Self.isRegularFile(url) else { return nil }
            return url
        }
    }

    /// A missing managed file must not fall back to a stale cache link.
    public func manages(_ path: String) -> Bool {
        (try? locked {
            try load()
            return index.artifacts[path] != nil
        }) ?? true
    }

    public func wasExternallyRemoved(_ path: String) -> Bool {
        (try? locked {
            try load()
            return index.externallyRemoved.contains(path)
        }) ?? true
    }

    public func allowDownloadAgain(_ paths: [String]) throws {
        try locked {
            try load()
            let previous = index.externallyRemoved
            index.externallyRemoved.subtract(paths)
            if previous != index.externallyRemoved {
                try persist(paths: previous.subtracting(index.externallyRemoved))
            }
        }
    }

    /// Install a completed transfer or a legacy offline file without downloading
    /// it again. Hard links avoid a second allocation on the same volume.
    @discardableResult
    public func publish(
        _ source: URL, for path: String, kind: Kind, displayName: String? = nil
    ) throws -> URL {
        try locked {
            try load()
            guard Self.isRegularFile(source) else { throw CocoaError(.fileReadNoSuchFile) }
            try prepare(directory)
            var artifact = index.artifacts[path]?[kind.rawValue]
            if artifact == nil {
                let id = UUID().uuidString
                let relative = preferredPath(path, kind: kind, displayName: displayName)
                artifact = Artifact(id: id, relativePath: relative, hasDisplayName: displayName != nil)
            }
            guard var artifact, var destination = safeURL(artifact.relativePath) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            // Never replace an unrelated file placed in Downloads by the user.
            if FileManager.default.fileExists(atPath: destination.path),
               Self.identity(destination) != artifact.id,
               !Self.sameFile(source, destination) {
                artifact.relativePath = preferredPath(path, kind: kind, displayName: displayName,
                                                       disambiguator: artifact.id)
                guard let alternative = safeURL(artifact.relativePath) else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                destination = alternative
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
            }
            if !Self.sameFile(source, destination) {
                try prepare(destination.deletingLastPathComponent())
                let staging = destination.deletingLastPathComponent()
                    .appendingPathComponent(".download-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: staging) }
                do { try FileManager.default.linkItem(at: source, to: staging) }
                catch { try FileManager.default.copyItem(at: source, to: staging) }
                try Self.setIdentity(artifact.id, on: staging)
                try coordinateWrite(destination) { coordinated in
                    guard Darwin.rename(staging.path, coordinated.path) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            } else {
                try Self.setIdentity(artifact.id, on: destination)
            }
            index.artifacts[path, default: [:]][kind.rawValue] = artifact
            index.externallyRemoved.remove(path)
            try persist(paths: [path])
            return destination
        }
    }

    /// Name legacy files when the library metadata becomes available. Preserve
    /// names the user has already changed in Files/Finder.
    public func setDisplayName(_ name: String, for path: String) throws {
        try locked {
            try load()
            var changed = false
            for kind in [Kind.original, .compact] {
                guard var artifact = index.artifacts[path]?[kind.rawValue], !artifact.hasDisplayName,
                      let source = safeURL(artifact.relativePath), Self.isRegularFile(source),
                      let destination = safeURL(preferredPath(path, kind: kind, displayName: name)),
                      !FileManager.default.fileExists(atPath: destination.path) else { continue }
                try prepare(destination.deletingLastPathComponent())
                try coordinateWrite(source, options: .forMoving) { coordinated in
                    try FileManager.default.moveItem(at: coordinated, to: destination)
                }
                artifact.relativePath = relativePath(destination)!
                artifact.hasDisplayName = true
                index.artifacts[path]?[kind.rawValue] = artifact
                changed = true
            }
            if changed { try persist(paths: [path]) }
        }
    }

    /// Reconcile only when an indexed path disappeared. A rename is found by
    /// file identity; a deletion is retained as an explicit download exclusion.
    /// Returns paths whose cache aliases must be discarded or rebuilt.
    public func reconcile() throws -> Set<String> {
        try locked {
            try load()
            var missing: [(String, String, Artifact)] = []
            for (path, artifacts) in index.artifacts {
                for (kind, artifact) in artifacts {
                    guard let url = safeURL(artifact.relativePath) else {
                        throw CocoaError(.fileReadInvalidFileName)
                    }
                    if try !Self.regularFileIfPresent(url) {
                        missing.append((path, kind, artifact))
                    }
                }
            }
            guard !missing.isEmpty else { return [] }
            let wantedIDs = Set(missing.map { $0.2.id })
            var relocated: [String: String] = [:]
            var enumerationError: Error?
            if let files = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles], errorHandler: { _, error in
                    if !Self.isMissingFile(error) { enumerationError = error }
                    return false
                }
            ) {
                for case let file as URL in files where Self.isRegularFile(file) {
                    guard let id = Self.identity(file), wantedIDs.contains(id),
                          let relative = relativePath(file) else { continue }
                    relocated[id] = relative
                }
            }
            if let enumerationError { throw enumerationError }
            var changed = Set<String>()
            for (path, kind, previous) in missing {
                changed.insert(path)
                if let relative = relocated[previous.id] {
                    var artifact = previous
                    artifact.relativePath = relative
                    artifact.hasDisplayName = true
                    index.artifacts[path]?[kind] = artifact
                } else {
                    index.artifacts[path]?[kind] = nil
                    if index.artifacts[path]?.isEmpty == true {
                        index.artifacts[path] = nil
                        index.externallyRemoved.insert(path)
                    }
                }
            }
            try persist(paths: changed)
            return changed
        }
    }

    public func remove(_ path: String, kind: Kind? = nil, recordRemoval: Bool = false) throws {
        try locked {
            try load()
            let hadDownload = index.artifacts[path] != nil
            let kinds = kind.map { [$0.rawValue] } ?? index.artifacts[path].map { Array($0.keys) } ?? []
            for key in kinds {
                guard let artifact = index.artifacts[path]?[key] else { continue }
                if let url = safeURL(artifact.relativePath), FileManager.default.fileExists(atPath: url.path) {
                    try coordinateWrite(url, options: .forDeleting) { coordinated in
                        try FileManager.default.removeItem(at: coordinated)
                    }
                }
                index.artifacts[path]?[key] = nil
            }
            if index.artifacts[path]?.isEmpty == true { index.artifacts[path] = nil }
            if kind == nil {
                if recordRemoval {
                    if hadDownload { index.externallyRemoved.insert(path) }
                } else {
                    index.externallyRemoved.remove(path)
                }
            }
            try persist(paths: [path])
        }
    }

    public func paths() throws -> Set<String> {
        try locked { try load(); return Set(index.artifacts.keys) }
    }

    public func byteCount(for path: String) -> Int64 {
        [Kind.original, .compact].reduce(0) { total, kind in
            guard let url = fileURL(for: path, kind: kind),
                  let size = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
            else { return total }
            return total + Int64(size)
        }
    }

    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func load() throws {
        guard !loaded else { return }
        var restored = Index()
        var restoredChanges = 0
        if let data = try Self.dataIfPresent(indexURL) {
            restored = try JSONDecoder().decode(Index.self, from: data)
        }
        if let data = try Self.dataIfPresent(journalURL) {
            var validBytes = 0
            for line in data.split(separator: 10, omittingEmptySubsequences: false) {
                guard validBytes + line.count < data.count else { break }
                if !line.isEmpty {
                    let mutation = try JSONDecoder().decode(Mutation.self, from: Data(line))
                    restored.artifacts[mutation.path] = mutation.artifacts
                    if mutation.externallyRemoved { restored.externallyRemoved.insert(mutation.path) }
                    else { restored.externallyRemoved.remove(mutation.path) }
                    restoredChanges += 1
                }
                validBytes += line.count + 1
            }
            if validBytes < data.count {
                let file = try FileHandle(forWritingTo: journalURL)
                defer { try? file.close() }
                try file.truncate(atOffset: UInt64(validBytes))
            }
        }
        index = restored
        journalChanges = restoredChanges
        loaded = true
    }

    private static func dataIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch { if isMissingFile(error) { return nil }; throw error }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain
                && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    private func persist(paths: Set<String>) throws {
        guard !paths.isEmpty else { return }
        try prepare(indexURL.deletingLastPathComponent())
        var data = Data()
        for path in paths {
            data.append(try JSONEncoder().encode(Mutation(
                path: path, artifacts: index.artifacts[path],
                externallyRemoved: index.externallyRemoved.contains(path)
            )))
            data.append(10)
        }
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            guard FileManager.default.createFile(atPath: journalURL.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let file = try FileHandle(forWritingTo: journalURL)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: data)
        try file.synchronize()
        journalChanges += paths.count
        if journalChanges >= 256 {
            // Replaying the old journal after a crash here is idempotent.
            if let snapshot = try? JSONEncoder().encode(index),
               (try? snapshot.write(to: indexURL, options: .atomic)) != nil {
                try Data().write(to: journalURL, options: .atomic)
                journalChanges = 0
            }
        }
    }

    private func prepare(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var directory = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    private func preferredPath(
        _ path: String, kind: Kind, displayName: String?, disambiguator: String? = nil
    ) -> String {
        let file = URL(fileURLWithPath: path)
        let source = Self.safeName(path.split(separator: "/").first.map(String.init) ?? "Music", limit: 64)
        let key = file.deletingPathExtension().lastPathComponent
        let stem = Self.safeName(displayName ?? key, limit: 140)
        let suffix = disambiguator ?? String(key.prefix(12))
        let ext = kind == .compact ? "m4a" : Self.safeName(file.pathExtension, limit: 12)
        return "\(source)/\(stem) - \(suffix)\(kind == .compact ? " - AAC" : "").\(ext.isEmpty ? "audio" : ext)"
    }

    private static func safeName(_ name: String, limit: Int) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        let clean = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        // Bound UTF-8 bytes, not characters, to stay below filesystem limits.
        var result = ""
        for character in clean {
            guard result.utf8.count + String(character).utf8.count <= limit else { break }
            result.append(character)
        }
        return result.isEmpty ? "Audio" : result
    }

    private func safeURL(_ relative: String) -> URL? {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let url = directory.appendingPathComponent(relative)
        guard AudioCachePathResolver(root: directory).relativePath(for: url) == relative else { return nil }
        return url
    }

    private func relativePath(_ url: URL) -> String? {
        let root = directory.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return nil }
        return String(path.dropFirst(root.count))
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? regularFileIfPresent(url)) == true
    }

    private static func regularFileIfPresent(_ url: URL) throws -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
        } catch { if isMissingFile(error) { return false }; throw error }
    }

    private static func sameFile(_ first: URL, _ second: URL) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: first.path),
              let b = try? FileManager.default.attributesOfItem(atPath: second.path) else { return false }
        return a[.systemFileNumber] as? NSNumber == b[.systemFileNumber] as? NSNumber
            && a[.systemNumber] as? NSNumber == b[.systemNumber] as? NSNumber
    }

    private static func identity(_ url: URL) -> String? {
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = getxattr(url.path, identityAttribute, &bytes, bytes.count, 0, 0)
        return count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : nil
    }

    private static func setIdentity(_ id: String, on url: URL) throws {
        let result = Array(id.utf8).withUnsafeBytes { bytes in
            setxattr(url.path, identityAttribute, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func coordinateWrite(
        _ url: URL, options: NSFileCoordinator.WritingOptions = .forReplacing,
        operation: (URL) throws -> Void
    ) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator(filePresenter: self).coordinate(writingItemAt: url, options: options,
                                                         error: &coordinationError) { coordinated in
            do { try operation(coordinated) } catch { operationError = error }
        }
        if let error = coordinationError ?? operationError as NSError? { throw error }
    }
}
