import AVFoundation
import Foundation
import PrimuseKit
import SFBAudioEngine

/// What a save does to the lyrics stored inside the audio file.
enum EmbeddedLyricsEdit: Sendable, Equatable {
    /// Leave whatever the file carries exactly as it is.
    case keep
    /// Store this text as the file's unsynchronised lyrics (LRC text included).
    case set(String)
    case remove

    var logName: String {
        switch self {
        case .keep: return "keep"
        case .set: return "set"
        case .remove: return "remove"
        }
    }
}

struct EmbeddedMetadataEdits: Sendable, Equatable {
    struct Tags: Sendable, Equatable {
        let title: String
        let artist: String?
        let albumTitle: String?
        let genre: String?
        let year: Int?
        let trackNumber: Int?
        let discNumber: Int?
    }

    /// `nil` leaves the file's text tags alone, for saves that only touch lyrics.
    let tags: Tags?
    let coverData: Data?
    let lyrics: EmbeddedLyricsEdit
    /// The text fields the caller actually changed. Only these are written;
    /// every other tag keeps what the file already holds. A library row can
    /// lag behind its file (tags not read yet, a reader that missed a field),
    /// and writing the row's value for an untouched field would replace the
    /// file's real tag with that gap. `nil` writes every field.
    var changedFields: Set<TagMetadataWritebackField>? = nil

    func writes(_ field: TagMetadataWritebackField) -> Bool {
        changedFields?.contains(field) ?? true
    }
}

struct EmbeddedMetadataVerification: Sendable, Equatable {
    let title: String?
    let artist: String?
    let albumTitle: String?
    let genre: String?
    let year: Int?
    let trackNumber: Int?
    let discNumber: Int?
    let coverData: Data?
}

enum EmbeddedMetadataWriterError: LocalizedError {
    case unsupportedFormat(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return String(localized: "metadata_writeback_error_unsupported")
        case .verificationFailed(let field):
            return String(
                format: String(localized: "metadata_writeback_error_embedded_verification_format"),
                field
            )
        }
    }
}

enum EmbeddedMetadataWriter {
    private static let supportedExtensions: Set<String> = ["mp3", "flac", "m4a"]

    /// The text tags a file holds now, read the same way verification reads
    /// them.
    static func currentTags(at fileURL: URL) throws -> EmbeddedMetadataVerification {
        verification(from: try AudioFile(readingPropertiesAndMetadataFrom: fileURL).metadata)
    }

    static func writeAndVerify(
        _ edits: EmbeddedMetadataEdits,
        to fileURL: URL
    ) async throws -> EmbeddedMetadataVerification {
        let fileExtension = fileURL.pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            throw EmbeddedMetadataWriterError.unsupportedFormat(fileExtension)
        }

        let audioFile = try AudioFile(readingPropertiesAndMetadataFrom: fileURL)
        let metadata = audioFile.metadata
        if let tags = edits.tags {
            if edits.writes(.title) { metadata.title = tags.title }
            if edits.writes(.artist) { metadata.artist = tags.artist }
            if edits.writes(.album) { metadata.albumTitle = tags.albumTitle }
            if edits.writes(.genre) { metadata.genre = tags.genre }
            // SFBAudioEngine 0.12.1 validates MP3 TDRC values through
            // NSISO8601DateFormatter and silently drops a year-only string.
            // A full ISO-8601 value preserves the editor's year in ID3; FLAC and
            // MP4 accept the intended year-only representation directly.
            if edits.writes(.year) {
                metadata.releaseDate = tags.year.map { year in
                    fileExtension == "mp3" ? String(format: "%04d-01-01T00:00:00Z", year) : String(year)
                }
            }
            if edits.writes(.trackNumber) { metadata.trackNumber = tags.trackNumber }
            if edits.writes(.discNumber) { metadata.discNumber = tags.discNumber }
        }

        // SFBAudioEngine 0.12.1 loads the MP4 grouping item (`©grp`) into
        // `lyrics` and never into `grouping`. Saving that model replaces the
        // file's embedded lyrics with the grouping text and deletes the
        // grouping, so both are restored from the file's own atoms first.
        var verifiesStoredM4ALyrics = edits.lyrics != .keep
        var expectedM4ALyrics: String?
        if fileExtension == "m4a" {
            let stored = ISOBaseMediaLyricsParser.storedITunesTextItems(
                in: try Data(contentsOf: fileURL, options: .mappedIfSafe)
            )
            if let grouping = stored.grouping {
                // Lyrics that cannot be read back cannot be restored either;
                // leave the file untouched rather than overwrite them.
                try require(
                    edits.lyrics != .keep || !stored.hasUndecodableLyrics,
                    field: "lyrics"
                )
                metadata.lyrics = stored.lyrics
                metadata.grouping = grouping
                expectedM4ALyrics = stored.lyrics
                verifiesStoredM4ALyrics = true
            }
        }

        // The library rebuilds ID3 lyrics from the first `USLT` frame alone and
        // drops its language and descriptor. When this save is not about
        // lyrics, the frames are put back afterwards exactly as they were.
        var preservedID3LyricsFrames: [Data]?
        if fileExtension == "mp3", edits.lyrics == .keep,
           let frames = ID3LyricsFramePreservation.lyricsFrameBodies(
               in: try Data(contentsOf: fileURL, options: .mappedIfSafe)
           ), !frames.isEmpty {
            preservedID3LyricsFrames = frames
        }

        switch edits.lyrics {
        case .keep:
            break
        case .set(let text):
            metadata.lyrics = text
            expectedM4ALyrics = text
        case .remove:
            metadata.lyrics = nil
            expectedM4ALyrics = nil
        }

        if let coverData = edits.coverData {
            if fileExtension == "m4a" {
                // MP4 `covr` entries do not retain ID3/FLAC picture roles.
                metadata.removeAllAttachedPictures()
            } else {
                metadata.removeAttachedPicturesOfType(.frontCover)
            }
            metadata.attachPicture(AttachedPicture(imageData: coverData, type: .frontCover))
        }

        try audioFile.writeMetadata()

        if let coverData = edits.coverData {
            switch fileExtension {
            case "mp3":
                try repairID3PictureMIME(at: fileURL, coverData: coverData)
            case "flac":
                try repairFLACPictureMIME(at: fileURL, coverData: coverData)
            default:
                break
            }
        }

        var restoredID3LyricsFrames = false
        if let preservedID3LyricsFrames {
            restoredID3LyricsFrames = try restoreID3LyricsFrames(
                preservedID3LyricsFrames,
                at: fileURL
            )
        }

        if fileExtension == "m4a", let tags = edits.tags, edits.writes(.album) {
            try await rewriteM4AAlbum(tags.albumTitle, at: fileURL)
        }

        let verifiedFile = try AudioFile(readingPropertiesAndMetadataFrom: fileURL)
        let verified = verification(from: verifiedFile.metadata)
        if let tags = edits.tags {
            if edits.writes(.title) {
                try require(verified.title == tags.title, field: "title")
            }
            if edits.writes(.artist) {
                try require(normalized(verified.artist) == normalized(tags.artist), field: "artist")
            }
            if edits.writes(.album) {
                try require(normalized(verified.albumTitle) == normalized(tags.albumTitle), field: "album")
            }
            if edits.writes(.genre) {
                try require(normalized(verified.genre) == normalized(tags.genre), field: "genre")
            }
            if edits.writes(.year) {
                try require(verified.year == tags.year, field: "year")
            }
            if edits.writes(.trackNumber) {
                try require(verified.trackNumber == tags.trackNumber, field: "track number")
            }
            if edits.writes(.discNumber) {
                try require(verified.discNumber == tags.discNumber, field: "disc number")
            }
        }
        if let coverData = edits.coverData {
            try require(verified.coverData == coverData, field: "cover artwork")
        }

        if fileExtension == "m4a" {
            // The library's own reading of MP4 lyrics is the faulty one, so the
            // result is checked against the atoms in the file.
            if verifiesStoredM4ALyrics {
                let written = ISOBaseMediaLyricsParser.storedITunesTextItems(
                    in: try Data(contentsOf: fileURL, options: .mappedIfSafe)
                )
                try require(
                    comparableLyrics(written.lyrics) == comparableLyrics(expectedM4ALyrics),
                    field: "lyrics"
                )
            }
        } else {
            switch edits.lyrics {
            case .keep:
                if restoredID3LyricsFrames {
                    let written = ID3LyricsFramePreservation.lyricsFrameBodies(
                        in: try Data(contentsOf: fileURL, options: .mappedIfSafe)
                    )
                    try require(written == preservedID3LyricsFrames, field: "lyrics")
                }
            case .set(let text):
                try require(
                    comparableLyrics(verifiedFile.metadata.lyrics) == comparableLyrics(text),
                    field: "lyrics"
                )
            case .remove:
                try require(comparableLyrics(verifiedFile.metadata.lyrics) == nil, field: "lyrics")
            }
        }
        return verified
    }

    /// Returns whether the file was rewritten. A saved tag in a shape this code
    /// does not restructure is left as the library wrote it.
    private static func restoreID3LyricsFrames(_ frames: [Data], at fileURL: URL) throws -> Bool {
        let saved = try Data(contentsOf: fileURL)
        guard ID3LyricsFramePreservation.lyricsFrameBodies(in: saved) != frames,
              let restored = ID3LyricsFramePreservation.replacingLyricsFrames(
                  in: saved,
                  with: frames
              ) else {
            return false
        }
        try restored.write(to: fileURL, options: .atomic)
        return true
    }

    /// Line endings and outer whitespace are not part of what was asked for.
    private static func comparableLyrics(_ value: String?) -> String? {
        guard let value else { return nil }
        let unified = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return unified.isEmpty ? nil : unified
    }

    /// SFBAudioEngine 0.12.1 writes the MP4 album atom as `©ALB` instead of
    /// the standard `©alb`, leaving an existing album unchanged. A passthrough
    /// AVFoundation export corrects that single field without re-encoding the
    /// audio stream and carries all metadata produced above into the new file.
    private static func rewriteM4AAlbum(_ albumTitle: String?, at fileURL: URL) async throws {
        let asset = AVURLAsset(url: fileURL)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw EmbeddedMetadataWriterError.verificationFailed("album export")
        }

        var metadata = try await asset.load(.metadata)
        metadata.removeAll { $0.identifier == .iTunesMetadataAlbum }
        if let albumTitle = normalized(albumTitle) {
            let item = AVMutableMetadataItem()
            item.identifier = .iTunesMetadataAlbum
            item.value = albumTitle as NSString
            metadata.append(item)
        }
        exporter.metadata = metadata

        let outputURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("m4a-metadata-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try await exporter.export(to: outputURL, as: .m4a)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: outputURL)
    }

    /// SFBAudioEngine currently emits an empty APIC MIME field even though it
    /// preserves the image bytes. Fill it so external readers such as ffprobe
    /// can recognize and dimension the attached cover.
    private static func repairID3PictureMIME(at fileURL: URL, coverData: Data) throws {
        var data = try Data(contentsOf: fileURL)
        guard data.count >= 10,
              data.prefix(3) == Data("ID3".utf8),
              data[3] == 3 || data[3] == 4 else {
            throw EmbeddedMetadataWriterError.verificationFailed("ID3 cover container")
        }
        let version = data[3]
        let oldTagSize = synchsafeInteger(data, at: 6)
        let tagEnd = 10 + oldTagSize
        guard tagEnd <= data.count else {
            throw EmbeddedMetadataWriterError.verificationFailed("ID3 size")
        }

        var offset = 10
        while offset + 10 <= tagEnd {
            let identifier = String(data: data[offset..<(offset + 4)], encoding: .isoLatin1) ?? ""
            if identifier.trimmingCharacters(in: CharacterSet(charactersIn: "\0")).isEmpty {
                break
            }
            let frameSize = version == 4
                ? synchsafeInteger(data, at: offset + 4)
                : bigEndianUInt32(data, at: offset + 4)
            let payloadStart = offset + 10
            let payloadEnd = payloadStart + frameSize
            guard frameSize >= 0, payloadEnd <= tagEnd else {
                throw EmbeddedMetadataWriterError.verificationFailed("ID3 frame size")
            }
            if identifier == "APIC" {
                let encoding = data[payloadStart]
                guard let mimeTerminator = data[(payloadStart + 1)..<payloadEnd]
                    .firstIndex(of: 0), mimeTerminator + 1 < payloadEnd else {
                    throw EmbeddedMetadataWriterError.verificationFailed("ID3 cover MIME")
                }
                let pictureTypeOffset = mimeTerminator + 1
                if data[pictureTypeOffset] == 0x03 { // ID3/FLAC front cover
                    let mimeData = Data(imageMIMEType(for: coverData).utf8)
                    let oldMimeRange = (payloadStart + 1)..<mimeTerminator
                    let delta = mimeData.count - oldMimeRange.count
                    if delta != 0 || data[oldMimeRange] != mimeData {
                        data.replaceSubrange(oldMimeRange, with: mimeData)
                        writeFrameSize(frameSize + delta, version: version, to: &data, at: offset + 4)
                        writeSynchsafeInteger(oldTagSize + delta, to: &data, at: 6)
                        try data.write(to: fileURL, options: .atomic)
                    }
                    return
                }
                _ = encoding // Description encoding does not affect the MIME field.
            }
            offset = payloadEnd
        }
        throw EmbeddedMetadataWriterError.verificationFailed("ID3 front cover")
    }

    /// FLAC PICTURE blocks use a length-prefixed MIME string. Repair the front
    /// cover block emitted with an empty value while leaving audio frames and
    /// all unrelated metadata blocks byte-for-byte intact.
    private static func repairFLACPictureMIME(at fileURL: URL, coverData: Data) throws {
        var data = try Data(contentsOf: fileURL)
        guard data.count >= 8, data.prefix(4) == Data("fLaC".utf8) else {
            throw EmbeddedMetadataWriterError.verificationFailed("FLAC cover container")
        }
        var offset = 4
        while offset + 4 <= data.count {
            let header = data[offset]
            let isLast = (header & 0x80) != 0
            let blockType = header & 0x7f
            let blockLength = Int(data[offset + 1]) << 16
                | Int(data[offset + 2]) << 8
                | Int(data[offset + 3])
            let payloadStart = offset + 4
            let payloadEnd = payloadStart + blockLength
            guard payloadEnd <= data.count else {
                throw EmbeddedMetadataWriterError.verificationFailed("FLAC block size")
            }
            if blockType == 6, blockLength >= 32 {
                let pictureType = bigEndianUInt32(data, at: payloadStart)
                let mimeLength = bigEndianUInt32(data, at: payloadStart + 4)
                let mimeStart = payloadStart + 8
                let mimeEnd = mimeStart + mimeLength
                guard mimeEnd + 4 <= payloadEnd else {
                    throw EmbeddedMetadataWriterError.verificationFailed("FLAC cover MIME")
                }
                let descriptionLength = bigEndianUInt32(data, at: mimeEnd)
                let fieldsStart = mimeEnd + 4 + descriptionLength
                guard fieldsStart + 20 <= payloadEnd else {
                    throw EmbeddedMetadataWriterError.verificationFailed("FLAC picture fields")
                }
                let imageLength = bigEndianUInt32(data, at: fieldsStart + 16)
                let imageStart = fieldsStart + 20
                guard imageStart + imageLength <= payloadEnd else {
                    throw EmbeddedMetadataWriterError.verificationFailed("FLAC picture data")
                }
                if pictureType == 0x03,
                   data[imageStart..<(imageStart + imageLength)] == coverData {
                    let mimeData = Data(imageMIMEType(for: coverData).utf8)
                    let delta = mimeData.count - mimeLength
                    data.replaceSubrange(mimeStart..<mimeEnd, with: mimeData)
                    writeBigEndianUInt32(mimeData.count, to: &data, at: payloadStart + 4)
                    let newBlockLength = blockLength + delta
                    guard newBlockLength <= 0x00ff_ffff else {
                        throw EmbeddedMetadataWriterError.verificationFailed("FLAC picture size")
                    }
                    data[offset + 1] = UInt8((newBlockLength >> 16) & 0xff)
                    data[offset + 2] = UInt8((newBlockLength >> 8) & 0xff)
                    data[offset + 3] = UInt8(newBlockLength & 0xff)
                    try data.write(to: fileURL, options: .atomic)
                    return
                }
            }
            if isLast { break }
            offset = payloadEnd
        }
        throw EmbeddedMetadataWriterError.verificationFailed("FLAC front cover")
    }

    private static func imageMIMEType(for data: Data) -> String {
        if data.count >= 3, data[0] == 0xff, data[1] == 0xd8, data[2] == 0xff {
            return "image/jpeg"
        }
        if data.count >= 8,
           data.prefix(8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
            return "image/png"
        }
        if data.count >= 6,
           String(data: data.prefix(6), encoding: .ascii)?.hasPrefix("GIF") == true {
            return "image/gif"
        }
        return "application/octet-stream"
    }

    private static func synchsafeInteger(_ data: Data, at offset: Int) -> Int {
        (Int(data[offset]) << 21)
            | (Int(data[offset + 1]) << 14)
            | (Int(data[offset + 2]) << 7)
            | Int(data[offset + 3])
    }

    private static func writeSynchsafeInteger(_ value: Int, to data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 21) & 0x7f)
        data[offset + 1] = UInt8((value >> 14) & 0x7f)
        data[offset + 2] = UInt8((value >> 7) & 0x7f)
        data[offset + 3] = UInt8(value & 0x7f)
    }

    private static func bigEndianUInt32(_ data: Data, at offset: Int) -> Int {
        (Int(data[offset]) << 24)
            | (Int(data[offset + 1]) << 16)
            | (Int(data[offset + 2]) << 8)
            | Int(data[offset + 3])
    }

    private static func writeBigEndianUInt32(_ value: Int, to data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 24) & 0xff)
        data[offset + 1] = UInt8((value >> 16) & 0xff)
        data[offset + 2] = UInt8((value >> 8) & 0xff)
        data[offset + 3] = UInt8(value & 0xff)
    }

    private static func writeFrameSize(
        _ value: Int,
        version: UInt8,
        to data: inout Data,
        at offset: Int
    ) {
        if version == 4 {
            writeSynchsafeInteger(value, to: &data, at: offset)
        } else {
            writeBigEndianUInt32(value, to: &data, at: offset)
        }
    }

    static func verification(from metadata: AudioMetadata) -> EmbeddedMetadataVerification {
        let frontCover = metadata.attachedPictures(ofType: .frontCover).first?.imageData
        let anyCover = metadata.attachedPictures.first?.imageData
        return EmbeddedMetadataVerification(
            title: normalized(metadata.title),
            artist: normalized(metadata.artist),
            albumTitle: normalized(metadata.albumTitle),
            genre: normalized(metadata.genre),
            year: metadata.releaseDate.flatMap { value in
                Int(String(value.prefix(4)))
            },
            trackNumber: metadata.trackNumber,
            discNumber: metadata.discNumber,
            coverData: frontCover ?? anyCover
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func require(_ condition: @autoclosure () -> Bool, field: String) throws {
        guard condition() else {
            throw EmbeddedMetadataWriterError.verificationFailed(field)
        }
    }
}
