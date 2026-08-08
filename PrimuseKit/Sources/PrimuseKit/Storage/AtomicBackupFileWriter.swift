import Foundation

public enum AtomicBackupFileWriter {
    /// Writes the new payload once and atomically replaces the destination.
    /// A trusted previous destination can be retained as the backup without
    /// rewriting its contents.
    public static func write(
        _ data: Data,
        to destinationURL: URL,
        backupURL: URL,
        preserveExistingAsBackup: Bool = true
    ) throws {
        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent().standardizedFileURL
        guard backupURL.deletingLastPathComponent().standardizedFileURL == directoryURL else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let replacementURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).replacement"
        )
        defer { try? fileManager.removeItem(at: replacementURL) }

        try data.write(to: replacementURL, options: .atomic)
        if fileManager.fileExists(atPath: destinationURL.path) {
            if preserveExistingAsBackup {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: replacementURL,
                    backupItemName: backupURL.lastPathComponent,
                    options: [.withoutDeletingBackupItem]
                )
            } else {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: replacementURL
                )
            }
        } else {
            try fileManager.moveItem(at: replacementURL, to: destinationURL)
        }
    }
}
