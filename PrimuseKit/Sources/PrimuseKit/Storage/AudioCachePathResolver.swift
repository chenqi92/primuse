import Foundation

public struct AudioCachePathResolver: Sendable {
    private let rootPrefix: String

    public init(root: URL) {
        let path = Self.canonicalPath(for: root)
        rootPrefix = path.hasSuffix("/") ? path : path + "/"
    }

    public func relativePath(for file: URL) -> String? {
        guard file.isFileURL else { return nil }
        let path = Self.canonicalPath(for: file)
        guard path.hasPrefix(rootPrefix) else { return nil }
        let relative = String(path.dropFirst(rootPrefix.count))
        return relative.isEmpty ? nil : relative
    }

    private static func canonicalPath(for file: URL) -> String {
        // Foundation leaves a missing descendant unchanged, including its
        // /private prefix. Streaming paths must also match before creation.
        var ancestor = file
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            missingComponents.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }
}
