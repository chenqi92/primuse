import Foundation
import Network
import Testing
@testable import PrimuseKit

@Suite("Wi-Fi transfer")
struct WiFiTransferTests {
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("primuse-wifi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func folderUploadKeepsUnicodeAndIndependentLyrics() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try WiFiTransferFiles(root: root)
        let data = Data(repeating: 42, count: 128 * 1024)
        let upload = try files.beginUpload(path: "音乐/专辑 & 现场/01 + Song.FLAC", size: Int64(data.count))
        try upload.append(data.prefix(17))
        #expect(try files.list("").isEmpty)
        try upload.append(data.dropFirst(17))
        try files.commit(upload)
        #expect(try Data(contentsOf: root.appendingPathComponent(upload.path)) == data)
        let lyrics = Data("[00:01.00]Hello".utf8)
        let sidecar = try files.beginUpload(path: "音乐/专辑 & 现场/01 + Song.lrc", size: Int64(lyrics.count))
        try sidecar.append(lyrics)
        try files.commit(sidecar)
        #expect(try files.list("音乐/专辑 & 现场").map(\.name) == ["01 + Song.FLAC", "01 + Song.lrc"])
    }

    @Test(arguments: ["../song.mp3", "/song.mp3", "a/../../song.mp3", "a//song.mp3", "a\\song.mp3", ".hidden/a.mp3", "a/./b.mp3", "a\u{0}b.mp3"])
    func rejectsUnsafePaths(_ path: String) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try WiFiTransferFiles(root: root)
        #expect(throws: WiFiTransferError.invalidPath) { try files.beginUpload(path: path, size: 32) }
    }

    @Test func rejectsSymlinksAndNonMusicFiles() throws {
        let root = try temporaryRoot()
        let outside = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let files = try WiFiTransferFiles(root: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(throws: WiFiTransferError.invalidPath) { try files.beginUpload(path: "link/song.mp3", size: 32) }
        #expect(throws: WiFiTransferError.unsupportedFile) { try files.beginUpload(path: "index.html", size: 32) }
        #expect(try files.list("").isEmpty)
    }

    @Test func incompleteUploadsNeverReplaceCompletedFiles() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try WiFiTransferFiles(root: root)
        var upload: WiFiTransferFiles.Upload? = try files.beginUpload(path: "song.mp3", size: 10)
        let temporary = try #require(upload?.temporaryURL)
        try upload?.append(Data([1, 2, 3]))
        #expect(throws: WiFiTransferError.invalidRequest) { try files.commit(upload!) }
        upload = nil
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(try files.list("").isEmpty)
        let first = try files.beginUpload(path: "song.mp3", size: 1)
        let second = try files.beginUpload(path: "song.mp3", size: 1)
        try first.append(Data([7])); try second.append(Data([9]))
        try files.commit(first)
        #expect(throws: WiFiTransferError.conflict) { try files.commit(second) }
        #expect(try Data(contentsOf: root.appendingPathComponent("song.mp3")) == Data([7]))
        try files.delete("song.mp3")
        let replacement = try files.beginUpload(path: "song.mp3", size: 1)
        try replacement.append(Data([9]))
        try files.commit(replacement)
        #expect(try Data(contentsOf: root.appendingPathComponent("song.mp3")) == Data([9]))
    }

    @Test func validatesSizeAndOnlyDeletesEmptyFolders() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try WiFiTransferFiles(root: root)
        #expect(throws: WiFiTransferError.invalidRequest) { try files.beginUpload(path: "empty.mp3", size: 0) }
        #expect(throws: WiFiTransferError.tooLarge) { try files.beginUpload(path: "huge.mp3", size: WiFiTransferFiles.maximumFileSize + 1) }
        let upload = try files.beginUpload(path: "album/song.mp3", size: 1)
        #expect(throws: WiFiTransferError.invalidRequest) { try upload.append(Data([1, 2])) }
        try upload.append(Data([1])); try files.commit(upload)
        #expect(throws: WiFiTransferError.conflict) { try files.delete("album") }
        try files.delete("album/song.mp3"); try files.delete("album")
        #expect(try files.list("").isEmpty)
        #expect(throws: WiFiTransferError.invalidPath) { try files.delete("") }
    }

    @Test func canonicalRootAliasesAndInterruptedSessionRecovery() throws {
        let root = URL(fileURLWithPath: "/private/tmp/primuse-wifi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent(".wifi-transfer-\(UUID().uuidString)")
        let unrelated = root.appendingPathComponent(".wifi-transfer-\(UUID().uuidString)")
        for directory in [stale, unrelated] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("Primuse Wi-Fi transfer v1".utf8).write(to: stale.appendingPathComponent(".owner"))
        try Data([1, 2, 3]).write(to: stale.appendingPathComponent("partial"))
        let first = try WiFiTransferFiles(root: root)
        let upload = try first.beginUpload(path: "Album/歌曲 + test.lrc", size: 3)
        try upload.append(Data([1, 2, 3]))
        let second = try WiFiTransferFiles(root: root)
        #expect(FileManager.default.fileExists(atPath: upload.temporaryURL.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        try first.commit(upload)
        #expect(try second.list("Album").count == 1)
    }

    @Test func parsesEncodedPathsWithoutDoubleDecoding() throws {
        let request = try WiFiTransferRequest(Data("PUT /api/files?path=Album%2F100%25%20%2B%20Song.lrc HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nContent-Length: 17".utf8))
        #expect(request.path == "Album/100% + Song.lrc")
        #expect(request.contentLength == 17)
    }

    @Test(arguments: [
        "Content-Length: 1\r\nContent-Length: 2", "Content-Length: -1", "Content-Length: 999999999999999999999",
        "Transfer-Encoding: chunked", "Content-Length: +1", "X-Key: a\r\n folded", "Expect: 100-continue"
    ])
    func rejectsAmbiguousHTTPFraming(_ headers: String) throws {
        #expect(throws: WiFiTransferError.invalidRequest) {
            try WiFiTransferRequest(Data("PUT /api/files?path=a.mp3 HTTP/1.1\r\nHost: localhost\r\n\(headers)".utf8))
        }
    }

    @Test func rateLimitsCodeGuessing() throws {
        let now = Date()
        var auth = WiFiTransferAuthorization(code: "123456")
        for _ in 0..<5 { #expect(throws: WiFiTransferError.unauthorized) { try auth.validate("000000", now: now) } }
        #expect(throws: WiFiTransferError.tooManyAttempts) { try auth.validate("123456", now: now.addingTimeInterval(29)) }
        try auth.validate("123456", now: now.addingTimeInterval(31))
    }

    @Test func pageEscapesLocalizedMarkup() {
        let html = WiFiTransferPage.html(strings: ["title": "</script><script>alert(1)</script>"])
        #expect(!html.contains("</script><script>alert(1)"))
        #expect(html.contains("webkitdirectory"))
        #expect(!html.contains("__LABELS__"))
    }

    @Test func managedLocalSourceSurvivesDataContainerUUIDMigration() {
        let oldContainer = "84A53263-830F-49AF-8B0F-6F0442C8F9D1"
        let currentContainer = "31F463AE-70DC-4B0D-8162-A21A391C4520"
        let simulator = "C19E7A74-27C4-4312-9A64-D4C1A31A71F8"
        let currentRoot = "/Users/test/Library/Developer/CoreSimulator/Devices/\(simulator)/data/Containers/Data/Application/\(currentContainer)/Documents/LocalMusic"
        let previousRoot = "/Users/test/Library/Developer/CoreSimulator/Devices/\(simulator)/data/Containers/Data/Application/\(oldContainer)/Documents/LocalMusic"

        func isManaged(
            _ basePath: String?,
            managedRoot: String = currentRoot,
            isLocalSource: Bool = true,
            sourceID: String = "copied",
            persistedID: String? = "copied"
        ) -> Bool {
            DeviceLocalSourcePolicy.isManagedCopy(
                isLocalSource: isLocalSource,
                sourceID: sourceID,
                persistedImportSourceID: persistedID,
                basePath: basePath,
                managedRootPath: managedRoot
            )
        }

        #expect(isManaged(currentRoot))
        #expect(isManaged(previousRoot))
        #expect(isManaged(
            "/private/var/mobile/Containers/Data/Application/\(oldContainer)/Documents/LocalMusic",
            managedRoot: "/var/mobile/Containers/Data/Application/\(currentContainer)/Documents/LocalMusic"
        ))

        let otherSimulatorRoot = "/Users/test/Library/Developer/CoreSimulator/Devices/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/data/Containers/Data/Application/\(oldContainer)/Documents/LocalMusic"
        #expect(!isManaged(otherSimulatorRoot))
        #expect(!isManaged("/private/var/mobile/Library/Mobile Documents/provider/Documents/LocalMusic"))
        #expect(!isManaged("/Users/test/Documents/LocalMusic"))
        #expect(!isManaged("/private/var/mobile/Containers/Data/Application/not-a-uuid/Documents/LocalMusic",
                           managedRoot: "/private/var/mobile/Containers/Data/Application/also-not-a-uuid/Documents/LocalMusic"))
        #expect(!isManaged(currentRoot + "/Album"))
        #expect(!isManaged(currentRoot, isLocalSource: false))
        #expect(!isManaged(currentRoot, sourceID: "other"))
        #expect(!isManaged(currentRoot, persistedID: nil))
    }

    @Test(.timeLimit(.minutes(1))) func realHTTPUploadListDeleteAndAuthorization() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (events, continuation) = AsyncStream.makeStream(of: WiFiTransferServer.Event.self)
        let server = WiFiTransferServer(root: root, page: WiFiTransferPage.html(), testingHost: "127.0.0.1") { continuation.yield($0) }
        server.start()
        defer { server.stop(); continuation.finish() }
        var iterator = events.makeAsyncIterator()
        guard case .ready(let address) = await iterator.next() else { Issue.record("Listener failed to start"); return }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func send(_ method: String, path: String = "", body: Data? = nil, code: String? = nil, origin: String? = nil) async throws -> (Data, Int) {
            var components = URLComponents(string: address + "/api/files")!
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.httpBody = body
            request.setValue(code, forHTTPHeaderField: "X-Primuse-Code")
            request.setValue(origin, forHTTPHeaderField: "Origin")
            let (data, response) = try await session.data(for: request)
            return (data, (response as! HTTPURLResponse).statusCode)
        }
        #expect(try await send("GET").1 == 401)
        #expect(try await send("GET", code: server.accessCode, origin: "https://example.com").1 == 401)
        let bytes = Data(repeating: 91, count: 256 * 1024)
        #expect(try await send("PUT", path: "Folder/song.mp3", body: bytes, code: server.accessCode).1 == 201)
        #expect(try Data(contentsOf: root.appendingPathComponent("Folder/song.mp3")) == bytes)
        let listing = try await send("GET", path: "Folder", code: server.accessCode)
        #expect(try JSONDecoder().decode([WiFiTransferFile].self, from: listing.0).first?.name == "song.mp3")
        #expect(try await send("PUT", path: "Folder/song.mp3", body: bytes, code: server.accessCode).1 == 409)
        #expect(try await send("DELETE", path: "Folder/song.mp3", code: server.accessCode).1 == 200)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/song.mp3").path))
        #expect(try await send("PUT", path: "Folder/song.mp3", body: bytes, code: server.accessCode).1 == 201)
    }

    @Test(.timeLimit(.minutes(1))) func nativeTransferRequiresApprovalAndCompletesWithinBudget() async throws {
        let root = try temporaryRoot()
        let source = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        let audio = Data(repeating: 37, count: 96 * 1024)
        let lyrics = Data("[00:01.00]native transfer".utf8)
        let audioURL = source.appendingPathComponent("A + Song.wav")
        let lyricsURL = source.appendingPathComponent("A + Song.lrc")
        try audio.write(to: audioURL)
        try lyrics.write(to: lyricsURL)

        let (events, continuation) = AsyncStream.makeStream(of: WiFiTransferServer.Event.self)
        let server = WiFiTransferServer(root: root, page: WiFiTransferPage.html(), testingHost: "127.0.0.1") {
            continuation.yield($0)
        }
        server.start()
        defer { server.stop(); continuation.finish() }
        var iterator = events.makeAsyncIterator()
        guard case .ready(let address) = await iterator.next() else {
            Issue.record("Listener failed to start")
            return
        }
        let client = try WiFiTransferClient(address: address, code: server.accessCode)
        #expect(try await client.destination().availableBytes > 0)

        let denied = try await client.invite(sender: "发送者 & Mac", fileCount: 2,
                                             byteCount: Int64(audio.count + lyrics.count))
        guard case .invitation(let deniedInvitation) = await iterator.next() else {
            Issue.record("Invitation event was not delivered")
            return
        }
        #expect(deniedInvitation.id == denied.id)
        #expect(deniedInvitation.sender == "发送者 & Mac")
        #expect(deniedInvitation.fileCount == 2)
        #expect(deniedInvitation.byteCount == Int64(audio.count + lyrics.count))
        await #expect(throws: WiFiTransferError.unauthorized) {
            try await client.upload(file: audioURL, path: "Album QA/Live & 中文/A + Song.wav",
                                    size: Int64(audio.count), ticket: denied.id) { _ in }
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Album QA/Live & 中文/A + Song.wav").path
        ))
        server.answer(invitationID: denied.id, accepted: false)
        await #expect(throws: WiFiTransferError.rejected) {
            try await client.waitForAcceptance(denied.id)
        }
        guard case .transferEnded = await iterator.next() else {
            Issue.record("Rejected transfer did not end")
            return
        }

        let accepted = try await client.invite(sender: "发送者 & Mac", fileCount: 2,
                                               byteCount: Int64(audio.count + lyrics.count))
        guard case .invitation(let acceptedInvitation) = await iterator.next() else {
            Issue.record("Second invitation event was not delivered")
            return
        }
        server.answer(invitationID: acceptedInvitation.id, accepted: true)
        try await client.waitForAcceptance(accepted.id)
        try await client.upload(file: audioURL, path: "Album QA/Live & 中文/A + Song.wav",
                                size: Int64(audio.count), ticket: accepted.id) { _ in }
        try await client.upload(file: lyricsURL, path: "Album QA/Live & 中文/A + Song.lrc",
                                size: Int64(lyrics.count), ticket: accepted.id) { _ in }
        #expect(try Data(contentsOf: root.appendingPathComponent("Album QA/Live & 中文/A + Song.wav")) == audio)
        #expect(try Data(contentsOf: root.appendingPathComponent("Album QA/Live & 中文/A + Song.lrc")) == lyrics)
        await #expect(throws: WiFiTransferError.invalidRequest) {
            try await client.upload(file: lyricsURL, path: "Album QA/extra.lrc",
                                    size: Int64(lyrics.count), ticket: accepted.id) { _ in }
        }
        await client.finish(accepted.id)
        await #expect(throws: WiFiTransferError.notFound) {
            try await client.waitForAcceptance(accepted.id)
        }
    }

    @Test(.timeLimit(.minutes(1))) func nativeBudgetAndBrowserAccessAreIndependent() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (events, continuation) = AsyncStream.makeStream(of: WiFiTransferServer.Event.self)
        let server = WiFiTransferServer(root: root, page: "<p>browser</p>", testingHost: "127.0.0.1") {
            continuation.yield($0)
        }
        server.start()
        defer { server.stop(); continuation.finish() }
        var iterator = events.makeAsyncIterator()
        guard case .ready(let address) = await iterator.next() else {
            Issue.record("Listener failed to start")
            return
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func send(_ method: String, route: String, path: String = "", body: Data? = nil,
                  code: String? = nil, ticket: String? = nil,
                  headers: [String: String] = [:]) async throws -> (Data, Int) {
            var components = URLComponents(string: address + route)!
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.httpBody = body
            request.setValue(code, forHTTPHeaderField: "X-Primuse-Code")
            request.setValue(ticket, forHTTPHeaderField: "X-Primuse-Transfer")
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await session.data(for: request)
            return (data, (response as! HTTPURLResponse).statusCode)
        }

        server.setBrowserEnabled(false)
        let pageDisabled = try await send("GET", route: "/")
        #expect(pageDisabled.1 == 401)
        #expect(try JSONDecoder().decode([String: String].self, from: pageDisabled.0)["error"] == "browserDisabled")
        let browserUploadDisabled = try await send(
            "PUT", route: "/api/files", path: "browser.mp3", body: Data([1]), code: server.accessCode
        )
        #expect(browserUploadDisabled.1 == 401)
        #expect(try await WiFiTransferClient(address: address, code: server.accessCode).destination().availableBytes > 0)

        let invalidInvite = try await send("POST", route: "/api/transfer", code: server.accessCode,
                                           headers: ["X-Primuse-Sender": "Mac",
                                                     "X-Primuse-File-Count": "0",
                                                     "X-Primuse-Byte-Count": "0"])
        #expect(invalidInvite.1 == 400)

        let first = Data([1, 2, 3])
        let second = Data([4, 5])
        let client = try WiFiTransferClient(address: address, code: server.accessCode)
        let ticket = try await client.invite(sender: "Mac", fileCount: 2, byteCount: Int64(first.count))
        guard case .invitation(let invitation) = await iterator.next() else {
            Issue.record("Invitation event was not delivered")
            return
        }
        server.answer(invitationID: invitation.id, accepted: true)
        try await client.waitForAcceptance(ticket.id)
        let firstURL = root.appendingPathComponent("first-source.mp3")
        let secondURL = root.appendingPathComponent("second-source.mp3")
        try first.write(to: firstURL)
        try second.write(to: secondURL)
        try await client.upload(file: firstURL, path: "received/first.mp3", size: Int64(first.count),
                                ticket: ticket.id) { _ in }
        await #expect(throws: WiFiTransferError.invalidRequest) {
            try await client.upload(file: secondURL, path: "received/second.mp3", size: Int64(second.count),
                                    ticket: ticket.id) { _ in }
        }
        await client.finish(ticket.id)

        server.setBrowserEnabled(true)
        #expect(try await send("GET", route: "/").1 == 200)
        #expect(try await send("PUT", route: "/api/files", path: "browser.mp3", body: Data([9]),
                               code: server.accessCode).1 == 201)
    }

    @Test func validatesNativeTransferAddresses() {
        let allowed = [
            "127.0.0.1:8080", "http://10.0.0.4:1", "http://172.16.0.1:65535/",
            "192.168.40.5:57607", "169.254.10.20:1234"
        ]
        for address in allowed { #expect(WiFiTransferClient.localURL(address) != nil) }

        let rejected = [
            "127.0.0.1", "http://127.0.0.1", "http://127.0.0.1:0", "http://127.0.0.1:65536",
            "https://192.168.0.2:80", "http://8.8.8.8:80", "http://localhost:8080",
            "http://user@192.168.0.2:80", "http://192.168.0.2:80/path",
            "http://192.168.0.2:80?code=123456", "http://192.168.0.2:80/#fragment",
            "http://192.168.001.2:80", "http://172.32.0.1:80", "http://169.253.1.1:80"
        ]
        for address in rejected { #expect(WiFiTransferClient.localURL(address) == nil) }
    }

    @Test(.timeLimit(.minutes(1))) func selectionStagesReadsAndCancellationLeavesNoFile() async throws {
        let source = try temporaryRoot()
        let staging = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: staging)
        }
        let album = source.appendingPathComponent("Album QA/Live & 中文")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let audio = Data(repeating: 12, count: 128 * 1024)
        let lyrics = Data("[00:01.00]lyrics".utf8)
        try audio.write(to: album.appendingPathComponent("A + Song.wav"))
        try lyrics.write(to: album.appendingPathComponent("A + Song.lrc"))
        try Data("ignored".utf8).write(to: album.appendingPathComponent("ignored.html"))
        try Data("hidden".utf8).write(to: album.appendingPathComponent(".hidden.mp3"))
        try FileManager.default.createSymbolicLink(
            at: album.appendingPathComponent("linked.mp3"),
            withDestinationURL: album.appendingPathComponent("A + Song.wav")
        )

        let selection = try await WiFiTransferSelection.prepare([album])
        #expect(selection.files.map(\.path) == [
            "Live & 中文/A + Song.lrc", "Live & 中文/A + Song.wav"
        ])
        #expect(selection.byteCount == Int64(audio.count + lyrics.count))
        #expect(selection.skipped == 2)
        let outgoing = try #require(selection.files.first { $0.path.hasSuffix(".wav") })
        let staged = try await WiFiTransferSelection.stage(outgoing, in: staging)
        #expect(try Data(contentsOf: staged) == audio)
        try FileManager.default.removeItem(at: staged)

        let large = source.appendingPathComponent("large.mp3")
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 64 * 1024 * 1024)
        try handle.close()
        let cancellationDirectory = staging.appendingPathComponent("cancelled")
        try FileManager.default.createDirectory(at: cancellationDirectory, withIntermediateDirectories: false)
        let cancellationFile = WiFiTransferOutgoingFile(
            url: large, path: "large.mp3", size: 64 * 1024 * 1024
        )
        let task = Task { try await WiFiTransferSelection.stage(cancellationFile, in: cancellationDirectory) }
        try await Task.sleep(for: .milliseconds(1))
        task.cancel()
        let result = await task.result
        if case .success(let escaped) = result {
            Issue.record("Cancelled staging unexpectedly completed")
            try? FileManager.default.removeItem(at: escaped)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: cancellationDirectory.path).isEmpty)
    }
}
