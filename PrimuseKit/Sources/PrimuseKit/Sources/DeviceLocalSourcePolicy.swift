import Foundation

public enum DeviceLocalSourceRemovalPolicy: Equatable, Sendable {
    case preserveReferencedFiles
    case deleteManagedCopies
}

public enum DeviceLocalSourcePolicy {
    /// Only the dedicated iOS import source is guaranteed to live in the app
    /// sandbox. Other `.local` sources may be security-scoped File Provider
    /// references and can require network materialization.
    public static func removalPolicy(
        isLocalSource: Bool,
        sourceID: String,
        persistedImportSourceID: String?,
        basePath: String?,
        managedRootPath: String
    ) -> DeviceLocalSourceRemovalPolicy {
        guard isLocalSource,
              sourceID == persistedImportSourceID,
              let basePath else {
            return .preserveReferencedFiles
        }
        let sourceRoot = normalizedRoot(basePath)
        let managedRoot = normalizedRoot(managedRootPath)
        let matchesCurrentContainer = sourceRoot == managedRoot
            || (containerParent(sourceRoot) != nil
                && containerParent(sourceRoot) == containerParent(managedRoot))
        return matchesCurrentContainer
            ? .deleteManagedCopies
            : .preserveReferencedFiles
    }

    private static func normalizedRoot(_ path: String) -> String {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    private static func containerParent(_ path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 6,
              Array(components.suffix(2)) == ["Documents", "LocalMusic"],
              UUID(uuidString: components[components.count - 3]) != nil,
              Array(components.suffix(6).prefix(3)) == ["Containers", "Data", "Application"] else {
            return nil
        }
        // An app update may replace only the data-container UUID. Matching the
        // complete parent keeps other devices and File Provider roots distinct.
        return components.dropLast(3).joined(separator: "/")
    }

    public static func isManagedCopy(
        isLocalSource: Bool,
        sourceID: String,
        persistedImportSourceID: String?,
        basePath: String?,
        managedRootPath: String
    ) -> Bool {
        removalPolicy(
            isLocalSource: isLocalSource,
            sourceID: sourceID,
            persistedImportSourceID: persistedImportSourceID,
            basePath: basePath,
            managedRootPath: managedRootPath
        ) == .deleteManagedCopies
    }
}
