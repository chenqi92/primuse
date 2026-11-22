import Foundation
import Testing
import zlib
@testable import PrimuseKit

@Suite("Embedded lyric attachments and timed-text tracks")
struct EmbeddedMediaLyricReaderTests {
    @Test func isoReadsOnlyLyricSamplesAndExcludesReferencedChapters() async throws {
        let sample = Data("盐花落进石阶".utf8)
        let events = integer(100, 4) + integer(2, 2) + integer(400, 4) + integer(0, 2) + integer(2, 2)
            + integer(1050, 4) + integer(2, 2) + integer(6, 2)
        let text = integer(sample.count, 2) + sample + box("krok", events)
        let web = box("vttc", box("payl", Data("薄云<00:00:00.500>合拢".utf8)))
        let xml = #"<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="0.25s" end="1s">雨声系起纸舟</p></div></body></tt>"#
        let xmlData = Data(xml.utf8)
        let offsets = [5_000_000_000, 5_001_000_000, 5_002_000_000]
        let audio = containerTrack(type: "soun", referencesChapter: 5)
        let title = isoTrack(number: 5, codec: "text", name: "Lyrics", offset: 99, size: text.count)
        let tracks = [audio, title,
                      isoTrack(number: 2, codec: "tx3g", name: "Lyrics", offset: offsets[0], size: text.count),
                      isoTrack(number: 3, codec: "wvtt", name: "Romanization", offset: offsets[1], size: web.count),
                      isoTrack(number: 4, codec: "stpp", name: "Translation", offset: offsets[2], size: xmlData.count + 640, xmlSize: xmlData.count)]
        let payloads = Dictionary(uniqueKeysWithValues: zip(offsets, [text, web, xmlData]))
        var requests: [Int] = []
        let fields = try await EmbeddedMediaLyricReader.isoTracks(
            metadataFile: box("moov", tracks.reduce(Data(), +)), fileSize: 6_000_000_000
        ) { offset, count in
            requests.append(Int(offset))
            let value = try #require(payloads[Int(offset)])
            #expect(value.count == count)
            return value
        }
        #expect(requests == offsets)
        #expect(fields.map(\.role) == [.original, .romanization, .translation])
        #expect(fields.map(\.languageCode) == ["zh", "zh", "zh"])
        let lines = fields.map { LyricsContentParser.parseText($0.text) }
        #expect(lines.map { $0.first?.text } == ["盐花落进石阶", "薄云合拢", "雨声系起纸舟"])
        #expect(lines[0].first?.syllables?.map(\.text) == ["盐花", "落进石阶"])
        #expect(lines[0].first?.syllables?.map(\.start) == [0.1, 0.4])
        #expect(lines[0].first?.syllables?.last?.end == 1.05)
        #expect(lines[1].first?.syllables?.last?.start == 0.5)
        #expect(fields[2].text == xml)
    }

    @Test func fragmentedTrackUsesTrackDefaultsAndSkipsTheAudioInMediaData() async throws {
        let payload = Data("星河照着浅滩".utf8)
        let sample = integer(payload.count, 2) + payload
        let track = isoTrack(number: 9, codec: "tx3g", name: "Lyrics", offset: 0, size: 0, fragmented: true)
        let defaults = integer(0, 4) + integer(9, 4) + integer(1, 4) + integer(750, 4) + integer(sample.count, 4) + integer(0, 4)
        let moov = box("moov", containerTrack(type: "soun") + track + box("mvex", box("trex", defaults)))
        let tfhd = box("tfhd", integer(0x020000, 4) + integer(9, 4))
        let tfdt = box("tfdt", integer(0x01000000, 4) + integer(2500, 8))
        func moof(offset: Int) -> Data {
            let run = box("trun", integer(1, 4) + integer(1, 4) + integer(offset, 4))
            return box("moof", box("traf", tfhd + tfdt + run))
        }
        let audio = Data(repeating: 0xF1, count: 300_000)
        let fragment = moof(offset: moof(offset: 0).count + 8 + audio.count)
        let file = moov + fragment + box("mdat", audio + sample)
        let mvex = try #require(moov.range(of: Data("mvex".utf8)))
        var metadataForAVFoundation = moov
        metadataForAVFoundation.replaceSubrange(mvex, with: Data("free".utf8))
        var transferred = 0
        let fields = try await EmbeddedMediaLyricReader.isoTracks(metadataFile: metadataForAVFoundation, fileSize: Int64(file.count)) { offset, count in
            transferred += Int(count)
            return file[Int(offset)..<Int(offset + count)]
        }
        let text = try #require(fields.first?.text)
        let line = try #require(LyricsContentParser.parseText(text).first)
        #expect(line.text == "星河照着浅滩")
        #expect(line.timestamp == 2.5)
        #expect(line.endTimestamp == 3.25)
        #expect(transferred < 1_000)
    }

    @Test func movieSubtitlesNeedALyricLabel() async throws {
        let media = containerTrack(type: "soun") + containerTrack(type: "vide")
        let track = isoTrack(number: 3, codec: "tx3g", name: "SubtitleHandler", offset: 10, size: 10)
        let fields = try await EmbeddedMediaLyricReader.isoTracks(metadataFile: box("moov", media + track), fileSize: 100) { _, _ in
            Issue.record("Ordinary movie subtitle samples should not be requested")
            return Data()
        }
        #expect(fields.isEmpty)
    }

    @Test func matroskaReadsNoncontiguousAttachmentsTagsAndSubtitleBlocks() async throws {
        let xml = #"<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="1s" end="2s">暮雨穿过青砖</p></div></body></tt>"#
        let lrc = "[00:01.00]青砖留下潮痕"
        let translation = "At the quiet sill"
        let otherTranslation = "Beyond the sill"
        let lyricAttachments = attached("巷口.ttml", mime: "application/ttml+xml", bytes: Data(xml.utf8))
            + attached("巷口.lrc", mime: "text/lrc", bytes: Data(lrc.utf8))
        let cover = attached("cover.jpg", mime: "image/jpeg", bytes: Data(repeating: 0xF8, count: 64_000))
        let timestamp = ebml(0xE7, integer(2000, 2))
        let audioBlock = ebml(0xA3, Data([0x81, 0, 0, 0]) + Data(repeating: 0xA8, count: 300_000))
        let subtitleBlock = ebml(0xA0, ebml(0xA1, Data([0x82, 0xFF, 0x06, 0]) + Data("岸灯拾起远帆".utf8)) + ebml(0x9B, integer(500, 2)))
        let textTrack = mkTrack(2, type: 17, codec: "S_TEXT/UTF8", name: "Lyrics", language: "zh-Hans")
        let tags = ebml(0x1254C367, ebml(0x7373, simpleTag("TRANSLATION", translation, language: "en") + simpleTag("TRANSLATION", otherTranslation, language: "en")))
        let segment = ebml(0x1654AE6B, mkTrack(1, type: 2, codec: "A_FLAC") + textTrack)
            + ebml(0x1F43B675, timestamp + audioBlock + subtitleBlock) + ebml(0x1941A469, cover + lyricAttachments) + tags
        let file = ebml(0x1A45DFA3, Data()) + ebml(0x18538067, segment)
        var bytesFetched = 0
        let fields = try await EmbeddedMediaLyricReader.matroska(head: file.prefix(64), fileSize: Int64(file.count)) { offset, count in
            bytesFetched += Int(count)
            return file.subdata(in: Int(offset)..<Int(offset + count))
        }
        #expect(bytesFetched < 3_000)
        #expect(fields.filter { $0.role == .translation }.map(\.text) == [translation, otherTranslation])
        #expect(fields.filter { $0.role == .translation }.map(\.languageCode) == ["en", "en"])
        #expect(fields.contains { $0.name == "巷口.ttml" && $0.text == xml })
        #expect(fields.contains { $0.name == "巷口.lrc" && $0.text == lrc })
        #expect(fields.count == 5)
        let track = try #require(fields.first { $0.name == "Lyrics" })
        #expect(track.languageCode == "zh-Hans")
        let line = try #require(LyricsContentParser.parseText(track.text).first)
        #expect(line.text == "岸灯拾起远帆")
        #expect(line.timestamp == 1.75)
        #expect(line.endTimestamp == 2.25)
    }

    @Test func overlappingWebVTTCuesAndMatroskaWordTimes() throws {
        let boxA = box("vttc", box("iden", Data("a".utf8)) + box("payl", Data("芦笛拾光".utf8)))
        let boxB = box("vttc", box("iden", Data("b".utf8)) + box("payl", Data("桥影入梦".utf8)))
        let split: [EmbeddedMediaLyricReader.Sample] = [.init(start: 1, end: 2, data: boxA),
            .init(start: 2, end: 3, data: boxA + boxB), .init(start: 3, end: 4, data: boxB)]
        let vtt = try #require(EmbeddedMediaLyricReader.document(codec: .webVTTBoxes, samples: split))
        let cues = LyricsContentParser.parseText(vtt, options: .literal)
        #expect(cues.map(\.text) == ["芦笛拾光", "桥影入梦"])
        #expect(cues.map(\.endTimestamp) == [3, 4])

        let packet = EmbeddedMediaLyricReader.Sample(start: 12, end: 14, data: Data("折扇<00:00:00.600>落在船头".utf8))
        let matroska = try #require(EmbeddedMediaLyricReader.document(codec: .webVTT, samples: [packet]))
        #expect(LyricsContentParser.parseText(matroska).first?.syllables?.last?.start == 12.6)

        let usf = Data(#"<image>cover.jpg</image><karaoke><k t="350"/>流萤<k t="600"/><b>过桥</b></karaoke>"#.utf8)
        let xml = try #require(EmbeddedMediaLyricReader.document(codec: .usf, samples: [.init(start: 3, end: 4, data: usf)]))
        let line = try #require(LyricsContentParser.parseText(xml).first)
        #expect(line.text == "流萤过桥")
        #expect(line.syllables?.map(\.start) == [3, 3.35])
        #expect(line.syllables?.last?.end == 3.95)
    }

    @Test func matroskaSkipsMovieCaptionsAndChapterScopedTags() async throws {
        let tracks = ebml(0x1654AE6B, mkTrack(1, type: 1, codec: "V_AV1") + mkTrack(2, type: 2, codec: "A_FLAC")
                            + mkTrack(3, type: 17, codec: "S_TEXT/UTF8", name: "English"))
        let chapterRef = ebml(0x63C0, ebml(0x63C4, integer(10, 1)))
        let tags = ebml(0x1254C367, ebml(0x7373, chapterRef + simpleTag("LYRICS", "海堤的章节", language: "zh")))
        let caption = attached("captions.vtt", mime: "text/vtt", bytes: Data("WEBVTT\n\n00:01.000 --> 00:02.000\n留在影片".utf8))
        let lyric = attached("码头.lrc", mime: "text/plain", bytes: Data("[00:01]堤边的砂钟".utf8))
        let file = ebml(0x1A45DFA3, Data()) + ebml(0x18538067, tracks + tags + ebml(0x1941A469, caption + lyric))
        let fields = try await EmbeddedMediaLyricReader.matroska(head: file, fileSize: Int64(file.count)) { _, _ in
            Issue.record("The supplied data contains all metadata")
            return Data()
        }
        #expect(fields.map(\.name) == ["码头.lrc"])
    }

    @Test func matroskaRestoresFrameHeadersAndZlibInDeclaredOrder() async throws {
        let prefix = Data("纸帆".utf8)
        let stripping = contentEncoding(order: 0, algorithm: 3, settings: prefix)
        // An encrypted CodecPrivate does not modify a frame. Scope 3 on zlib does include frames.
        let privateOnly = contentEncoding(order: 2, scope: 2, type: 1)
        let compressed = contentEncoding(order: 1, scope: 3)
        let track = mkTrack(2, type: 17, codec: "S_TEXT/UTF8", name: "Lyrics", language: "zh",
                            encodings: stripping + privateOnly + compressed)
        let allHeader = mkTrack(3, type: 17, codec: "S_TEXT/UTF8", name: "Translation", language: "en",
                                encodings: contentEncoding(order: 0, algorithm: 3, settings: Data("Paper sails".utf8)))
        let file = matroska(tracks: track + allHeader,
                            blocks: subtitleBlock(2, compressedFrame(Data("寻岸".utf8))) + subtitleBlock(3, Data()))
        let fields = try await EmbeddedMediaLyricReader.matroska(head: file, fileSize: Int64(file.count)) { _, _ in Data() }
        #expect(fields.map(\.languageCode) == ["zh", "en"])
        #expect(fields.map(\.role) == [.original, .translation])
        #expect(fields.compactMap { LyricsContentParser.parseText($0.text).first?.text } == ["纸帆寻岸", "Paper sails"])
    }

    @Test func invalidOrOversizeCompressedFramesDoNotPublishPartialTracks() async throws {
        let zlib = contentEncoding(order: 0)
        let bad = mkTrack(2, type: 17, codec: "S_TEXT/UTF8", name: "Lyrics", encodings: zlib)
        let large = mkTrack(3, type: 17, codec: "S_TEXT/UTF8", name: "Lyrics", encodings: zlib)
        let unaffected = mkTrack(4, type: 17, codec: "S_TEXT/UTF8", name: "Lyrics", encodings: zlib)
        let validFirstFrame = compressedFrame(Data("风捎来一枚叶笺".utf8))
        let oversize = compressedFrame(Data(repeating: 65, count: LyricsRawDocumentPolicy.maximumByteCount + 1))
        let broken = subtitleBlock(2, validFirstFrame) + subtitleBlock(2, Data(validFirstFrame.dropLast()))
        let file = matroska(tracks: bad + large + unaffected,
                            blocks: broken + subtitleBlock(3, oversize) + subtitleBlock(4, compressedFrame(Data("晨光停在水车上".utf8))))
        let fields = try await EmbeddedMediaLyricReader.matroska(head: file, fileSize: Int64(file.count)) { _, _ in Data() }
        #expect(fields.count == 1)
        #expect(fields.first.flatMap { LyricsContentParser.parseText($0.text).first?.text } == "晨光停在水车上")
    }

    private func contentEncoding(order: Int, scope: Int = 1, type: Int = 0, algorithm: Int = 0, settings: Data = Data()) -> Data {
        let header = ebml(0x5031, integer(order, 1)) + ebml(0x5032, integer(scope, 1))
        let options = algorithm == 0 ? Data() : ebml(0x4254, integer(algorithm, 1)) + ebml(0x4255, settings)
        return ebml(0x6240, header + ebml(0x5033, integer(type, 1)) + (type == 0 ? ebml(0x5034, options) : ebml(0x5035, Data())))
    }

    private func compressedFrame(_ bytes: Data) -> Data {
        var size = compressBound(uLong(bytes.count))
        var data = Data(count: Int(size))
        let status = data.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { source in
                compress2(destination.bindMemory(to: Bytef.self).baseAddress, &size,
                          source.bindMemory(to: Bytef.self).baseAddress, uLong(bytes.count), Z_DEFAULT_COMPRESSION)
            }
        }
        precondition(status == Z_OK)
        return Data(data.prefix(Int(size)))
    }

    private func matroska(tracks: Data, blocks: Data) -> Data {
        let entries = ebml(0x1654AE6B, mkTrack(1, type: 2, codec: "A_FLAC") + tracks)
        return ebml(0x1A45DFA3, Data()) + ebml(0x18538067, entries + ebml(0x1F43B675, ebml(0xE7, integer(1000, 2)) + blocks))
    }

    private func subtitleBlock(_ track: UInt8, _ bytes: Data) -> Data {
        ebml(0xA0, ebml(0xA1, Data([track | 0x80, 0, 0, 0]) + bytes) + ebml(0x9B, integer(500, 2)))
    }

    private func containerTrack(type: String, referencesChapter: Int? = nil) -> Data {
        let hdlr = box("hdlr", Data(repeating: 0, count: 8) + Data(type.utf8))
        let ref = referencesChapter.map { box("tref", box("chap", integer($0, 4))) } ?? Data()
        return box("trak", ref + box("mdia", hdlr))
    }

    private func isoTrack(number: Int, codec: String, name: String, offset: Int, size: Int, xmlSize: Int? = nil, fragmented: Bool = false) -> Data {
        let tkhd = box("tkhd", Data(repeating: 0, count: 12) + integer(number, 4))
        let hdlr = box("hdlr", Data(repeating: 0, count: 8) + Data("subt".utf8) + Data(repeating: 0, count: 12) + Data(name.utf8))
        let packedLanguage = (26 << 10) | (8 << 5) | 15 // zho
        let mdhd = box("mdhd", Data(repeating: 0, count: 12) + integer(1000, 4) + integer(1250, 4) + integer(packedLanguage, 2))
        let oneEntry = integer(0, 4) + integer(1, 4)
        let stsd = box("stsd", oneEntry + box(codec, Data(repeating: 0, count: 8)))
        let stsc = box("stsc", oneEntry + integer(1, 4) + integer(1, 4) + integer(1, 4))
        let stsz = box("stsz", integer(0, 4) + integer(size, 4) + integer(1, 4))
        let stts = box("stts", oneEntry + integer(1, 4) + integer(1250, 4))
        let co64 = box("co64", oneEntry + integer(offset, 8))
        let subs = xmlSize.map { n in
            let entries = integer(1, 4) + integer(2, 2) + integer(n, 2) + Data(repeating: 0, count: 6)
                + integer(size - n, 2) + Data(repeating: 0, count: 6)
            return box("subs", oneEntry + entries)
        } ?? Data()
        let empty = integer(0, 8)
        let tables = fragmented ? box("stsc", empty) + box("stsz", integer(0, 4) + empty) + box("stts", empty) + box("stco", empty)
                                : stsc + stsz + stts + co64 + subs
        let stbl = box("stbl", stsd + tables)
        return box("trak", tkhd + box("mdia", hdlr + mdhd + box("minf", stbl)))
    }

    private func mkTrack(_ number: Int, type: Int, codec: String, name: String = "", language: String = "und", encodings: Data = Data()) -> Data {
        let info = ebml(0xD7, integer(number, 1)) + ebml(0x83, integer(type, 1)) + ebml(0x86, Data(codec.utf8))
        let storage = encodings.isEmpty ? Data() : ebml(0x6D80, encodings)
        return ebml(0xAE, info + ebml(0x536E, Data(name.utf8)) + ebml(0x22B59D, Data(language.utf8)) + storage)
    }

    private func attached(_ name: String, mime: String, bytes: Data) -> Data {
        ebml(0x61A7, ebml(0x466E, Data(name.utf8)) + ebml(0x4660, Data(mime.utf8)) + ebml(0x465C, bytes))
    }

    private func simpleTag(_ name: String, _ text: String, language: String) -> Data {
        ebml(0x67C8, ebml(0x45A3, Data(name.utf8)) + ebml(0x447B, Data(language.utf8)) + ebml(0x4487, Data(text.utf8)))
    }

    private func box(_ type: String, _ body: Data) -> Data {
        integer(body.count + 8, 4) + Data(type.utf8) + body
    }

    private func ebml(_ id: Int, _ body: Data) -> Data {
        let length = (1...8).first { body.count < (1 << (7 * $0)) - 1 }!
        let idBytes = (Int.bitWidth - id.leadingZeroBitCount + 7) / 8
        return integer(id, idBytes) + integer((1 << (7 * length)) | body.count, length) + body
    }

    private func integer(_ value: Int, _ count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
}
