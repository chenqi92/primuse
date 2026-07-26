import Foundation

/// Decodes and validates the synchronous `xpan/filemanager` response.
///
/// Baidu reports two levels of status: the top-level `errno` and one
/// `info[]` entry per requested path. A zero top-level status does not mean
/// every file operation succeeded, so callers must validate both levels.
public struct BaiduFileManagerBatchResponse: Decodable, Sendable, Equatable {
    public struct Item: Decodable, Sendable, Equatable {
        public let errno: Int
        public let path: String

        public init(errno: Int, path: String) {
            self.errno = errno
            self.path = path
        }
    }

    public enum ValidationError: Error, Sendable, Equatable, LocalizedError {
        case topLevel(Int)
        case missingItemResults
        case failedItems([Item])
        case missingPaths([String])

        public var errorDescription: String? {
            switch self {
            case .topLevel(let errno):
                return "Baidu filemanager failed with errno \(errno)"
            case .missingItemResults:
                return "Baidu filemanager returned no per-item results"
            case .failedItems(let items):
                let first = items.first
                return "Baidu filemanager failed \(items.count) item(s)"
                    + (first.map { ": \($0.path) (errno \($0.errno))" } ?? "")
            case .missingPaths(let paths):
                return "Baidu filemanager omitted \(paths.count) requested path(s)"
            }
        }
    }

    public let errno: Int
    public let info: [Item]?

    public init(errno: Int, info: [Item]?) {
        self.errno = errno
        self.info = info
    }

    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    /// Validate a synchronous response against the exact batch submitted.
    /// Extra provider rows are harmless, but every requested path must have a
    /// successful item result before the app removes it from the local library.
    public func validate(expectedPaths: [String]) throws {
        guard errno == 0 else { throw ValidationError.topLevel(errno) }
        guard let info else { throw ValidationError.missingItemResults }

        let failed = info.filter { $0.errno != 0 }
        guard failed.isEmpty else { throw ValidationError.failedItems(failed) }

        let reportedPaths = Set(info.map(\.path))
        let missing = Array(Set(expectedPaths).subtracting(reportedPaths)).sorted()
        guard missing.isEmpty else { throw ValidationError.missingPaths(missing) }
    }
}
