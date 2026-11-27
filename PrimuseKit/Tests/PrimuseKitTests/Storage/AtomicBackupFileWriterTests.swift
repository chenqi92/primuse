import Foundation
import Testing
@testable import PrimuseKit

@Suite("Atomic backup file writer")
struct AtomicBackupFileWriterTests {
    @Test("First write creates only the destination")
    func firstWrite() throws {
        try withURLs { directoryURL, destinationURL, backupURL in
            let payload = Data("first".utf8)

            try AtomicBackupFileWriter.write(
                payload,
                to: destinationURL,
                backupURL: backupURL
            )

            #expect(try Data(contentsOf: destinationURL) == payload)
            #expect(!FileManager.default.fileExists(atPath: backupURL.path))
            #expect(try replacementFiles(in: directoryURL).isEmpty)
        }
    }

    @Test("Replacement rotates the previous file instead of rewriting it")
    func rotatesPreviousFile() throws {
        try withURLs { directoryURL, destinationURL, backupURL in
            let previous = Data("previous".utf8)
            let replacement = Data("replacement".utf8)
            try previous.write(to: destinationURL)
            try Data("older backup".utf8).write(to: backupURL)
            let previousFileNumber = try #require(try fileNumber(at: destinationURL))

            try AtomicBackupFileWriter.write(
                replacement,
                to: destinationURL,
                backupURL: backupURL
            )

            #expect(try Data(contentsOf: destinationURL) == replacement)
            #expect(try Data(contentsOf: backupURL) == previous)
            let backupFileNumber = try #require(try fileNumber(at: backupURL))
            #expect(backupFileNumber == previousFileNumber)
            #expect(try replacementFiles(in: directoryURL).isEmpty)
        }
    }

    @Test("Replacement keeps the last valid backup when the destination is untrusted")
    func preservesBackupForUntrustedDestination() throws {
        try withURLs { directoryURL, destinationURL, backupURL in
            let previousBackup = Data("valid backup".utf8)
            let replacement = Data("replacement".utf8)
            try Data("corrupt destination".utf8).write(to: destinationURL)
            try previousBackup.write(to: backupURL)
            let previousBackupFileNumber = try #require(try fileNumber(at: backupURL))

            try AtomicBackupFileWriter.write(
                replacement,
                to: destinationURL,
                backupURL: backupURL,
                preserveExistingAsBackup: false
            )

            #expect(try Data(contentsOf: destinationURL) == replacement)
            #expect(try Data(contentsOf: backupURL) == previousBackup)
            let backupFileNumber = try #require(try fileNumber(at: backupURL))
            #expect(backupFileNumber == previousBackupFileNumber)
            #expect(try replacementFiles(in: directoryURL).isEmpty)
        }
    }

    private func withURLs(
        _ body: (URL, URL, URL) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "primuse-atomic-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        try body(
            directoryURL,
            directoryURL.appendingPathComponent("snapshot.json"),
            directoryURL.appendingPathComponent("snapshot.backup.json")
        )
    }

    private func fileNumber(at url: URL) throws -> NSNumber? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
    }

    private func replacementFiles(in directoryURL: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directoryURL.path).filter {
            $0.hasSuffix(".replacement")
        }
    }
}
