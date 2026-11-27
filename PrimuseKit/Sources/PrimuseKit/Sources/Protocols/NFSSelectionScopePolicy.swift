import Foundation

public struct NFSScopedSelection: Equatable, Sendable {
    public let exportPath: String
    public let relativePath: String

    public init(exportPath: String, relativePath: String) {
        self.exportPath = exportPath
        self.relativePath = relativePath
    }
}

/// Validates the decoded parts of an NFS selection path before a client mounts
/// an export. A configured source is confined to that exact export; all sources
/// reject parent components in both the export identity and relative file path.
public enum NFSSelectionScopePolicy {
    public static func resolve(
        exportPath: String,
        relativePath: String,
        configuredExportPath: String?
    ) -> NFSScopedSelection? {
        let exportScope = RemotePathScopePolicy(rootPath: exportPath)
        guard exportScope.matchesRoot(exportPath),
              let scopedRelativePath = RemotePathScopePolicy(rootPath: "/")
                .resolvedPath(forStoredPath: relativePath) else {
            return nil
        }

        if let configuredExportPath {
            let configured = configuredExportPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !configured.isEmpty {
                let configuredScope = RemotePathScopePolicy(rootPath: configured)
                guard configuredScope.matchesRoot(configured),
                      configuredScope.matchesRoot(exportScope.rootPath) else {
                    return nil
                }
            }
        }

        return NFSScopedSelection(
            exportPath: exportScope.rootPath,
            relativePath: scopedRelativePath
        )
    }
}
