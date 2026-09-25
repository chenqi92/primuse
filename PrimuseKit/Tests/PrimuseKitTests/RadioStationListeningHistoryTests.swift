import Foundation
import Testing
@testable import PrimuseKit

@Suite("Radio heard titles")
struct RadioHeardTitlePolicyTests {
    private func entry(_ text: String, _ seconds: TimeInterval) -> RadioHeardTitle {
        RadioHeardTitle(text: text, heardAt: Date(timeIntervalSince1970: seconds))
    }

    @Test("newest first, repeated pushes of the latest title are ignored")
    func dedupesLatest() throws {
        var log = try #require(RadioHeardTitlePolicy.recording(entry("Air - La Femme", 10), stationID: "a", in: [:]))
        #expect(RadioHeardTitlePolicy.recording(entry("  air - la femme ", 20), stationID: "a", in: log) == nil)
        log = try #require(RadioHeardTitlePolicy.recording(entry("Cee Lo - Fool", 30), stationID: "a", in: log))
        #expect(log["a"]?.entries.map(\.text) == ["Cee Lo - Fool", "Air - La Femme"])
        #expect(log["a"]?.updatedAt == Date(timeIntervalSince1970: 30))
        // An older title coming back later is a new airing, not a duplicate.
        log = try #require(RadioHeardTitlePolicy.recording(entry("Air - La Femme", 40), stationID: "a", in: log))
        #expect(log["a"]?.entries.count == 3)
    }

    @Test("blank titles and empty station ids are not recorded")
    func ignoresBlank() {
        #expect(RadioHeardTitlePolicy.recording(entry("   ", 1), stationID: "a", in: [:]) == nil)
        #expect(RadioHeardTitlePolicy.recording(entry("Song", 1), stationID: "", in: [:]) == nil)
    }

    @Test("entries per station are capped")
    func capsEntries() throws {
        var log: [String: RadioStationHeardTitles] = [:]
        for index in 0..<8 {
            log = try #require(RadioHeardTitlePolicy.recording(
                entry("Song \(index)", Double(index)), stationID: "a", in: log, maximumEntries: 5
            ))
        }
        #expect(log["a"]?.entries.map(\.text) == ["Song 7", "Song 6", "Song 5", "Song 4", "Song 3"])
    }

    @Test("least recently written stations are evicted, the one just written is kept")
    func evictsStations() throws {
        var log: [String: RadioStationHeardTitles] = [:]
        for index in 0..<4 {
            log = try #require(RadioHeardTitlePolicy.recording(
                entry("Song", Double(index * 10)), stationID: "s\(index)", in: log, maximumStations: 3
            ))
        }
        #expect(Set(log.keys) == ["s1", "s2", "s3"])
        // A write with an old timestamp still keeps its own station.
        log = try #require(RadioHeardTitlePolicy.recording(
            entry("Other", 0), stationID: "s9", in: log, maximumStations: 3
        ))
        #expect(log["s9"] != nil)
        #expect(log.count == 3)
        #expect(log["s1"] == nil)
    }

    @Test("sanitizing drops empty stations, sorts and caps entries")
    func sanitizes() {
        let log: [String: RadioStationHeardTitles] = [
            "a": RadioStationHeardTitles(entries: [entry("Old", 1), entry("New", 5), entry(" ", 9)], updatedAt: Date(timeIntervalSince1970: 5)),
            "b": RadioStationHeardTitles(entries: [], updatedAt: Date(timeIntervalSince1970: 7)),
            "": RadioStationHeardTitles(entries: [entry("X", 1)], updatedAt: Date(timeIntervalSince1970: 1)),
        ]
        let cleaned = RadioHeardTitlePolicy.sanitized(log, maximumEntries: 1)
        #expect(Array(cleaned.keys) == ["a"])
        #expect(cleaned["a"]?.entries.map(\.text) == ["New"])
    }

    @Test("round-trips through JSON")
    func codable() throws {
        let log = ["a": RadioStationHeardTitles(entries: [entry("Song", 3)], updatedAt: Date(timeIntervalSince1970: 3))]
        let data = try JSONEncoder().encode(log)
        let decoded = try JSONDecoder().decode([String: RadioStationHeardTitles].self, from: data)
        #expect(decoded == log)
    }
}

@Suite("Radio station recency")
struct RadioStationRecencyPolicyTests {
    private struct Item: Identifiable, Equatable {
        let id: String
        let played: TimeInterval?
    }

    private let items = [
        Item(id: "p1", played: nil),
        Item(id: "p2", played: 20),
        Item(id: "p3", played: nil),
        Item(id: "p4", played: 50),
        Item(id: "p5", played: 20),
    ]

    private func played(_ item: Item) -> Date? {
        item.played.map { Date(timeIntervalSince1970: $0) }
    }

    @Test("recent lists only played stations, newest first, ties keep priority order")
    func recent() {
        #expect(RadioStationRecencyPolicy.recent(items, lastPlayedAt: played).map(\.id) == ["p4", "p2", "p5"])
        #expect(RadioStationRecencyPolicy.recent(items, limit: 1, lastPlayedAt: played).map(\.id) == ["p4"])
        #expect(RadioStationRecencyPolicy.recent(items, limit: 0, lastPlayedAt: played).isEmpty)
    }

    @Test("strip puts recent stations first, then fills in priority order without duplicates")
    func strip() {
        #expect(RadioStationRecencyPolicy.strip(items, lastPlayedAt: played).map(\.id) == ["p4", "p2", "p5", "p1", "p3"])
        #expect(RadioStationRecencyPolicy.strip(items, limit: 4, lastPlayedAt: played).map(\.id) == ["p4", "p2", "p5", "p1"])
        #expect(RadioStationRecencyPolicy.strip(items, limit: 2, lastPlayedAt: played).map(\.id) == ["p4", "p2"])
        let neverPlayed = items.map { Item(id: $0.id, played: nil) }
        #expect(RadioStationRecencyPolicy.strip(neverPlayed, limit: 3, lastPlayedAt: played).map(\.id) == ["p1", "p2", "p3"])
    }
}
