import AVFoundation
import Foundation
import PrimuseKit

enum FileMetadataReader {
    struct Metadata {
        var title: String?
        var artist: String?
        var albumTitle: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var genre: String?
        var duration: TimeInterval?
        var coverArtData: Data?
        var sampleRate: Int?
        var bitRate: Int?
        var bitDepth: Int?
        var replayGainTrackGain: Double?
        var replayGainTrackPeak: Double?
        var replayGainAlbumGain: Double?
        var replayGainAlbumPeak: Double?
        var lyricsText: String?
    }

    /// Reads metadata from an audio file using AVFoundation
    static func read(from url: URL) async -> Metadata {
        var metadata = Metadata()

        let asset = AVURLAsset(url: url)

        // Get duration
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds >= 0 {
                metadata.duration = seconds
            }
        }

        // Read metadata items
        if let items = try? await asset.load(.metadata) {
            for item in items {
                guard let key = item.commonKey?.rawValue else { continue }
                let value = try? await item.load(.value)

                switch key {
                case AVMetadataKey.commonKeyTitle.rawValue:
                    metadata.title = value as? String
                case AVMetadataKey.commonKeyArtist.rawValue:
                    metadata.artist = value as? String
                case AVMetadataKey.commonKeyAlbumName.rawValue:
                    metadata.albumTitle = value as? String
                case AVMetadataKey.commonKeyArtwork.rawValue:
                    if let data = value as? Data {
                        metadata.coverArtData = data
                    }
                default:
                    break
                }
            }

            // Try format-specific metadata for more detail
            for item in items {
                guard let identifier = item.identifier else { continue }
                let value = try? await item.load(.value)

                switch identifier {
                case .id3MetadataTrackNumber, .iTunesMetadataTrackNumber:
                    if let str = value as? String {
                        metadata.trackNumber = Int(str.split(separator: "/").first.map(String.init) ?? "")
                    } else if let num = value as? Int {
                        metadata.trackNumber = num
                    }
                case .id3MetadataPartOfASet:
                    if let str = value as? String {
                        metadata.discNumber = Int(str.split(separator: "/").first.map(String.init) ?? "")
                    }
                case .id3MetadataYear, .id3MetadataRecordingTime:
                    if let str = value as? String {
                        metadata.year = Int(String(str.prefix(4)))
                    }
                case .id3MetadataContentType:
                    metadata.genre = value as? String
                case .id3MetadataUnsynchronizedLyric:
                    if let text = value as? String, !text.isEmpty {
                        metadata.lyricsText = text
                    }
                case .iTunesMetadataLyrics:
                    if let text = value as? String, !text.isEmpty, metadata.lyricsText == nil {
                        metadata.lyricsText = text
                    }
                case .id3MetadataUserText:
                    // TXXX frames: ReplayGain tags stored in extraAttributes[.info]
                    if let extras = try? await item.load(.extraAttributes),
                       let desc = extras[.info] as? String {
                        let stringValue = try? await item.load(.stringValue)
                        switch desc.lowercased() {
                        case "replaygain_track_gain":
                            metadata.replayGainTrackGain = parseReplayGainDB(stringValue)
                        case "replaygain_track_peak":
                            metadata.replayGainTrackPeak = Double(stringValue ?? "")
                        case "replaygain_album_gain":
                            metadata.replayGainAlbumGain = parseReplayGainDB(stringValue)
                        case "replaygain_album_peak":
                            metadata.replayGainAlbumPeak = Double(stringValue ?? "")
                        default:
                            break
                        }
                    }
                default:
                    break
                }
            }
        }

        // Get audio format details
        if let tracks = try? await asset.load(.tracks) {
            for track in tracks {
                if track.mediaType == .audio {
                    if let formatDescriptions = try? await track.load(.formatDescriptions) {
                        for desc in formatDescriptions {
                            let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
                            if let basic = basicDescription?.pointee {
                                metadata.sampleRate = Int(basic.mSampleRate)
                                metadata.bitDepth = Int(basic.mBitsPerChannel)
                            }
                        }
                    }

                    if let bitRate = try? await track.load(.estimatedDataRate) {
                        metadata.bitRate = Int(bitRate / 1000) // kbps
                    }
                }
            }
        }

        // Use filename as title fallback
        if metadata.title == nil {
            metadata.title = url.deletingPathExtension().lastPathComponent
        }

        return metadata
    }

    /// Parse ReplayGain dB string like "-7.43 dB" or "+3.21 dB" to Double
    private static func parseReplayGainDB(_ value: String?) -> Double? {
        guard let value else { return nil }
        let cleaned = value
            .replacingOccurrences(of: " dB", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }
}
