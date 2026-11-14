import Foundation
import Testing
@testable import PrimuseKit

struct MotionArtworkEndpointListTests {
    // MARK: 迁移

    @Test func migratesLegacyEndpointOnceIntoAFixedEntry() throws {
        let migrated = try #require(MotionArtworkEndpointList.migratingLegacyEndpoint(
            storedData: nil,
            legacyEndpoint: "  https://Artwork.Example.test/v1/lookup  "
        ))
        #expect(migrated.endpoints.count == 1)
        let entry = try #require(migrated.endpoints.first)
        #expect(entry.id == MotionArtworkEndpointList.legacyEndpointID)
        #expect(entry.name == "artwork.example.test")
        #expect(entry.url == "https://Artwork.Example.test/v1/lookup")
        #expect(entry.isEnabled)

        // 存下以后（哪怕之后被删空）就不再迁移。
        let stored = try #require(migrated.encodedData())
        #expect(MotionArtworkEndpointList.migratingLegacyEndpoint(
            storedData: stored,
            legacyEndpoint: "https://artwork.example.test/v1/lookup"
        ) == nil)
        let emptied = try #require(MotionArtworkEndpointList().encodedData())
        #expect(MotionArtworkEndpointList.migratingLegacyEndpoint(
            storedData: emptied,
            legacyEndpoint: "https://artwork.example.test/v1/lookup"
        ) == nil)
    }

    @Test func twoDevicesMigrateTheSameLegacyEndpointIdentically() throws {
        let legacy = "https://artwork.example.test/v1/lookup"
        let first = try #require(MotionArtworkEndpointList.migratingLegacyEndpoint(storedData: nil, legacyEndpoint: legacy))
        let second = try #require(MotionArtworkEndpointList.migratingLegacyEndpoint(storedData: nil, legacyEndpoint: legacy))
        #expect(first.encodedData() == second.encodedData())
    }

    @Test func skipsMissingBlankInvalidAndBlockedLegacyEndpoints() {
        for legacy in [
            nil,
            "",
            "   ",
            "not a url",
            "ftp://artwork.example.test/lookup",
            "https://artwork.m8tec.top/api/v1/artwork/search",
            "https://music.apple.com/cn/album/123",
        ] as [String?] {
            #expect(MotionArtworkEndpointList.migratingLegacyEndpoint(storedData: nil, legacyEndpoint: legacy) == nil)
        }
    }

    @Test func legacySourceValueStillDecidesWhetherTheServiceIsOn() {
        #expect(MotionArtworkServiceSource.resolved("", hasConfiguredEndpoints: true) == .custom)
        #expect(MotionArtworkServiceSource.resolved("", hasConfiguredEndpoints: false) == .disabled)
        #expect(MotionArtworkServiceSource.resolved("custom", hasConfiguredEndpoints: false) == .custom)
        #expect(MotionArtworkServiceSource.resolved("disabled", hasConfiguredEndpoints: true) == .disabled)
        #expect(MotionArtworkServiceSource.resolved("m8tec", hasConfiguredEndpoints: true) == .disabled)
    }

    // MARK: 添加与校验

    @Test func addingValidatesEveryEndpointWithTheSameRules() {
        var list = MotionArtworkEndpointList()
        for invalid in [
            "",
            "lookup",
            "ftp://artwork.example.test/lookup",
            "https:/lookup",
            "https://user:secret@artwork.example.test/lookup",
            "https://artwork.example.test/lookup#private",
        ] {
            let result = list.add(name: "", url: invalid)
            #expect(result == .failure(.invalid), "\(invalid)")
        }
        for blocked in [
            "https://apple.com/lookup",
            "https://music.apple.com/cn/album/123",
            "https://is1-ssl.mzstatic.com/image/cover.gif",
            "https://artwork.m8tec.top/api/v1/artwork/search",
        ] {
            let result = list.add(name: "", url: blocked)
            #expect(result == .failure(.blocked), "\(blocked)")
        }
        #expect(list.isEmpty)

        guard case .success(let added) = list.add(name: "  Mine  ", url: " http://localhost:8080/lookup ") else {
            Issue.record("Expected the endpoint to be added")
            return
        }
        #expect(added.name == "Mine")
        #expect(added.url == "http://localhost:8080/lookup")
        let duplicate = list.add(name: "Again", url: "HTTP://LOCALHOST:8080/lookup")
        #expect(duplicate == .failure(.duplicate))

        guard case .success(let unnamed) = list.add(name: " ", url: "https://second.example.test/v1") else {
            Issue.record("Expected the endpoint to be added")
            return
        }
        #expect(unnamed.name == "second.example.test")
        #expect(list.endpoints.map(\.name) == ["Mine", "second.example.test"])
    }

    @Test func blockedHostsAreRejectedEvenWhenSyncedIn() throws {
        let json = """
        {"endpoints":[
          {"id":"a","name":"Blocked","url":"https://music.apple.com/lookup","isEnabled":true},
          {"id":"b","name":"Fine","url":"https://fine.example.test/lookup","isEnabled":true}
        ]}
        """
        let list = MotionArtworkEndpointList(data: Data(json.utf8))
        #expect(list.endpoints.count == 2)
        #expect(list.usableEndpoints.map(\.id) == ["b"])
        #expect(list.endpoints[0].endpointURL == nil)
    }

    // MARK: 顺序

    @Test func usableEndpointsKeepListOrderAndSkipDisabledOnes() {
        var list = makeList(["a", "b", "c", "d"])
        list.setEnabled(false, id: "b")
        #expect(list.usableEndpoints.map(\.id) == ["a", "c", "d"])
        list.setEnabled(true, id: "b")
        #expect(list.usableEndpoints.map(\.id) == ["a", "b", "c", "d"])
    }

    @Test func moveFollowsOnMoveSemantics() {
        var list = makeList(["a", "b", "c", "d"])
        list.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(list.endpoints.map(\.id) == ["b", "c", "a", "d"])
        list.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(list.endpoints.map(\.id) == ["d", "b", "c", "a"])
        // Mac 拖动手柄：往下挪一位传 index + 2，往上挪一位传 index - 1。
        list.move(fromOffsets: IndexSet(integer: 1), toOffset: 3)
        #expect(list.endpoints.map(\.id) == ["d", "c", "b", "a"])
        list.move(fromOffsets: IndexSet(integer: 0), toOffset: -1)
        #expect(list.endpoints.map(\.id) == ["d", "c", "b", "a"])
        list.move(fromOffsets: IndexSet(integer: 9), toOffset: 0)
        #expect(list.endpoints.map(\.id) == ["d", "c", "b", "a"])
        list.remove(id: "c")
        #expect(list.endpoints.map(\.id) == ["d", "b", "a"])
    }

    @Test func asksSourcesInOrderAndStopsAtTheFirstHit() async {
        let list = makeList(["a", "b", "c"])
        var asked: [String] = []
        let found = await MotionArtworkEndpointList.firstFound(in: list.usableEndpoints) { endpoint in
            asked.append(endpoint.id)
            return endpoint.id == "b" ? .found : .missing
        }
        #expect(found?.id == "b")
        #expect(asked == ["a", "b"])
    }

    @Test func fallsThroughEverySourceAndStopsWhenAbandoned() async {
        let list = makeList(["a", "b", "c"])
        var asked: [String] = []
        let none = await MotionArtworkEndpointList.firstFound(in: list.usableEndpoints) { endpoint in
            asked.append(endpoint.id)
            return .missing
        }
        #expect(none == nil)
        #expect(asked == ["a", "b", "c"])

        asked = []
        let abandoned = await MotionArtworkEndpointList.firstFound(in: list.usableEndpoints) { endpoint in
            asked.append(endpoint.id)
            return endpoint.id == "a" ? .abandoned : .found
        }
        #expect(abandoned == nil)
        #expect(asked == ["a"])
    }

    // MARK: 存储格式

    @Test func roundTripsAsAJSONObject() throws {
        var list = makeList(["a", "b"])
        list.setEnabled(false, id: "a")
        let data = try #require(list.encodedData())
        #expect(try JSONSerialization.jsonObject(with: data) is [String: Any])
        #expect(MotionArtworkEndpointList(data: data) == list)
        #expect(MotionArtworkEndpointList(data: nil).isEmpty)
        #expect(MotionArtworkEndpointList(data: Data("garbage".utf8)).isEmpty)
    }

    @Test func decodingSkipsBrokenEntriesAndFillsMissingFields() {
        let json = """
        {"endpoints":[
          {"id":"a","url":"https://first.example.test/lookup"},
          {"name":"No ID","url":"https://broken.example.test/lookup"},
          "not an object",
          {"id":"a","name":"Duplicate","url":"https://dup.example.test/lookup","isEnabled":true},
          {"id":"c","name":"  ","url":"https://third.example.test/lookup","isEnabled":false}
        ], "future": 1}
        """
        let list = MotionArtworkEndpointList(data: Data(json.utf8))
        #expect(list.endpoints.map(\.id) == ["a", "c"])
        #expect(list.endpoints.map(\.name) == ["first.example.test", "third.example.test"])
        #expect(list.endpoints.map(\.isEnabled) == [true, false])
        #expect(list.usableEndpoints.map(\.id) == ["a"])
    }

    private func makeList(_ ids: [String]) -> MotionArtworkEndpointList {
        var list = MotionArtworkEndpointList()
        for id in ids {
            list.add(name: id, url: "https://\(id).example.test/lookup", id: id)
        }
        return list
    }
}
