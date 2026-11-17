import Foundation

/// The foobar2000 SACD metabase format: root/store/track with meta and replaygain attributes.
public enum SACDMetadataXML {
    public static let maximumBytes = 1024 * 1024

    public struct File: Sendable {
        public let name: String
        public let path: String
        public let size: Int64

        public init(name: String, path: String, size: Int64) {
            self.name = name
            self.path = path
            self.size = size
        }
    }

    public struct Document: Equatable, Sendable {
        public let tracks: [Int: EmbeddedTagMetadata]
        public let songwriters: [Int: String]
    }

    public static func parse(_ data: Data) -> Document? {
        guard !data.isEmpty, data.count <= maximumBytes else { return nil }
        let delegate = Parser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, delegate.storeCount == 1,
              !delegate.values.isEmpty else { return nil }
        return Document(tracks: delegate.values.mapValues { values in
            var tags = EmbeddedTagMetadataParser.metadata(fromTagValues: values)
            tags.trackNumber = positiveNumber((values["TRACKNUMBER"] ?? values["TRACK"])?.first)
            tags.discNumber = positiveNumber((values["DISCNUMBER"] ?? values["DISC"])?.first)
            return tags
        }, songwriters: delegate.values.compactMapValues {
            ($0["COMPOSER"] ?? $0["SONGWRITER"])?.joined(separator: "; ")
        })
    }

    /// Only a unique same-name sibling is eligible; arbitrary folder XML must never label another disc.
    public static func companion(imageFileName: String, files: [File]) -> File? {
        let stem = (imageFileName as NSString).deletingPathExtension
        let matches = files.filter {
            ($0.name as NSString).pathExtension.lowercased() == "xml"
                && ($0.name as NSString).deletingPathExtension.caseInsensitiveCompare(stem) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func loading(
        into sheet: CueSheet, imageFileName: String, files: [File],
        read: @Sendable (File, Int64, Int64) async throws -> Data
    ) async throws -> CueSheet {
        try Task.checkCancellation()
        guard sheet.files.count == 1, sheet.files[0].type == "SACD",
              let file = companion(imageFileName: imageFileName, files: files),
              file.size <= Int64(maximumBytes) else { return sheet }
        do {
            var data = Data()
            let limit = file.size > 0 ? Int(file.size) : maximumBytes + 1
            while data.count < limit {
                try Task.checkCancellation()
                let chunk = try await read(file, Int64(data.count), Int64(min(64 * 1024, limit - data.count)))
                try Task.checkCancellation()
                guard !chunk.isEmpty else { break }
                guard chunk.count <= limit - data.count else { return sheet }
                data.append(chunk)
                if file.size <= 0, let document = parse(data) {
                    return merging(document, into: sheet)
                }
            }
            try Task.checkCancellation()
            guard file.size <= 0 || data.count == Int(file.size), let document = parse(data) else { return sheet }
            return merging(document, into: sheet)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return sheet
        }
    }

    public static func loadingLocal(into sheet: CueSheet, imageURL: URL) async throws -> CueSheet {
        guard sheet.files.count == 1, sheet.files[0].type == "SACD" else { return sheet }
        let directory = imageURL.deletingLastPathComponent()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )) ?? []
        let files = urls.compactMap { url -> File? in
            guard url.pathExtension.lowercased() == "xml",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return File(name: url.lastPathComponent, path: url.path, size: Int64(values.fileSize ?? 0))
        }
        return try await loading(into: sheet, imageFileName: imageURL.lastPathComponent, files: files) { file, offset, length in
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file.path))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: Int(length)) ?? Data()
        }
    }

    public static func merging(_ document: Document, into sheet: CueSheet) -> CueSheet {
        guard sheet.files.count == 1, sheet.files[0].type == "SACD" else { return sheet }
        let tracks = sheet.files[0].tracks
        guard !tracks.isEmpty else { return sheet }
        // TRACKNUMBER establishes whether XML IDs need an offset, including sparse documents.
        // Without it require a complete, unambiguous table.
        let offsets = [0, 1].filter { offset in
            let matched = tracks.compactMap { track -> (Int, EmbeddedTagMetadata)? in
                document.tracks[track.number + offset].map { (track.number, $0) }
            }
            guard !matched.isEmpty else { return false }
            let numbered = matched.filter { $0.1.trackNumber != nil }
            if !numbered.isEmpty { return numbered.allSatisfy { $0.0 == $0.1.trackNumber } }
            return matched.count == tracks.count && Set(document.tracks.keys) == Set(tracks.map { $0.number + offset })
        }
        guard offsets.count == 1, let offset = offsets.first else { return sheet }
        var result = sheet
        for index in tracks.indices {
            let id = tracks[index].number + offset
            guard var tags = document.tracks[id], !tags.isEmpty || document.songwriters[id] != nil else { continue }
            var track = tracks[index]
            // Technical properties and the immutable ISO selector always come from the disc.
            track.title = tags.title ?? track.title
            track.performer = tags.artist ?? track.performer ?? sheet.performer
            track.songwriter = document.songwriters[id] ?? track.songwriter
            if let number = tags.discNumber, number <= 0 { tags.discNumber = nil }
            track.sacdMetadata = tags
            track.replayGainTrackGain = gain(tags.replayGainTrackGain) ?? track.replayGainTrackGain
            track.replayGainTrackPeak = peak(tags.replayGainTrackPeak) ?? track.replayGainTrackPeak
            track.replayGainAlbumGain = gain(tags.replayGainAlbumGain) ?? track.replayGainAlbumGain
            track.replayGainAlbumPeak = peak(tags.replayGainAlbumPeak) ?? track.replayGainAlbumPeak
            result.files[0].tracks[index] = track
        }
        return result
    }

    private static func gain(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && (-60...60).contains($0) ? $0 : nil }
    }

    private static func positiveNumber(_ value: String?) -> Int? {
        guard let head = value?.split(separator: "/", omittingEmptySubsequences: false).first
                .map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !head.isEmpty, head.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(head), number > 0 else { return nil }
        return number
    }

    private static func peak(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var invalid = false
        var storeCount = 0
        var elements: [String] = []
        var trackID: Int?
        var values: [Int: [String: [String]]] = [:]

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            elements.append(name)
            guard elements.count <= 16 else { invalid = true; parser.abortParsing(); return }
            switch elements {
            case ["root"]: break
            case ["root", "store"]:
                storeCount += 1
                if attributes["type"]?.uppercased() != "SACD" { invalid = true }
            case ["root", "store", "track"]:
                guard let id = attributes["id"].flatMap(Int.init), (1...1024).contains(id), values[id] == nil else {
                    invalid = true; parser.abortParsing(); return
                }
                trackID = id
                values[id] = [:]
            case ["root", "store", "track", "meta"], ["root", "store", "track", "replaygain"]:
                guard let id = trackID, let key = attributes["name"]?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                      let value = attributes["value"], !key.isEmpty else { return }
                let items = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                values[id, default: [:]][key, default: []].append(contentsOf: items)
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if elements == ["root", "store", "track"] { trackID = nil }
            elements.removeLast()
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            invalid = true; parser.abortParsing()
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            invalid = true; parser.abortParsing()
        }
    }
}
