import Foundation

/// External CUE text can describe an edition without defining the ISO's playback timeline.
public enum ISOAlbumMetadataPolicy {
    public struct Sidecar: Sendable {
        public let name: String
        public let sheet: CueSheet

        public init(name: String, sheet: CueSheet) {
            self.name = name
            self.sheet = sheet
        }
    }

    public static func merging(_ embedded: CueSheet, imageFileName: String, sidecars: [Sidecar]) -> CueSheet {
        var result = embedded
        let tracks = embedded.files.flatMap(\.tracks)
        guard !tracks.isEmpty else { return result }
        let isDataImage = tracks.contains { $0.isoAudioTrack?.kind == .file }
        let albumKeys = Set(tracks.map {
            [text($0.isoAudioTrack?.albumTitle) ?? "", text($0.isoAudioTrack?.albumArtist) ?? ""]
                .joined(separator: "\u{1F}")
        })
        let directories = Set(tracks.compactMap { $0.isoAudioTrack?.path }.map {
            ($0 as NSString).deletingLastPathComponent
        })
        // A data disc can be a collection of unrelated albums. Its outer name/CUE
        // must not collapse them; only each internal file's edition marks apply.
        let isSingleAlbum = !isDataImage || (albumKeys.count == 1 && directories.count <= 1)
        let external = isSingleAlbum ? matchingSidecar(imageFileName: imageFileName, sidecars: sidecars) : nil
        let externalFile = external?.sheet.files.first { refersToImage($0.name, imageFileName: imageFileName) }
        let mappedTracks = !isDataImage ? matchingTracks(tracks, external: externalFile?.tracks ?? []) : [:]
        let names = [imageFileName] + (external.map { [$0.name] } ?? [])

        if isSingleAlbum {
            result.title = addingEditionMarkers(to: text(external?.sheet.title) ?? text(embedded.title)
                ?? (imageFileName as NSString).deletingPathExtension, fileNames: names)
            result.performer = text(external?.sheet.performer) ?? embedded.performer
            result.songwriter = text(external?.sheet.songwriter) ?? embedded.songwriter
            result.genre = text(external?.sheet.genre) ?? embedded.genre
            result.year = external?.sheet.year ?? embedded.year
        }
        for fileIndex in result.files.indices {
            for trackIndex in result.files[fileIndex].tracks.indices {
                var track = result.files[fileIndex].tracks[trackIndex]
                if let override = mappedTracks[track.number] {
                    track.title = text(override.title) ?? track.title
                    track.performer = text(override.performer) ?? text(external?.sheet.performer) ?? track.performer
                    track.songwriter = text(override.songwriter) ?? track.songwriter
                }
                if var selector = track.isoAudioTrack {
                    let album = isSingleAlbum
                        ? text(external?.sheet.title) ?? text(selector.albumTitle) ?? text(embedded.title)
                        : text(selector.albumTitle)
                    selector.albumTitle = addingEditionMarkers(to: album, fileNames: isSingleAlbum ? names : [selector.path])
                    if isSingleAlbum {
                        selector.albumArtist = text(external?.sheet.performer) ?? selector.albumArtist
                    }
                    track.isoAudioTrack = selector
                }
                result.files[fileIndex].tracks[trackIndex] = track
            }
        }
        return result
    }

    public static func addingEditionMarkers(to title: String?, fileNames: [String]) -> String? {
        guard var title = text(title) else { return nil }
        var seen = Set(markers(in: title).map { markerKey($0) })
        for fileName in fileNames {
            for marker in markers(in: (fileName as NSString).lastPathComponent) {
                let key = markerKey(marker)
                guard !markerKey(title).contains(key), seen.insert(key).inserted else { continue }
                title += " " + marker
            }
        }
        return title
    }

    /// A successful rescan has fresh sidecar text even when the ISO bytes are unchanged.
    /// Keep cached technical data and explicit user edits while adopting that text.
    public static func refreshingIdentity(of existing: Song, from candidate: Song) -> Song {
        guard candidate.isDiscImageTrack else { return existing }
        var result = existing
        result.title = candidate.title
        result.artistName = candidate.artistName
        result.sourceArtistNames = candidate.sourceArtistNames
        result.albumTitle = candidate.albumTitle
        result.albumArtistName = candidate.albumArtistName
        result.artistID = candidate.artistID
        result.albumID = candidate.albumID
        result.trackNumber = candidate.trackNumber
        result.genre = candidate.genre
        result.year = candidate.year
        if result.title != existing.title { result.titlePinyin = nil }
        if result.artistName != existing.artistName { result.artistPinyin = nil }
        if result.albumTitle != existing.albumTitle { result.albumPinyin = nil }
        return SongUserMetadataPolicy.preservingUserEdits(from: existing, in: result)
    }

    private static func matchingSidecar(imageFileName: String, sidecars: [Sidecar]) -> Sidecar? {
        let matching = sidecars.filter { sidecar in
            sidecar.sheet.files.filter { refersToImage($0.name, imageFileName: imageFileName) }.count == 1
        }
        let stem = (imageFileName as NSString).deletingPathExtension
        let sameName = matching.filter {
            ($0.name as NSString).deletingPathExtension.caseInsensitiveCompare(stem) == .orderedSame
        }
        if sameName.count == 1 { return sameName[0] }
        return matching.count == 1 ? matching[0] : nil
    }

    private static func refersToImage(_ reference: String, imageFileName: String) -> Bool {
        let path = reference.replacingOccurrences(of: "\\", with: "/")
        // Sidecars are supplied from the image's own directory. Do not borrow
        // metadata from another directory's identically named image.
        let components = path.split(separator: "/").filter { $0 != "." }
        return components.count == 1 && !path.hasPrefix("/")
            && String(components[0]).caseInsensitiveCompare(imageFileName) == .orderedSame
    }

    private static func matchingTracks(_ internalTracks: [CueTrack], external: [CueTrack]) -> [Int: CueTrack] {
        let audio = external.filter { $0.type == "AUDIO" && $0.startTime != nil }
        guard !audio.isEmpty, audio.count == internalTracks.count,
              Set(audio.map(\.number)).count == audio.count,
              Set(internalTracks.map(\.number)).count == internalTracks.count,
              Set(audio.map(\.number)) == Set(internalTracks.map(\.number)) else { return [:] }
        let byNumber = Dictionary(uniqueKeysWithValues: audio.map { ($0.number, $0) })
        for track in internalTracks {
            guard let other = byNumber[track.number] else { return [:] }
            if let end = other.endTime, let start = other.startTime {
                guard let duration = track.endTime.map({ $0 - (track.startTime ?? 0) }),
                      duration > 0, end > start, abs((end - start) - duration) <= 2 else { return [:] }
            }
        }
        return byNumber
    }

    private static let brackets = try! NSRegularExpression(pattern: #"【[^【】]+】|\[[^\[\]]+\]|（[^（）]+）|\([^()]+\)"#)
    private static let edition = try! NSRegularExpression(pattern:
        #"(?:香港|台湾|台灣|臺灣|日本|美国|美國|英国|英國|德国|德國|欧洲|歐洲|大陆|大陸|中国|中國|新加坡|马来西亚|馬來西亞|港|台|臺|日|美|英|德|欧|歐|法|韩|韓)(?:首|初|再|原)?版|首版|初版|再版|重制版|重製版|复刻版|復刻版|限量版|纪念版|紀念版"#)

    private static func markers(in value: String) -> [String] {
        brackets.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            let marker = String(value[range])
            return edition.firstMatch(in: marker, range: NSRange(marker.startIndex..., in: marker)) == nil ? nil : marker
        }
    }

    private static func markerKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { !$0.isWhitespace && !"【】[]（）()".contains($0) }
            .replacingOccurrences(of: "臺", with: "台")
            .replacingOccurrences(of: "灣", with: "湾")
            .replacingOccurrences(of: "香港", with: "港")
            .replacingOccurrences(of: "台湾", with: "台")
    }

    private static func text(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
