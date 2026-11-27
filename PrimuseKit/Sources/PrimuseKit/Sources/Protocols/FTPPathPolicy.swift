import Foundation

/// Keeps the app-facing FTP namespace relative to the configured source root.
/// The connection URL always names the server root and every FTP command gets
/// an absolute server path, so `basePath` is applied here exactly once instead
/// of producing `/base/base/...` commands.
public struct FTPPathPolicy: Equatable, Sendable {
    public static let providerBaseURLPath = "/"

    public let basePath: String

    public init(basePath: String?) {
        self.basePath = Self.normalizeAbsolutePath(basePath ?? "/")
    }

    /// Converts a source-relative browser/song path to the absolute server path
    /// passed to every FTP command.
    public func providerPath(forSourcePath sourcePath: String) -> String {
        let sourcePath = Self.normalizeAbsolutePath(sourcePath)
        guard basePath != "/" else { return sourcePath }
        guard sourcePath != "/" else { return basePath }
        return basePath + sourcePath
    }

    /// Converts an FTP listing path back to the source-relative path
    /// persisted by selected directories and songs. Out-of-root results are
    /// rejected instead of escaping the configured source scope.
    public func sourcePath(forProviderPath providerPath: String) -> String? {
        let providerPath = Self.normalizeAbsolutePath(providerPath)
        guard basePath != "/" else { return providerPath }
        if providerPath == basePath { return "/" }
        guard providerPath.hasPrefix(basePath + "/") else { return nil }
        return String(providerPath.dropFirst(basePath.count))
    }

    private static func normalizeAbsolutePath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        let absolutePath = path.hasPrefix("/") ? path : "/\(path)"
        var normalized = (absolutePath as NSString).standardizingPath
        if normalized.isEmpty || normalized == "." { return "/" }
        if !normalized.hasPrefix("/") { normalized = "/\(normalized)" }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
