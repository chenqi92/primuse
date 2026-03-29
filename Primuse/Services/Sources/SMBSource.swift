import Foundation
import AMSMB2
import PrimuseKit

actor SMBSource: MusicSourceConnector {
    let sourceID: String
    private let host: String
    private let port: Int
    private let sharePath: String
    private let username: String
    private let password: String
    private var client: SMB2Manager?
    private let cacheDirectory: URL

    init(sourceID: String, host: String, port: Int = 445, sharePath: String, username: String, password: String) {
        self.sourceID = sourceID
        self.host = host
        self.port = port
        self.sharePath = sharePath
        self.username = username
        self.password = password

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("primuse_smb_cache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    func connect() async throws {
        if client != nil {
            return
        }

        guard let serverURL = URL(string: "smb://\(host):\(port)") else {
            throw SourceError.connectionFailed("Invalid SMB URL")
        }

        let credential = URLCredential(
            user: username,
            password: password,
            persistence: .forSession
        )

        client = SMB2Manager(url: serverURL, credential: credential)

        // Test connection by listing shares
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client?.listShares { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: SourceError.connectionFailed(error.localizedDescription))
                }
            }
        }

        // Connect to the specific share
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client?.connectShare(name: sharePath) { error in
                if let error {
                    continuation.resume(throwing: SourceError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func disconnect() async {
        client?.disconnectShare { _ in }
        client = nil
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        guard let client else { throw SourceError.connectionFailed("Not connected") }

        return try await withCheckedThrowingContinuation { continuation in
            client.contentsOfDirectory(atPath: path) { result in
                switch result {
                case .success(let items):
                    let fileItems = items
                        .filter { ($0[.nameKey] as? String)?.hasPrefix(".") == false }
                        .map { item -> RemoteFileItem in
                            let name = item[.nameKey] as? String ?? ""
                            let isDir = (item[.fileResourceTypeKey] as? URLFileResourceType) == .directory
                            let size = item[.fileSizeKey] as? Int64 ?? 0
                            let modified = item[.contentModificationDateKey] as? Date

                            return RemoteFileItem(
                                name: name,
                                path: (path as NSString).appendingPathComponent(name),
                                isDirectory: isDir,
                                size: size,
                                modifiedDate: modified
                            )
                        }
                        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

                    continuation.resume(returning: fileItems)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func localURL(for path: String) async throws -> URL {
        guard let client else { throw SourceError.connectionFailed("Not connected") }

        let localURL = cacheDirectory.appendingPathComponent(
            path.replacingOccurrences(of: "/", with: "_")
        )

        // Check if already cached
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        // Download file
        return try await withCheckedThrowingContinuation { continuation in
            client.downloadItem(atPath: path, to: localURL) { bytesReceived, totalBytes -> Bool in
                return true // continue downloading
            } completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: localURL)
                }
            }
        }
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let localURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: localURL)
                    defer { handle.closeFile() }
                    let chunkSize = 64 * 1024
                    while true {
                        let data = handle.readData(ofLength: chunkSize)
                        if data.isEmpty { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await scanDirectory(path: path, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func scanDirectory(
        path: String,
        continuation: AsyncThrowingStream<RemoteFileItem, Error>.Continuation
    ) async throws {
        let items = try await listFiles(at: path)

        for item in items {
            if item.isDirectory {
                try await scanDirectory(path: item.path, continuation: continuation)
            } else {
                let ext = (item.name as NSString).pathExtension.lowercased()
                if PrimuseConstants.supportedAudioExtensions.contains(ext) {
                    continuation.yield(item)
                }
            }
        }
    }

    func writeFile(data: Data, to path: String) async throws {
        guard let client else { throw SourceError.connectionFailed("Not connected") }

        // Write data to temp file first
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smb_upload_\(UUID().uuidString)")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.uploadItem(at: tempURL, toPath: path, progress: { _ in return true }) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
