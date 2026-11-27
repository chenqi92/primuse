import Foundation
import Testing
@testable import PrimuseKit

@Suite("Apple Music local assets")
struct AppleMusicLocalAssetTests {
    private func asset(
        _ url: URL?,
        isSong: Bool = true,
        isFileLocation: Bool = true,
        isProtected: Bool = false
    ) -> AppleMusicLocalAsset {
        AppleMusicLocalAsset(
            url: url, isSong: isSong, isFileLocation: isFileLocation, isProtected: isProtected
        )
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleMusicLocalAssetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test("Ordinary audio and unknown suffixes reach the content decoder",
          arguments: ["mp3", "aac", "m4a", "alac", "wav", "aiff", "flac", "unknown"])
    func acceptsOrdinaryFiles(ext: String) throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("song.\(ext)")
            try Data([1, 2, 3]).write(to: url)
            #expect(try asset(url).validatedURL() == url)
        }
    }

    @Test("Protection and managed packages are rejected independently of readability")
    func rejectsProtectedAssets() throws {
        try withDirectory { directory in
            for ext in ["m4p", "M4P"] {
                let url = directory.appendingPathComponent("song.\(ext)")
                try Data([1]).write(to: url)
                #expect(throws: AppleMusicLocalAssetError.protectedContent) {
                    try asset(url).validatedURL()
                }
            }
            let renamed = directory.appendingPathComponent("song.m4a")
            try Data([1]).write(to: renamed)
            #expect(throws: AppleMusicLocalAssetError.protectedContent) {
                try asset(renamed, isProtected: true).validatedURL()
            }
            for ext in ["movpkg", "MOVPKG"] {
                let package = directory.appendingPathComponent("song.\(ext)", isDirectory: true)
                try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                let fragment = package.appendingPathComponent("audio.m4a")
                try Data([1]).write(to: fragment)
                for url in [package, fragment] {
                    #expect(throws: AppleMusicLocalAssetError.managedDownload) {
                        try asset(url).validatedURL()
                    }
                }
            }
        }
    }

    @Test("Local URLs alone cannot establish an ordinary readable music file")
    func rejectsUnavailableAssets() throws {
        #expect(throws: AppleMusicLocalAssetError.unavailable) { try asset(nil).validatedURL() }
        #expect(throws: AppleMusicLocalAssetError.unavailable) {
            try asset(URL(string: "https://example.com/song.m4a")).validatedURL()
        }
        try withDirectory { directory in
            let url = directory.appendingPathComponent("song.m4a")
            #expect(throws: AppleMusicLocalAssetError.unavailable) { try asset(url).validatedURL() }
            try Data().write(to: url)
            #expect(throws: AppleMusicLocalAssetError.invalidFile) { try asset(url).validatedURL() }
            try Data([1]).write(to: url)
            #expect(throws: AppleMusicLocalAssetError.invalidFile) {
                try asset(url, isSong: false).validatedURL()
            }
            #expect(throws: AppleMusicLocalAssetError.unavailable) {
                try asset(url, isFileLocation: false).validatedURL()
            }
            #expect(throws: AppleMusicLocalAssetError.invalidFile) { try asset(directory).validatedURL() }
        }
    }

    @Test("Cached library records recheck the current file on every resolution")
    func cachedRecordDoesNotTrustPreviousFileState() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("song.m4a")
            try Data([1]).write(to: url)
            let cached = asset(url)
            #expect(try cached.validatedURL() == url)
            try FileManager.default.removeItem(at: url)
            #expect(throws: AppleMusicLocalAssetError.unavailable) { try cached.validatedURL() }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            #expect(throws: AppleMusicLocalAssetError.invalidFile) { try cached.validatedURL() }
        }
    }

    @Test("A readable cached asset is rejected after its file permission changes")
    func rejectsUnreadableAsset() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("song.m4a")
            try Data([1]).write(to: url)
            let cached = asset(url)
            #expect(try cached.validatedURL() == url)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            #expect(throws: AppleMusicLocalAssetError.unreadable) { try cached.validatedURL() }
        }
    }

    @Test("Symlinks retain ordinary files but cannot disguise managed downloads")
    func resolvesSymlinkTargets() throws {
        try withDirectory { directory in
            let regular = directory.appendingPathComponent("song.m4a")
            try Data([1]).write(to: regular)
            let link = directory.appendingPathComponent("link.m4a")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
            #expect(try asset(link).validatedURL() == link)
            try FileManager.default.removeItem(at: link)
            let package = directory.appendingPathComponent("song.movpkg", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)
            #expect(throws: AppleMusicLocalAssetError.managedDownload) { try asset(link).validatedURL() }
        }
    }

    @Test("Unavailable local assets preserve selection without publishing stale errors",
          arguments: AppleMusicLocalAssetError.allCases)
    func errorsRequireUserAction(error: AppleMusicLocalAssetError) {
        #expect(PlaybackPipelineFailurePolicy.action(requestIsCurrent: true, error: error) == .preserveCurrentItem)
        #expect(PlaybackPipelineFailurePolicy.action(requestIsCurrent: false, error: error) == .discardStaleResult)
        #expect(error.localizedDescription != "appleMusic.localAsset.\(error.rawValue)")
    }
}
