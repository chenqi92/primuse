import Foundation
import Testing
@testable import PrimuseKit

@Suite("Top-level JSON array reader")
struct TopLevelJSONArrayReaderTests {
    private struct Item: Codable, Equatable {
        var id: String
        var title: String
        var tags: [String]?
        var nested: [String: [Int]]?
        var addedAt: Date
    }

    private struct Envelope: Codable, Equatable {
        var songs: [Item]
        var playlists: [[String: [String]]]
        var recent: [String]?
    }

    private func items(_ count: Int) -> [Item] {
        (0..<count).map { index in
            Item(
                id: String(format: "%064x", index),
                title: "歌曲 \(index) \"quoted\" / slash \\ back ] } , [ {",
                tags: index.isMultiple(of: 2) ? ["a\\\"", "songs\":[]}"] : nil,
                nested: index.isMultiple(of: 3) ? ["k\(index)": [index, -index]] : nil,
                addedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index))
            )
        }
    }

    private func encoder(_ formatting: JSONEncoder.OutputFormatting) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = formatting
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func readAll(_ reader: TopLevelJSONArrayReader, pageSize: Int) throws -> (items: [Item], pages: Int) {
        var pages = reader.pages(maximumCount: pageSize)
        var collected: [Item] = []
        var count = 0
        while let page = try pages.next() {
            let decoded = try decoder.decode([Item].self, from: page)
            #expect(decoded.count <= pageSize)
            collected += decoded
            count += 1
        }
        #expect(pages.elementCount == collected.count)
        let afterTheEnd = try pages.next()
        #expect(afterTheEnd == nil, "a finished reader stays finished")
        return (collected, count)
    }

    @Test("Pages decode to the whole array in order, the rest decodes to the object with an empty array",
          arguments: [0, 1, 2, 7, 64])
    func pagesEqualTheWholeArray(count: Int) throws {
        let envelope = Envelope(songs: items(count), playlists: [["songs": ["x", "y"]], [:]], recent: ["r"])
        for formatting: JSONEncoder.OutputFormatting in [[.sortedKeys], [], [.prettyPrinted], [.prettyPrinted, .sortedKeys]] {
            let data = try encoder(formatting).encode(envelope)
            let reader = try TopLevelJSONArrayReader(data: data, key: "songs")
            for pageSize in [1, 3, 1000] {
                let (collected, pages) = try readAll(reader, pageSize: pageSize)
                #expect(collected == envelope.songs)
                #expect(pages == (count + pageSize - 1) / pageSize)
            }
            var head = envelope
            head.songs = []
            #expect(try decoder.decode(Envelope.self, from: reader.objectWithEmptyArray()) == head)
        }
    }

    @Test("The key may sit anywhere, be escaped, and be surrounded by values that contain its name")
    func keyPositionAndEscapes() throws {
        let element = #"{"id":"1","title":"a","addedAt":"2023-11-14T22:13:20Z"}"#
        let documents = [
            #"{"songs":[\#(element)],"playlists":[],"recent":["songs"]}"#,
            #"{ "recent" : [ "\"songs\":[" ] , "songs" : [ \#(element) ,\#n \#(element) ] , "playlists" : [ ] }"#,
            #"{"playlists":[{"songs":["x"]}],"songs":[\#(element)]}"#,
        ]
        for document in documents {
            let reader = try TopLevelJSONArrayReader(data: Data(document.utf8), key: "songs")
            let (collected, _) = try readAll(reader, pageSize: 1)
            #expect(!collected.isEmpty)
            #expect(collected.allSatisfy { $0.id == "1" })
            let rest = try JSONSerialization.jsonObject(with: reader.objectWithEmptyArray()) as? [String: Any]
            #expect((rest?.values.compactMap { $0 as? [Any] }.contains { $0.isEmpty }) == true)
        }
    }

    @Test("A slice of a larger buffer reads the same")
    func dataSlice() throws {
        let envelope = Envelope(songs: items(5), playlists: [], recent: nil)
        var buffer = Data("garbage".utf8)
        buffer.append(try encoder([.sortedKeys]).encode(envelope))
        let slice = buffer[7...]
        let reader = try TopLevelJSONArrayReader(data: slice, key: "songs")
        #expect(try readAll(reader, pageSize: 2).items == envelope.songs)
    }

    @Test("Structural errors are reported, never read as a shorter array")
    func errors() throws {
        func open(_ text: String) -> TopLevelJSONArrayReader.ReadError? {
            do {
                let reader = try TopLevelJSONArrayReader(data: Data(text.utf8), key: "songs")
                var pages = reader.pages(maximumCount: 1)
                while try pages.next() != nil {}
                return nil
            } catch let error as TopLevelJSONArrayReader.ReadError {
                return error
            } catch {
                return .malformed(offset: -1)
            }
        }
        #expect(open(#"["songs"]"#) == .notAnObject)
        #expect(open("") == .notAnObject)
        #expect(open(#"{"playlists":[]}"#) == .missingKey)
        #expect(open("{}") == .missingKey)
        #expect(open(#"{"songs":[],"songs":[]}"#) == .duplicateKey)
        #expect(open(#"{"songs":{"a":1}}"#) == .notAnArray)
        #expect(open(#"{"songs":"[]"}"#) == .notAnArray)
        #expect(open(#"{"songs":[1,2}"#) != nil)
        #expect(open(#"{"songs":[1,2]} x"#) != nil)
        #expect(open(#"{"songs":["unterminated]}"#) != nil)
        #expect(open(#"{"songs" [1]}"#) != nil)
        #expect(open(#"{"songs":[1],"x":}"#) != nil)
        #expect(open("{\"songs\":[1]}\n ") == nil, "trailing whitespace is fine")
        #expect(open(#"{"songs":[]}"#) == nil)
        #expect(open(#"{"songs":[ ]}"#) == nil)
    }

    private struct Document: Decodable, Equatable {
        var songs: [Int]
        var x: Int?
    }

    /// 分隔上的出入(多的、少的、开头结尾的逗号)收不收,与整份交给 JSONDecoder 一样:它收的,读出同样的东西;
    /// 它不收的,这里也不收。页大小 1 与 2,让分隔落在页与页之间,也落在页里面。
    @Test("Separators are accepted exactly when JSONDecoder accepts the whole document")
    func separatorsFollowJSONDecoder() {
        let documents = [
            #"{"songs":[1,2,3],"x":1}"#, #"{"songs":[1,2,3,],"x":1}"#, #"{"songs":[1,2,3] ,"x":1,}"#,
            #"{"songs":[1,,2,3]}"#, #"{"songs":[1,2,,3]}"#, #"{"songs":[,1,2,3]}"#, #"{"songs":[,]}"#,
            #"{"songs":[1 2,3]}"#, #"{"songs":[1,2 3]}"#, #"{"x":1 "songs":[1]}"#, #"{,"songs":[1]}"#,
            #"{"songs":[1],,"x":2}"#, #"{"songs":[ 1 , 2 , 3 , ]}"#, #"{"songs":[1,2,3,,]}"#, "{\"songs\":[1,\n2]}",
        ]
        for document in documents {
            let whole = try? JSONDecoder().decode(Document.self, from: Data(document.utf8))
            for pageSize in [1, 2] {
                var paged: Document?
                if let reader = try? TopLevelJSONArrayReader(data: Data(document.utf8), key: "songs"),
                   var head = try? JSONDecoder().decode(Document.self, from: reader.objectWithEmptyArray()) {
                    var pages = reader.pages(maximumCount: pageSize)
                    var songs: [Int]? = []
                    do {
                        while let page = try pages.next() {
                            guard let decoded = try? JSONDecoder().decode([Int].self, from: page) else { songs = nil; break }
                            songs?.append(contentsOf: decoded)
                        }
                    } catch {
                        songs = nil
                    }
                    if let songs {
                        head.songs = songs
                        paged = head
                    }
                }
                #expect(paged == whole, "\(document) pageSize=\(pageSize)")
            }
        }
    }
}
