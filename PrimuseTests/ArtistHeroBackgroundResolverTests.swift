import Foundation
import CoreGraphics
import XCTest
@testable import Primuse

final class ArtistHeroBackgroundResolverTests: XCTestCase {
    func testThirdArtistUsesReleasedSlotWithoutExceedingTwoLookups() async throws {
        let fixture = try ArtistMetadataAdmissionFixture()
        defer { fixture.cleanUp() }
        let first = fixture.lookup("first")
        let second = fixture.lookup("second")
        try await fixture.waitForStarts(2)
        let third = fixture.lookup("third")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.trace.started, [fixture.name("first"), fixture.name("second")].sorted())
        fixture.trace.release(fixture.name("first"))
        try await fixture.waitForStarts(3)
        XCTAssertEqual(fixture.trace.maximumActive, 2)
        XCTAssertEqual(fixture.trace.count(for: fixture.name("third")), 1)
        fixture.trace.releaseAll()
        _ = await (first.value, second.value, third.value)
    }

    func testCancelledWaitingArtistDoesNotStartNetworkLookup() async throws {
        let fixture = try ArtistMetadataAdmissionFixture()
        defer { fixture.cleanUp() }
        let first = fixture.lookup("first")
        let second = fixture.lookup("second")
        try await fixture.waitForStarts(2)
        let cancelled = fixture.lookup("cancelled")
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        _ = await cancelled.value
        fixture.trace.releaseAll()
        _ = await (first.value, second.value)
        XCTAssertEqual(fixture.trace.count(for: fixture.name("cancelled")), 0)
        XCTAssertEqual(fixture.trace.maximumActive, 2)
    }

    func testWaitingColorAndNameRequestsCoalesceForSameArtist() async throws {
        let fixture = try ArtistMetadataAdmissionFixture()
        defer { fixture.cleanUp() }
        let first = fixture.lookup("first")
        let second = fixture.lookup("second")
        try await fixture.waitForStarts(2)
        let color = fixture.lookup("shared")
        let resolver = fixture.resolver
        let image = fixture.image
        let name = fixture.name("shared")
        let logo = Task { await resolver.resolveNameArtwork(artistName: name, image: image, allowNetwork: true) }
        try await Task.sleep(for: .milliseconds(100))
        fixture.trace.release(fixture.name("first"))
        try await fixture.waitForStarts(3)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.trace.count(for: name), 1)
        fixture.trace.releaseAll()
        _ = await (first.value, second.value, color.value, logo.value)
        // The empty response is a completed negative cache entry. A waiter
        // arriving after completion must not perform a second lookup either.
        _ = await resolver.resolveNameArtwork(artistName: name, image: image, allowNetwork: true)
        XCTAssertEqual(fixture.trace.count(for: name), 1)
        XCTAssertEqual(fixture.trace.maximumActive, 2)
    }
}

/// Only the public search endpoint is intercepted. Held responses make slot
/// release deterministic; no account, real artist, image download or timer is
/// needed to observe the production resolver's admission/coalescing behavior.
private final class ArtistMetadataAdmissionFixture: @unchecked Sendable {
    let prefix = "admission-\(UUID().uuidString)-"
    let trace = ArtistMetadataAdmissionTrace()
    let resolver: ArtistHeroBackgroundResolver
    let image: CGImage
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtistMetadataAdmissionProtocol.self]
        resolver = ArtistHeroBackgroundResolver(cacheFileURL: directory.appendingPathComponent("index.json"),
                                                 sessionConfiguration: configuration)
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        image = try XCTUnwrap(context.makeImage())
        ArtistMetadataAdmissionProtocol.registry.register(trace, prefix: prefix)
    }

    func name(_ suffix: String) -> String { prefix + suffix }

    func lookup(_ suffix: String) -> Task<Void, Never> {
        let resolver = resolver, image = image, name = name(suffix)
        return Task { _ = await resolver.resolve(artistName: name, image: image, allowNetwork: true) }
    }

    func waitForStarts(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while trace.started.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(trace.started.count, count, "Expected search requests to reach the controlled endpoint")
        if trace.started.count != count { throw URLError(.timedOut) }
    }

    func cleanUp() {
        trace.releaseAll()
        ArtistMetadataAdmissionProtocol.registry.remove(prefix: prefix)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ArtistMetadataAdmissionTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [String: @Sendable () -> Void] = [:]
    private var counts: [String: Int] = [:]
    private var peak = 0

    var started: [String] { locked { counts.keys.sorted() } }
    var maximumActive: Int { locked { peak } }
    func count(for name: String) -> Int { locked { counts[name, default: 0] } }

    func start(_ name: String, completion: @escaping @Sendable () -> Void) {
        locked {
            counts[name, default: 0] += 1
            completions[name] = completion
            peak = max(peak, completions.count)
        }
    }

    func release(_ name: String) {
        let completion = locked { completions.removeValue(forKey: name) }
        completion?()
    }

    func releaseAll() {
        let pending = locked { let values = Array(completions.values); completions.removeAll(); return values }
        pending.forEach { $0() }
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return operation()
    }
}

private final class ArtistMetadataAdmissionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var traces: [String: ArtistMetadataAdmissionTrace] = [:]
    func register(_ trace: ArtistMetadataAdmissionTrace, prefix: String) {
        lock.lock(); defer { lock.unlock() }; traces[prefix] = trace
    }
    func remove(prefix: String) {
        lock.lock(); defer { lock.unlock() }; traces[prefix] = nil
    }
    func trace(for name: String) -> ArtistMetadataAdmissionTrace? {
        lock.lock(); defer { lock.unlock() }
        return traces.first { name.hasPrefix($0.key) }?.value
    }
}

private final class ArtistMetadataAdmissionProtocol: URLProtocol, @unchecked Sendable {
    static let registry = ArtistMetadataAdmissionRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url, url.host == "itunes.apple.com", url.path == "/search",
              let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "term" })?.value,
              let trace = Self.registry.trace(for: name) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        trace.start(name) { [self] in
            let data = Data(#"{"results":[]}"#.utf8)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)])!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
