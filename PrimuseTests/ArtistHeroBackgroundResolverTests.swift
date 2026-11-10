import Foundation
import CoreGraphics
import XCTest
import PrimuseKit
@testable import Primuse

final class ArtistHeroBackgroundResolverTests: XCTestCase {
    func testOfflineLookupDoesNotStartCatalogRequest() async throws {
        let fixture = try ArtistMetadataAdmissionFixture()
        defer { fixture.cleanUp() }
        let value = await fixture.resolver.resolve(artistName: "Offline Artist", image: fixture.image, allowNetwork: false)
        XCTAssertNil(value)
        XCTAssertTrue(fixture.trace.started.isEmpty)
    }

    func testOfficialBackgroundRequiresMatchingPhotograph() async throws {
        let fixture = try ArtistMetadataAdmissionFixture()
        defer { fixture.cleanUp() }
        let signature = try XCTUnwrap(ArtistHeroPhotoVerification.signature(image: fixture.image))
        let color = ArtistHeroArtworkColor(red: 0.2, green: 0.3, blue: 0.4)
        let matching = ArtistHeroBackgroundResolver { _ in .init(color: color, signature: signature) }
        let accepted = await matching.resolve(artistName: "Paper Lantern", image: fixture.image, allowNetwork: true)
        XCTAssertEqual(accepted, color)
        let cached = await matching.resolve(artistName: "Paper Lantern", image: fixture.image, allowNetwork: false)
        XCTAssertEqual(cached, color)
        let different = try XCTUnwrap(ArtistHeroPhotoSignature(samples: signature.samples, aspectRatio: 2))
        let mismatched = ArtistHeroBackgroundResolver { _ in .init(color: color, signature: different) }
        let rejected = await mismatched.resolve(artistName: "Paper Lantern", image: fixture.image, allowNetwork: true)
        XCTAssertNil(rejected)
    }

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

    func testWaitingColorRequestsCoalesceAndCacheMissForSameArtist() async throws {
        let fixture = try ArtistMetadataAdmissionFixture()
        defer { fixture.cleanUp() }
        let first = fixture.lookup("first")
        let second = fixture.lookup("second")
        try await fixture.waitForStarts(2)
        let color = fixture.lookup("shared")
        let resolver = fixture.resolver
        let image = fixture.image
        let name = fixture.name("shared")
        let repeated = Task { await resolver.resolve(artistName: name, image: image, allowNetwork: true) }
        try await Task.sleep(for: .milliseconds(100))
        fixture.trace.release(fixture.name("first"))
        try await fixture.waitForStarts(3)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.trace.count(for: name), 1)
        fixture.trace.releaseAll()
        _ = await (first.value, second.value, color.value, repeated.value)
        // The empty response is a completed negative cache entry. A waiter
        // arriving after completion must not perform a second lookup either.
        _ = await resolver.resolve(artistName: name, image: image, allowNetwork: true)
        XCTAssertEqual(fixture.trace.count(for: name), 1)
        XCTAssertEqual(fixture.trace.maximumActive, 2)
    }
}

/// Hold injected MusicKit lookups to exercise admission and coalescing without network access.
private final class ArtistMetadataAdmissionFixture: @unchecked Sendable {
    let prefix = "admission-\(UUID().uuidString)-"
    let trace = ArtistMetadataAdmissionTrace()
    let resolver: ArtistHeroBackgroundResolver
    let image: CGImage

    init() throws {
        let trace = trace
        resolver = ArtistHeroBackgroundResolver { name in
            await withCheckedContinuation { continuation in
                trace.start(name) { continuation.resume(returning: nil) }
            }
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        image = try XCTUnwrap(context.makeImage())
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
        XCTAssertEqual(trace.started.count, count, "Expected MusicKit lookups to reach the injected provider")
        if trace.started.count != count { throw URLError(.timedOut) }
    }

    func cleanUp() {
        trace.releaseAll()
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
