import Foundation
import Testing
@testable import PrimuseKit

@Suite struct StreamResolverRoutingTests {
    @Test func serviceAndCancellationErrorsDoNotRetireLAN() async throws {
        let errors: [any Error] = [CancellationError(), URLError(.cancelled),
                                  StreamResolveError.authFailed, StreamResolveError.needs2FA,
                                  StreamResolveError.missingCredential,
                                  StreamResolveError.badServerResponse(503), URLError(.serverCertificateUntrusted)]
        for error in errors {
            let runtime = SourceConnectionRuntime()
            let registry = StreamResolverRegistry(runtime: runtime)
            let resolver = RoutingResolver()
            await registry.register(resolver, for: [.smb])
            let source = makeSource()
            let song = Song(id: "song", title: "T", fileFormat: .flac, filePath: "/s.flac", sourceID: source.id)
            _ = try await registry.streamURL(for: song, source: source, credential: nil)
            await resolver.failNext(error)
            do {
                _ = try await registry.streamURL(for: song, source: source, credential: nil)
                Issue.record("Expected original error")
            } catch {}
            let result = try await registry.streamURL(for: song, source: source, credential: nil)
            #expect(result.host == "lan.invalid")
            #expect(await runtime.activeKind(for: source.id) == .localAddress)
            #expect(await resolver.hosts == ["lan.invalid", "lan.invalid", "lan.invalid"])
        }
    }

    @Test func networkFailureUsesFallbackAndKeepsItsRoute() async throws {
        let runtime = SourceConnectionRuntime()
        let registry = StreamResolverRegistry(runtime: runtime, endpointProbe: { endpoint in
            if endpoint.host == "lan.invalid" { throw URLError(.cannotConnectToHost) }
        })
        let resolver = RoutingResolver()
        await registry.register(resolver, for: [.smb])
        let source = makeSource()
        let song = Song(id: "song", title: "T", fileFormat: .flac, filePath: "/s.flac", sourceID: source.id)
        await resolver.failNext(URLError(.networkConnectionLost))
        let result = try await registry.streamURL(for: song, source: source, credential: nil)
        #expect(result.host == "wan.invalid")
        #expect(await runtime.activeKind(for: source.id) == .publicAddress)
        #expect(await resolver.hosts == ["lan.invalid", "wan.invalid"])
    }

    @Test func mediaTimeoutDoesNotRetireReachableEndpoint() async throws {
        let runtime = SourceConnectionRuntime()
        let registry = StreamResolverRegistry(runtime: runtime, endpointProbe: { _ in })
        let resolver = RoutingResolver()
        await registry.register(resolver, for: [.smb])
        let source = makeSource()
        let song = Song(id: "song", title: "T", fileFormat: .flac, filePath: "/s.flac", sourceID: source.id)
        _ = try await registry.streamURL(for: song, source: source, credential: nil)
        await resolver.failNext(URLError(.timedOut))
        do {
            _ = try await registry.streamURL(for: song, source: source, credential: nil)
            Issue.record("Expected media timeout")
        } catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(await runtime.activeKind(for: source.id) == .localAddress)
        let result = try await registry.streamURL(for: song, source: source, credential: nil)
        #expect(result.host == "lan.invalid")
        #expect(await resolver.hosts == ["lan.invalid", "lan.invalid", "lan.invalid"])
    }

    @Test func failedPreflightIsNotImmediatelyProbedAgain() async throws {
        let runtime = SourceConnectionRuntime()
        let probe = RoutingProbe()
        let registry = StreamResolverRegistry(runtime: runtime, endpointProbe: { endpoint in
            await probe.record(endpoint.host)
            if endpoint.host == "lan.invalid" { throw URLError(.timedOut) }
        })
        let resolver = RoutingResolver()
        await registry.register(resolver, for: [.navidrome])
        let source = makeSource(type: .navidrome)
        let song = Song(id: "song", title: "T", fileFormat: .flac, filePath: "/s.flac", sourceID: source.id)
        let result = try await registry.streamURL(for: song, source: source, credential: nil)
        #expect(result.host == "wan.invalid")
        #expect(await probe.hosts == ["lan.invalid", "wan.invalid"])
        #expect(await resolver.hosts == ["wan.invalid"])
    }

    @Test(arguments: [MusicSourceType.navidrome, .smb], [URLError.Code.timedOut, .cannotConnectToHost])
    func networkFailureCooldownMatchesReason(sourceType: MusicSourceType, errorCode: URLError.Code) async throws {
        let runtime = SourceConnectionRuntime()
        let registry = StreamResolverRegistry(runtime: runtime, endpointProbe: { endpoint in
            if endpoint.host == "lan.invalid" { throw URLError(errorCode) }
        })
        let resolver = RoutingResolver()
        if sourceType == .smb {
            await resolver.failNext(URLError(errorCode))
        }
        await registry.register(resolver, for: [sourceType])
        let source = makeSource(type: sourceType)
        let song = Song(id: "song", title: "T", fileFormat: .flac, filePath: "/s.flac", sourceID: source.id)
        let startedAt = Date()
        let result = try await registry.streamURL(for: song, source: source, credential: nil)
        let finishedAt = Date()
        #expect(result.host == "wan.invalid")
        #expect(await runtime.activeKind(for: source.id) == .publicAddress)

        let retryInterval: TimeInterval = errorCode == .timedOut ? 8 : 30
        #expect(await runtime.preferredKind(
            for: source.id,
            availableKinds: [.localAddress, .publicAddress],
            prefersLocalNetwork: true,
            now: startedAt.addingTimeInterval(retryInterval - 1)
        ) == .publicAddress)
        #expect(await runtime.preferredKind(
            for: source.id,
            availableKinds: [.localAddress, .publicAddress],
            prefersLocalNetwork: true,
            now: finishedAt.addingTimeInterval(retryInterval + 1)
        ) == .localAddress)
    }

    @Test func serviceNetworkFailureStillRequiresAnIndependentProbe() async throws {
        let runtime = SourceConnectionRuntime()
        let probe = RoutingProbe()
        let registry = StreamResolverRegistry(runtime: runtime, endpointProbe: { endpoint in
            let attempt = await probe.record(endpoint.host)
            if endpoint.host == "lan.invalid", attempt > 1 { throw URLError(.cannotConnectToHost) }
        })
        let resolver = RoutingResolver()
        await resolver.failNext(URLError(.networkConnectionLost))
        await registry.register(resolver, for: [.navidrome])
        let source = makeSource(type: .navidrome)
        let song = Song(id: "song", title: "T", fileFormat: .flac, filePath: "/s.flac", sourceID: source.id)
        let result = try await registry.streamURL(for: song, source: source, credential: nil)
        #expect(result.host == "wan.invalid")
        #expect(await probe.hosts == ["lan.invalid", "lan.invalid", "wan.invalid"])
        #expect(await resolver.hosts == ["lan.invalid", "wan.invalid"])
    }

    @Test func preflightCancellationAndTrustErrorsDoNotTryFallback() async throws {
        for expected: any Error in [CancellationError(), URLError(.cancelled), URLError(.serverCertificateUntrusted)] {
            let runtime = SourceConnectionRuntime()
            let probe = RoutingProbe()
            let registry = StreamResolverRegistry(runtime: runtime, endpointProbe: { endpoint in
                await probe.record(endpoint.host)
                throw expected
            })
            let resolver = RoutingResolver()
            await registry.register(resolver, for: [.navidrome])
            let source = makeSource(type: .navidrome)
            let song = Song(id: "song", title: "T", fileFormat: .flac, filePath: "/s.flac", sourceID: source.id)
            do {
                _ = try await registry.streamURL(for: song, source: source, credential: nil)
                Issue.record("Expected original probe failure")
            } catch {
                #expect((error as NSError).domain == (expected as NSError).domain)
                #expect((error as NSError).code == (expected as NSError).code)
            }
            #expect(await probe.hosts == ["lan.invalid"])
            #expect(await resolver.hosts.isEmpty)
        }
    }

    @Test func changedNetworkDoesNotReuseOldPreflightFailure() async throws {
        let runtime = SourceConnectionRuntime()
        let probe = RoutingProbe()
        let registry = StreamResolverRegistry(runtime: runtime, endpointProbe: { endpoint in
            let attempt = await probe.record(endpoint.host)
            if attempt == 1 {
                await runtime.observeNetworkPath(prefersLocalNetwork: true, pathChanged: true)
                throw URLError(.timedOut)
            }
        })
        let resolver = RoutingResolver()
        await registry.register(resolver, for: [.navidrome])
        let source = makeSource(type: .navidrome)
        let song = Song(id: "song", title: "T", fileFormat: .flac, filePath: "/s.flac", sourceID: source.id)
        do {
            _ = try await registry.streamURL(for: song, source: source, credential: nil)
            Issue.record("Expected original error while the current endpoint is reachable")
        } catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(await probe.hosts == ["lan.invalid", "lan.invalid"])
        #expect(await resolver.hosts.isEmpty)
        #expect(await runtime.preferredKind(
            for: source.id, availableKinds: [.localAddress, .publicAddress], prefersLocalNetwork: true
        ) == .localAddress)
        let result = try await registry.streamURL(for: song, source: source, credential: nil)
        #expect(result.host == "lan.invalid")
    }

    private func makeSource(type: MusicSourceType = .smb) -> MusicSource {
        MusicSource(id: UUID().uuidString, name: "NAS", type: type,
                    connectionConfiguration: .init(
                        localEndpoint: .init(host: "lan.invalid", port: 445, useSsl: false),
                        publicEndpoint: .init(host: "wan.invalid", port: 445, useSsl: false)))
    }
}

private actor RoutingProbe {
    private(set) var hosts: [String] = []
    @discardableResult
    func record(_ host: String) -> Int {
        hosts.append(host)
        return hosts.filter { $0 == host }.count
    }
}

private actor RoutingResolver: StreamResolver {
    var hosts: [String] = []
    private var error: (any Error)?
    func failNext(_ error: any Error) { self.error = error }
    func streamURL(for song: Song, source: MusicSource, credential: SourceCredential?) async throws -> URL {
        hosts.append(source.host ?? "")
        if let error {
            self.error = nil
            throw error
        }
        return URL(string: "https://\(source.host!)/stream")!
    }
}
