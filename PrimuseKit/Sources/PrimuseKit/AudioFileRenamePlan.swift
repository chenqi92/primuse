import Foundation

public struct AudioFileRenamePlan: Sendable {
    public struct Entry: Sendable {
        public let name: String
        public let path: String
        public let isDirectory: Bool

        public init(name: String, path: String, isDirectory: Bool = false) {
            self.name = name
            self.path = path
            self.isDirectory = isDirectory
        }
    }

    public struct Move: Sendable, Equatable {
        public let from: String
        public let to: String
    }

    public enum Failure: String, Error, Sendable {
        case invalidName, collision, cue, sharedSidecars, missingFile
    }

    public let moves: [Move]
    public var audioMove: Move? { moves.last }

    public static func suggestedStem(title: String, artist: String, track: Int? = nil) -> String {
        let parts = [track.map { String(format: "%02d", $0) }, artist, title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        return parts.joined(separator: " - ").components(separatedBy: invalid)
            .filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    public static func fileName(stem: String, original: String) throws -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        guard !stem.isEmpty, stem != ".", stem != "..", !stem.hasPrefix("."),
              stem == stem.trimmingCharacters(in: .whitespacesAndNewlines),
              !stem.hasSuffix("."), stem.rangeOfCharacter(from: invalid) == nil else {
            throw Failure.invalidName
        }
        let ext = (original as NSString).pathExtension
        guard !ext.isEmpty else { throw Failure.invalidName }
        let name = stem + "." + ext
        guard name.utf8.count <= 255 else { throw Failure.invalidName }
        return name
    }

    public init(audioPath: String, stem: String, entries: [Entry]) throws {
        let oldName = (audioPath as NSString).lastPathComponent
        let newName = try Self.fileName(stem: stem, original: oldName)
        guard entries.contains(where: { $0.path == audioPath && !$0.isDirectory }) else {
            throw Failure.missingFile
        }
        if oldName == newName { moves = []; return }
        // CUE sheets can refer to audio with a different base name.
        guard !entries.contains(where: { !$0.isDirectory && ($0.name as NSString).pathExtension.lowercased() == "cue" }) else {
            throw Failure.cue
        }
        let oldStem = (oldName as NSString).deletingPathExtension
        let directory = (audioPath as NSString).deletingLastPathComponent
        let sameNameSidecarExtensions: Set<String> = [
            "lrc", "elrc", "ttml", "lys", "yrc", "qrc", "vtt", "srt", "txt",
            "jpg", "jpeg", "png", "webp", "heic", "mp4", "mov", "m4v"
        ]
        let audioExtensions: Set<String> = ["mp3", "flac", "m4a", "aac", "alac", "wav", "aiff", "aif", "ogg", "opus", "ape", "wv", "dsf", "dff", "wma"]
        var changes: [Move] = []
        for entry in entries where !entry.isDirectory && entry.path != audioPath {
            let ext = (entry.name as NSString).pathExtension.lowercased()
            let base = (entry.name as NSString).deletingPathExtension
            let sameStem = base.compare(oldStem, options: [.caseInsensitive]) == .orderedSame
            if ["cover", "folder", "front", "back", "album", "artwork"].contains(base.lowercased()),
               ["jpg", "jpeg", "png", "webp", "heic"].contains(ext) { continue }
            if sameStem && audioExtensions.contains(ext) { throw Failure.sharedSidecars }
            let artworkSuffix = ["-cover", "-back"].first { base == oldStem + $0 }
            guard (sameStem && sameNameSidecarExtensions.contains(ext))
                    || (artworkSuffix != nil && ["jpg", "jpeg", "png", "webp", "heic"].contains(ext)) else { continue }
            let name = stem + (artworkSuffix ?? "") + "." + (entry.name as NSString).pathExtension
            guard name.utf8.count <= 255 else { throw Failure.invalidName }
            changes.append(Move(from: entry.path, to: (directory as NSString).appendingPathComponent(name)))
        }
        changes.sort { $0.from < $1.from }
        changes.append(Move(from: audioPath, to: (directory as NSString).appendingPathComponent(newName)))
        var destinations = Set<String>()
        for move in changes {
            let name = (move.to as NSString).lastPathComponent
            let key = name.precomposedStringWithCanonicalMapping.lowercased()
            guard destinations.insert(key).inserted,
                  !entries.contains(where: {
                      $0.path != move.from && $0.name.precomposedStringWithCanonicalMapping.lowercased() == key
                  }) else { throw Failure.collision }
        }
        moves = changes
    }
}
