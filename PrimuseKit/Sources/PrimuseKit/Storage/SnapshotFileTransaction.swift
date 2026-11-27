import Foundation

/// A rollback journal keeps a multi-file snapshot recoverable if a write fails
/// or the process exits between individual atomic replacements.
public struct SnapshotFileTransaction {
    private struct Entry: Codable {
        let destination: URL
        let backupName: String?
    }
    private struct Journal: Codable { let entries: [Entry] }
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func recover() throws {
        let fm = FileManager.default
        let journalURL = directory.appendingPathComponent("journal.json")
        guard fm.fileExists(atPath: journalURL.path) else { return }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        if !fm.fileExists(atPath: directory.appendingPathComponent("committed").path) {
            for entry in journal.entries {
                if let backup = entry.backupName {
                    try Data(contentsOf: directory.appendingPathComponent(backup))
                        .write(to: entry.destination, options: .atomic)
                } else if fm.fileExists(atPath: entry.destination.path) {
                    try fm.removeItem(at: entry.destination)
                }
            }
        }
        try fm.removeItem(at: directory)
    }

    public func apply(_ files: [URL: Data], writer: (Data, URL) throws -> Void = {
        try $0.write(to: $1, options: .atomic)
    }) throws {
        try recover()
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries: [Entry] = []
        let ordered = files.keys.sorted { $0.path < $1.path }
        for (index, destination) in ordered.enumerated() {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let backup = fm.fileExists(atPath: destination.path) ? "backup-\(index)" : nil
            if let backup {
                try fm.copyItem(at: destination, to: directory.appendingPathComponent(backup))
            }
            entries.append(Entry(destination: destination, backupName: backup))
        }
        try JSONEncoder().encode(Journal(entries: entries))
            .write(to: directory.appendingPathComponent("journal.json"), options: .atomic)
        do {
            for destination in ordered {
                try writer(files[destination]!, destination)
            }
            try Data().write(to: directory.appendingPathComponent("committed"), options: .atomic)
        } catch {
            try recover()
            throw error
        }
        // A committed journal can be cleaned at the next launch as well; a
        // cleanup error must not turn a successfully installed snapshot into a retry.
        try? recover()
    }
}
