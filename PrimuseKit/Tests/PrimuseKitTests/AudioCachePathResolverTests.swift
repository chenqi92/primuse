import Foundation
import Testing
@testable import PrimuseKit

@Suite("Audio cache path resolution")
struct AudioCachePathResolverTests {
    @Test("Symlink and physical roots produce the same reusable cache key")
    func aliasedCacheRoot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-cache-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("storage", isDirectory: true)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        let file = root.appendingPathComponent("source/song.flac")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([1, 2, 3, 4]).write(to: file)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)

        let resolver = AudioCachePathResolver(root: alias)
        let physicalKey = try #require(resolver.relativePath(for: file))
        let aliasedKey = try #require(resolver.relativePath(
            for: alias.appendingPathComponent("source/song.flac")
        ))
        #expect(physicalKey == "source/song.flac")
        #expect(aliasedKey == physicalKey)
        #expect(Set([physicalKey, aliasedKey]).count == 1)
        #expect(try Data(contentsOf: alias.appendingPathComponent(physicalKey)) == Data([1, 2, 3, 4]))
        #expect(resolver.relativePath(
            for: file.appendingPathExtension("partial")
        ) == "source/song.flac.partial")
    }

    @Test("Apple private-directory aliases do not contaminate cache keys")
    func privateDirectoryAlias() {
        let resolver = AudioCachePathResolver(
            root: URL(fileURLWithPath: "/var/tmp/audio-cache")
        )
        #expect(resolver.relativePath(
            for: URL(fileURLWithPath: "/private/var/tmp/audio-cache/source/song.flac")
        ) == "source/song.flac")
    }

    @Test("Cache keys cannot refer to a sibling root or an escaped symlink")
    func rejectsPathsOutsideCache() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-cache-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("cache", isDirectory: true)
        let outside = directory.appendingPathComponent("cache-other/song.flac")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outside.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([9]).write(to: outside)
        let escaped = root.appendingPathComponent("escape.flac")
        try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: outside)

        let resolver = AudioCachePathResolver(root: root)
        #expect(resolver.relativePath(for: root) == nil)
        #expect(resolver.relativePath(for: outside) == nil)
        #expect(resolver.relativePath(for: escaped) == nil)
        #expect(resolver.relativePath(for: root.appendingPathComponent("../cache-other/song.flac")) == nil)
        #expect(resolver.relativePath(for: URL(string: "https://media.invalid/song.flac")!) == nil)
    }
}
