#if canImport(BackgroundAssets) && !os(watchOS)
import BackgroundAssets
import Foundation
import Testing
@testable import PrimuseKit

@Suite("Apple-hosted model discovery")
struct AppleHostedAssetPackResolverTests {
    private let id = "KaraokeVocalModel"

    @available(iOS 26.4, macOS 26.4, tvOS 26.4, *)
    private actor Catalog {
        var visible: Bool
        let published: Bool
        let refreshError: (any Error)?
        var calls: [String] = []

        init(visible: Bool = false, published: Bool = true, refreshError: (any Error)? = nil) {
            self.visible = visible
            self.published = published
            self.refreshError = refreshError
        }

        func lookup(_ id: String) throws -> String {
            calls.append("lookup:\(id)")
            guard visible else { throw ManagedBackgroundAssetsError.assetPackNotFound(withID: id) }
            return id
        }

        func refresh() throws {
            calls.append("refresh")
            if let refreshError { throw refreshError }
            visible = published
        }
    }

    @available(iOS 26.4, macOS 26.4, tvOS 26.4, *)
    private func resolve(_ catalog: Catalog) async throws -> String {
        try await AppleHostedAssetPackResolver.resolve(
            withID: id,
            lookup: { try await catalog.lookup($0) },
            refresh: { try await catalog.refresh() }
        )
    }

    @available(iOS 26.4, macOS 26.4, tvOS 26.4, *)
    @Test func knownPackDoesNotRefreshOtherModels() async throws {
        let catalog = Catalog(visible: true)
        #expect(try await resolve(catalog) == id)
        #expect(await catalog.calls == ["lookup:\(id)"])
    }

    @available(iOS 26.4, macOS 26.4, tvOS 26.4, *)
    @Test func newlyPublishedPackIsDiscoveredWithoutReinstalling() async throws {
        let catalog = Catalog()
        #expect(try await resolve(catalog) == id)
        #expect(await catalog.calls == ["lookup:\(id)", "refresh", "lookup:\(id)"])
    }

    @available(iOS 26.4, macOS 26.4, tvOS 26.4, *)
    @Test func unpublishedChannelFailsAfterOneRefresh() async {
        let catalog = Catalog(published: false)
        do {
            _ = try await resolve(catalog)
            Issue.record("An unpublished pack must remain unavailable")
        } catch ManagedBackgroundAssetsError.assetPackNotFound(let missingID) {
            #expect(missingID == id)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await catalog.calls == ["lookup:\(id)", "refresh", "lookup:\(id)"])
    }

    @available(iOS 26.4, macOS 26.4, tvOS 26.4, *)
    @Test func refreshFailureIsPreserved() async {
        let catalog = Catalog(refreshError: URLError(.notConnectedToInternet))
        await #expect(throws: URLError(.notConnectedToInternet)) {
            _ = try await resolve(catalog)
        }
        #expect(await catalog.calls == ["lookup:\(id)", "refresh"])
    }

    @available(iOS 26.4, macOS 26.4, tvOS 26.4, *)
    @Test func networkFailureDoesNotRefreshOrRetry() async {
        let catalog = Catalog()
        await #expect(throws: URLError(.timedOut)) {
            let _: String = try await AppleHostedAssetPackResolver.resolve(
                withID: id,
                lookup: { _ in throw URLError(.timedOut) },
                refresh: { try await catalog.refresh() }
            )
        }
        #expect(await catalog.calls.isEmpty)
    }

    @available(iOS 26.4, macOS 26.4, tvOS 26.4, *)
    @Test func unrelatedMissingPackDoesNotRefresh() async {
        let catalog = Catalog()
        do {
            let _: String = try await AppleHostedAssetPackResolver.resolve(
                withID: id,
                lookup: { _ in throw ManagedBackgroundAssetsError.assetPackNotFound(withID: "OtherPack") },
                refresh: { try await catalog.refresh() }
            )
            Issue.record("Expected the original missing-pack error")
        } catch ManagedBackgroundAssetsError.assetPackNotFound(let missingID) {
            #expect(missingID == "OtherPack")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await catalog.calls.isEmpty)
    }

    @available(iOS 26.4, macOS 26.4, tvOS 26.4, *)
    @Test func cancellationDuringRefreshPreventsAnotherLookup() async {
        let catalog = Catalog()
        let task = Task {
            let _: String = try await AppleHostedAssetPackResolver.resolve(
                withID: id,
                lookup: { try await catalog.lookup($0) },
                refresh: {
                    try await catalog.refresh()
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await catalog.calls == ["lookup:\(id)", "refresh"])
    }
}
#endif
