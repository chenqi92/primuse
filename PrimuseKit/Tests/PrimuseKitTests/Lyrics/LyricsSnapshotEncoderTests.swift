import Foundation
import Testing
@testable import PrimuseKit

@Test func lyricsSnapshotEncoderProducesCompatibleBoundedJSON() throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }

    let firstName = "0123456789abcdef0123456789abcdef.json"
    let secondName = "fedcba9876543210fedcba9876543210.json"
    let first = Data("first lyric".utf8)
    let second = Data("second lyric".utf8)
    try first.write(to: directory.appendingPathComponent(firstName))
    try second.write(to: directory.appendingPathComponent(secondName))
    try Data("ignored".utf8).write(to: directory.appendingPathComponent("unsafe.json"))

    let result = try #require(
        LyricsSnapshotEncoder.encodeDirectory(
            directory,
            maximumOutputBytes: 4_096,
            maximumFileBytes: 1_024,
            fileManager: fm
        )
    )
    let decoded = try JSONDecoder().decode([String: String].self, from: result.data)

    #expect(result.data.count <= 4_096)
    #expect(result.fileCount == 2)
    #expect(result.skippedFileCount == 1)
    #expect(result.isTruncated == false)
    #expect(decoded[firstName].flatMap { Data(base64Encoded: $0) } == first)
    #expect(decoded[secondName].flatMap { Data(base64Encoded: $0) } == second)
}

@Test func lyricsSnapshotEncoderTruncatesWithoutExceedingBudget() throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }

    try Data(repeating: 0x41, count: 24).write(
        to: directory.appendingPathComponent("00000000000000000000000000000000.json")
    )
    try Data(repeating: 0x42, count: 24).write(
        to: directory.appendingPathComponent("11111111111111111111111111111111.json")
    )

    let result = try #require(
        LyricsSnapshotEncoder.encodeDirectory(
            directory,
            maximumOutputBytes: 100,
            maximumFileBytes: 1_024,
            fileManager: fm
        )
    )

    #expect(result.data.count <= 100)
    #expect(result.fileCount == 1)
    #expect(result.skippedFileCount == 1)
    #expect(result.isTruncated)
    #expect(try JSONDecoder().decode([String: String].self, from: result.data).count == 1)
}

@Test func lyricsSnapshotEncoderRejectsOversizedFilesBeforeEncoding() throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }

    try Data(repeating: 0x41, count: 32).write(
        to: directory.appendingPathComponent("22222222222222222222222222222222.json")
    )

    #expect(
        LyricsSnapshotEncoder.encodeDirectory(
            directory,
            maximumOutputBytes: 1_024,
            maximumFileBytes: 8,
            fileManager: fm
        ) == nil
    )
}

@Test func lyricsSnapshotEncoderIncludesOnlyAllowedSongFiles() throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }

    let allowed = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json"
    let localOnly = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json"
    try Data("allowed".utf8).write(to: directory.appendingPathComponent(allowed))
    try Data("local".utf8).write(to: directory.appendingPathComponent(localOnly))

    let result = try #require(LyricsSnapshotEncoder.encodeDirectory(
        directory,
        maximumOutputBytes: 1_024,
        maximumFileBytes: 1_024,
        allowedFileNames: [allowed],
        fileManager: fm
    ))
    let decoded = try JSONDecoder().decode([String: String].self, from: result.data)

    #expect(Set(decoded.keys) == [allowed])
    #expect(result.skippedFileCount == 0)
}
