#if os(iOS)
import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class MotionArtworkEndpointClientTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)

    func testValidatesUserConfiguredEndpointAndUsesEphemeralDefaults() async {
        XCTAssertTrue(MotionArtworkEndpointClient.isValidEndpoint(
            URL(string: "https://motion.example.test/v1/lookup?tenant=user")!
        ))
        XCTAssertTrue(MotionArtworkEndpointClient.isValidEndpoint(
            URL(string: "http://localhost:8080/lookup")!
        ))
        XCTAssertFalse(MotionArtworkEndpointClient.isValidEndpoint(
            URL(string: "ftp://motion.example.test/lookup")!
        ))
        XCTAssertFalse(MotionArtworkEndpointClient.isValidEndpoint(
            URL(string: "https:/lookup")!
        ))
        XCTAssertFalse(MotionArtworkEndpointClient.isValidEndpoint(
            URL(string: "https://user:secret@motion.example.test/lookup")!
        ))
        XCTAssertFalse(MotionArtworkEndpointClient.isValidEndpoint(
            URL(string: "https://motion.example.test/lookup#private")!
        ))

        let configuration = MotionArtworkEndpointClient.ephemeralConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertGreaterThan(configuration.timeoutIntervalForRequest, 0)
        XCTAssertGreaterThan(configuration.timeoutIntervalForResource, 0)

        let client = makeClient()
        await assertClientError(.invalidEndpoint) {
            try await client.lookup(
                endpoint: URL(string: "https://user@motion.example.test/lookup")!,
                input: self.lookupInput(),
                allowExpensiveNetwork: false
            )
        }
    }

    func testLookupPostsVersionedJSONAndAppliesRestrictedNetworkPolicy() async throws {
        let endpoint = URL(string: "https://motion-lookup-success.invalid/custom/motion")!
        let asset = makeAsset(url: URL(string: "https://assets.invalid/cover.webp")!)
        MotionArtworkEndpointURLProtocol.configure(
            url: endpoint,
            body: try serviceResponseData(asset: asset)
        )
        let client = makeClient()

        let result = try await client.lookup(
            endpoint: endpoint,
            input: lookupInput(),
            allowExpensiveNetwork: false
        )

        XCTAssertEqual(result, .asset(asset))
        let request = try XCTUnwrap(
            MotionArtworkEndpointURLProtocol.requests(host: endpoint.host!).first
        )
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json; charset=utf-8"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertFalse(request.allowsExpensiveNetworkAccess)
        XCTAssertFalse(request.allowsConstrainedNetworkAccess)

        let requestBody = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode(MotionArtworkServiceRequest.self, from: requestBody)
        XCTAssertEqual(decoded.schemaVersion, MotionArtworkServiceRequest.currentSchemaVersion)
        XCTAssertEqual(decoded.input, lookupInput())
        XCTAssertEqual(decoded.acceptedKinds, [.animatedImage])
        XCTAssertEqual(
            Set(decoded.acceptedMIMETypes),
            MotionArtworkServiceResolver.supportedAnimatedImageMIMETypes
        )
    }

    func testV1DateDecodesHandwrittenFractionalISO8601AndEncodesISO8601() async throws {
        let endpoint = URL(string: "https://motion-iso-date.invalid/lookup")!
        let assetURL = URL(string: "https://motion-iso-assets.invalid/cover.webp")!
        let handwrittenJSON = Data(
            """
            {
              "schemaVersion": 1,
              "candidates": [{
                "album": {
                  "id": "album-1",
                  "identity": {
                    "upc": "012345678905",
                    "isrcs": ["US-AAA-26-00001"],
                    "albumArtist": "Example Artist",
                    "albumTitle": "Example Album",
                    "releaseYear": 2026,
                    "trackCount": 10,
                    "storefront": "us"
                  }
                },
                "assets": [{
                  "providerIdentifier": "configured-service",
                  "assetIdentifier": "motion-1",
                  "kind": "animatedImage",
                  "assetURL": "https://motion-iso-assets.invalid/cover.webp",
                  "mimeType": "image/webp",
                  "pixelWidth": 1200,
                  "pixelHeight": 1200,
                  "expiresAt": "2033-05-18T03:33:20.125Z"
                }]
              }]
            }
            """.utf8
        )
        MotionArtworkEndpointURLProtocol.configure(url: endpoint, body: handwrittenJSON)
        let client = makeClient()

        let result = try await client.lookup(
            endpoint: endpoint,
            input: lookupInput(),
            allowExpensiveNetwork: true
        )
        guard case .asset(let decodedAsset) = result else {
            return XCTFail("Expected a decoded asset")
        }
        XCTAssertEqual(decodedAsset.assetURL, assetURL)
        XCTAssertEqual(
            try XCTUnwrap(decodedAsset.expiresAt).timeIntervalSince1970,
            fixedNow.addingTimeInterval(0.125).timeIntervalSince1970,
            accuracy: 0.000_1
        )

        let encodedAsset = makeAsset(
            url: assetURL,
            expiresAt: fixedNow.addingTimeInterval(0.125)
        )
        let encoded = try MotionArtworkEndpointClient.makeJSONEncoder().encode(encodedAsset)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(encodedText.contains(
            "\"expiresAt\":\"2033-05-18T03:33:20.125Z\""
        ))
    }

    func testLookupMapsAvailabilityAndRejectsMalformedOrOversizedResponses() async throws {
        let notFound = URL(string: "https://motion-not-found.invalid/lookup")!
        MotionArtworkEndpointURLProtocol.configure(url: notFound, statusCode: 404)
        let notFoundResult = try await makeClient().lookup(
            endpoint: notFound,
            input: lookupInput(),
            allowExpensiveNetwork: true
        )
        XCTAssertEqual(notFoundResult, .notFound)

        let unavailable = URL(string: "https://motion-unavailable.invalid/lookup")!
        MotionArtworkEndpointURLProtocol.configure(
            url: unavailable,
            statusCode: 503,
            headers: ["Retry-After": "120"]
        )
        let unavailableResult = try await makeClient().lookup(
            endpoint: unavailable,
            input: lookupInput(),
            allowExpensiveNetwork: true
        )
        XCTAssertEqual(
            unavailableResult,
            .temporarilyUnavailable(retryAfter: fixedNow.addingTimeInterval(120))
        )

        let malformed = URL(string: "https://motion-malformed.invalid/lookup")!
        MotionArtworkEndpointURLProtocol.configure(
            url: malformed,
            body: Data("not-json".utf8)
        )
        let malformedClient = makeClient()
        await assertClientError(.malformedServiceResponse) {
            try await malformedClient.lookup(
                endpoint: malformed,
                input: self.lookupInput(),
                allowExpensiveNetwork: true
            )
        }

        let oversized = URL(string: "https://motion-oversized.invalid/lookup")!
        MotionArtworkEndpointURLProtocol.configure(
            url: oversized,
            body: Data(repeating: 0x20, count: 65)
        )
        let oversizedClient = makeClient(serviceResponseLimit: 64)
        await assertClientError(.responseTooLarge(maximumBytes: 64)) {
            try await oversizedClient.lookup(
                endpoint: oversized,
                input: self.lookupInput(),
                allowExpensiveNetwork: true
            )
        }
    }

    func testAssetAuthorizationAllowsOnlyConfiguredEndpointOrSafeUpgrade() {
        let localEndpoint = URL(string: "http://127.0.0.1/lookup")!
        XCTAssertTrue(MotionArtworkEndpointClient.isAuthorizedAssetURL(
            URL(string: "http://127.0.0.1/art.gif")!,
            configuredEndpoint: localEndpoint
        ))
        XCTAssertTrue(MotionArtworkEndpointClient.isAuthorizedAssetURL(
            URL(string: "https://127.0.0.1/art.gif")!,
            configuredEndpoint: localEndpoint
        ))
        for forbidden in [
            "https://cdn.example.test/art.gif",
            "https://10.0.0.8/art.gif",
            "https://172.16.0.8/art.gif",
            "https://192.168.0.8/art.gif",
            "https://169.254.2.3/art.gif",
            "https://127.0.0.2/art.gif",
            "https://[::1]/art.gif",
            "https://[fd00::8]/art.gif",
            "https://[fe80::8]/art.gif",
            "https://[fec0::8]/art.gif",
            "https://[::127.0.0.1]/art.gif",
            "https://artwork.local/art.gif",
            "https://sub.localhost/art.gif",
            "http://cdn.example.test/art.gif",
            "https://2130706433/art.gif",
            "https://127.1/art.gif",
            "https://0x7f000001/art.gif",
            "https://999.1.1.1/art.gif",
        ] {
            XCTAssertFalse(MotionArtworkEndpointClient.isAuthorizedAssetURL(
                URL(string: forbidden)!,
                configuredEndpoint: localEndpoint
            ), forbidden)
        }
    }

    func testRedirectPoliciesConstrainDestinationAndStripSensitiveHeaders() throws {
        let endpoint = URL(string: "https://motion-redirect-policy.invalid/lookup")!
        var lookup = URLRequest(url: endpoint)
        lookup.httpMethod = "POST"
        lookup.httpBody = Data("body".utf8)
        lookup.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        lookup.setValue("session=secret", forHTTPHeaderField: "Cookie")
        let lookupResponse = try XCTUnwrap(HTTPURLResponse(
            url: endpoint,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "/v1/lookup"]
        ))
        let safeLookup = try XCTUnwrap(
            MotionArtworkEndpointClient.redirectedLookupRequest(
                from: lookup,
                response: lookupResponse,
                configuredEndpoint: endpoint
            )
        )
        XCTAssertEqual(safeLookup.url?.absoluteString,
                       "https://motion-redirect-policy.invalid/v1/lookup")
        XCTAssertEqual(safeLookup.httpMethod, "POST")
        XCTAssertEqual(safeLookup.httpBody, lookup.httpBody)
        XCTAssertNil(safeLookup.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(safeLookup.value(forHTTPHeaderField: "Cookie"))

        let crossHostLookup = try XCTUnwrap(HTTPURLResponse(
            url: endpoint,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://other.example.test/lookup"]
        ))
        XCTAssertNil(MotionArtworkEndpointClient.redirectedLookupRequest(
            from: lookup,
            response: crossHostLookup,
            configuredEndpoint: endpoint
        ))
        let downgradeLookup = try XCTUnwrap(HTTPURLResponse(
            url: endpoint,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "http://motion-redirect-policy.invalid/lookup"]
        ))
        XCTAssertNil(MotionArtworkEndpointClient.redirectedLookupRequest(
            from: lookup,
            response: downgradeLookup,
            configuredEndpoint: endpoint
        ))

        let assetURL = URL(string: "https://motion-redirect-policy.invalid/art.webp")!
        var asset = URLRequest(url: assetURL)
        asset.httpMethod = "GET"
        asset.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        asset.setValue("session=secret", forHTTPHeaderField: "Cookie")
        let assetResponse = try XCTUnwrap(HTTPURLResponse(
            url: assetURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "/next.webp"]
        ))
        let safeAsset = try XCTUnwrap(
            MotionArtworkEndpointClient.redirectedAssetRequest(
                from: asset,
                response: assetResponse,
                configuredEndpoint: endpoint
            )
        )
        XCTAssertNil(safeAsset.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(safeAsset.value(forHTTPHeaderField: "Cookie"))

        let crossHostAssetResponse = try XCTUnwrap(HTTPURLResponse(
            url: assetURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://cdn.example.test/art.webp"]
        ))
        XCTAssertNil(MotionArtworkEndpointClient.redirectedAssetRequest(
            from: asset,
            response: crossHostAssetResponse,
            configuredEndpoint: endpoint
        ))

        let privateAssetResponse = try XCTUnwrap(HTTPURLResponse(
            url: assetURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://192.168.0.8/art.webp"]
        ))
        XCTAssertNil(MotionArtworkEndpointClient.redirectedAssetRequest(
            from: asset,
            response: privateAssetResponse,
            configuredEndpoint: endpoint
        ))
    }

    func testLookupFollowsOnlySameEndpointRedirectAndLimitsHops() async throws {
        let host = "motion-lookup-redirect.invalid"
        let start = URL(string: "https://\(host)/start")!
        let final = URL(string: "https://\(host)/final")!
        let asset = makeAsset(url: URL(string: "https://assets.example.test/art.webp")!)
        MotionArtworkEndpointURLProtocol.configure(
            url: start,
            statusCode: 307,
            headers: ["Location": final.absoluteString]
        )
        MotionArtworkEndpointURLProtocol.configure(
            url: final,
            body: try serviceResponseData(asset: asset)
        )
        let result = try await makeClient().lookup(
            endpoint: start,
            input: lookupInput(),
            allowExpensiveNetwork: true
        )
        XCTAssertEqual(result, .asset(asset))
        let requests = MotionArtworkEndpointURLProtocol.requests(host: host)
        XCTAssertEqual(requests.map(\.url), [start, final])
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST"])

        let blockedHost = "motion-lookup-blocked.invalid"
        let blocked = URL(string: "https://\(blockedHost)/start")!
        let other = URL(string: "https://other-lookup.invalid/final")!
        MotionArtworkEndpointURLProtocol.configure(
            url: blocked,
            statusCode: 307,
            headers: ["Location": other.absoluteString]
        )
        let blockedClient = makeClient()
        await assertClientError(.rejectedRedirect) {
            try await blockedClient.lookup(
                endpoint: blocked,
                input: self.lookupInput(),
                allowExpensiveNetwork: true
            )
        }
        XCTAssertTrue(MotionArtworkEndpointURLProtocol.requests(host: other.host!).isEmpty)

        let loopHost = "motion-lookup-loop.invalid"
        let loopURLs = (0...6).map { URL(string: "https://\(loopHost)/\($0)")! }
        for index in 0..<6 {
            MotionArtworkEndpointURLProtocol.configure(
                url: loopURLs[index],
                statusCode: 307,
                headers: ["Location": loopURLs[index + 1].absoluteString]
            )
        }
        do {
            _ = try await makeClient().lookup(
                endpoint: loopURLs[0],
                input: lookupInput(),
                allowExpensiveNetwork: true
            )
            XCTFail("Expected redirect limit")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .httpTooManyRedirects)
        }
        XCTAssertEqual(
            MotionArtworkEndpointURLProtocol.requests(host: loopHost).count,
            HTTPRedirectRequestPolicy.maximumRedirects + 1
        )
    }

    func testDownloadFollowsSameEndpointRedirectAndRejectsCrossHostHop() async throws {
        let endpoint = URL(string: "https://motion-service.invalid/lookup")!
        let first = URL(string: "https://motion-service.invalid/art.webp")!
        let second = URL(string: "https://motion-service.invalid/redirected.webp")!
        MotionArtworkEndpointURLProtocol.configure(
            url: first,
            statusCode: 302,
            headers: ["Location": second.absoluteString]
        )
        MotionArtworkEndpointURLProtocol.configure(
            url: second,
            headers: ["Content-Type": "image/webp"],
            body: animatedWebP()
        )
        let client = makeClient()
        let result = try await client.download(
            asset: makeAsset(url: first),
            configuredEndpoint: endpoint,
            allowExpensiveNetwork: true
        )
        guard case .downloaded(let payload) = result else {
            return XCTFail("Expected downloaded artwork")
        }
        XCTAssertTrue(payload.descriptor.isAnimated)
        XCTAssertEqual(MotionArtworkEndpointURLProtocol.requests(url: first).count, 1)
        XCTAssertEqual(MotionArtworkEndpointURLProtocol.requests(url: second).count, 1)

        let blocked = URL(string: "https://motion-service.invalid/blocked.webp")!
        MotionArtworkEndpointURLProtocol.configure(
            url: blocked,
            statusCode: 302,
            headers: ["Location": "https://cdn.example.test/private.webp"]
        )
        let blockedClient = makeClient()
        await assertClientError(.rejectedRedirect) {
            try await blockedClient.download(
                asset: self.makeAsset(url: blocked),
                configuredEndpoint: endpoint,
                allowExpensiveNetwork: true
            )
        }
        XCTAssertTrue(MotionArtworkEndpointURLProtocol.requests(host: "cdn.example.test").isEmpty)
    }

    func testDownloadEnforcesKindAnimationAndHardByteCap() async throws {
        let endpoint = URL(string: "https://motion-download-service.invalid/lookup")!
        let client = makeClient()
        await assertClientError(.unsupportedAssetKind(.video)) {
            try await client.download(
                asset: self.makeAsset(
                    url: URL(string: "https://video.example.test/art.mp4")!,
                    kind: .video
                ),
                configuredEndpoint: endpoint,
                allowExpensiveNetwork: true
            )
        }
        await assertClientError(.invalidAssetURL) {
            try await client.download(
                asset: self.makeAsset(url: URL(fileURLWithPath: "/tmp/private.gif")),
                configuredEndpoint: endpoint,
                allowExpensiveNetwork: true
            )
        }

        let staticURL = URL(string: "https://motion-download-service.invalid/still.gif")!
        MotionArtworkEndpointURLProtocol.configure(url: staticURL, body: staticGIF())
        await assertClientError(.notAnimatedImage) {
            try await client.download(
                asset: self.makeAsset(url: staticURL),
                configuredEndpoint: endpoint,
                allowExpensiveNetwork: true
            )
        }

        let oversizedURL = URL(string: "https://motion-download-service.invalid/oversized.webp")!
        MotionArtworkEndpointURLProtocol.configure(
            url: oversizedURL,
            body: Data(repeating: 0, count: 65)
        )
        let oversizedClient = makeClient(animatedImageLimit: 64)
        await assertClientError(.responseTooLarge(maximumBytes: 64)) {
            try await oversizedClient.download(
                asset: self.makeAsset(url: oversizedURL),
                configuredEndpoint: endpoint,
                allowExpensiveNetwork: false
            )
        }
    }

    func testResolveCoalescesLookupAndDownloadAcrossWaiters() async throws {
        let endpoint = URL(string: "https://motion-resolve-shared.invalid/lookup")!
        let assetURL = URL(string: "https://motion-resolve-shared.invalid/art.webp")!
        let asset = makeAsset(url: assetURL)
        MotionArtworkEndpointURLProtocol.configure(
            url: endpoint,
            body: try serviceResponseData(asset: asset),
            delay: 0.05
        )
        MotionArtworkEndpointURLProtocol.configure(
            url: assetURL,
            body: animatedWebP(),
            delay: 0.05
        )
        let client = makeClient()
        let input = lookupInput()

        async let first = client.resolve(
            endpoint: endpoint,
            input: input,
            requestKey: "disk-key",
            allowExpensiveNetwork: true
        )
        async let second = client.resolve(
            endpoint: endpoint,
            input: input,
            requestKey: "disk-key",
            allowExpensiveNetwork: true
        )
        let values = try await [first, second]
        XCTAssertEqual(values.count, 2)
        for value in values {
            guard case .downloaded(let payload) = value else {
                return XCTFail("Expected a shared download")
            }
            XCTAssertEqual(payload.data, animatedWebP())
        }
        XCTAssertEqual(MotionArtworkEndpointURLProtocol.requests(url: endpoint).count, 1)
        XCTAssertEqual(MotionArtworkEndpointURLProtocol.requests(url: assetURL).count, 1)
    }

    func testCancellingOneResolveWaiterKeepsSharedProducerAlive() async throws {
        let endpoint = URL(string: "https://motion-resolve-cancel-one.invalid/lookup")!
        let assetURL = URL(string: "https://motion-resolve-cancel-one.invalid/art.webp")!
        MotionArtworkEndpointURLProtocol.configure(
            url: endpoint,
            body: try serviceResponseData(asset: makeAsset(url: assetURL)),
            delay: 0.15
        )
        MotionArtworkEndpointURLProtocol.configure(url: assetURL, body: animatedWebP())
        let client = makeClient()
        let input = lookupInput()
        let first = Task {
            try await client.resolve(
                endpoint: endpoint,
                input: input,
                requestKey: "shared-cancel-key",
                allowExpensiveNetwork: true
            )
        }
        try await waitForRequests(host: endpoint.host!, count: 1)
        let second = Task {
            try await client.resolve(
                endpoint: endpoint,
                input: input,
                requestKey: "shared-cancel-key",
                allowExpensiveNetwork: true
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        first.cancel()
        await assertCancelled(first)

        guard case .downloaded = try await second.value else {
            return XCTFail("The remaining waiter should succeed")
        }
        XCTAssertEqual(MotionArtworkEndpointURLProtocol.requests(url: endpoint).count, 1)
        XCTAssertEqual(MotionArtworkEndpointURLProtocol.requests(url: assetURL).count, 1)
    }

    func testLastWaiterCancellationRemovesFlightAndLateCompletionCannotReplaceNewSuccess() async throws {
        let endpoint = URL(string: "https://motion-resolve-restart.invalid/lookup")!
        let assetURL = URL(string: "https://motion-resolve-restart.invalid/art.webp")!
        let body = try serviceResponseData(asset: makeAsset(url: assetURL))
        MotionArtworkEndpointURLProtocol.configure(
            url: endpoint,
            responses: [
                .init(body: body, delay: 1),
                .init(body: body),
            ]
        )
        MotionArtworkEndpointURLProtocol.configure(url: assetURL, body: animatedWebP())
        let client = makeClient()
        let input = lookupInput()
        let first = Task {
            try await client.resolve(
                endpoint: endpoint,
                input: input,
                requestKey: "restart-key",
                allowExpensiveNetwork: true
            )
        }
        try await waitForRequests(host: endpoint.host!, count: 1)
        first.cancel()
        await assertCancelled(first)

        let restarted = try await client.resolve(
            endpoint: endpoint,
            input: input,
            requestKey: "restart-key",
            allowExpensiveNetwork: true
        )
        guard case .downloaded = restarted else {
            return XCTFail("A replacement flight should succeed")
        }
        XCTAssertEqual(MotionArtworkEndpointURLProtocol.requests(url: endpoint).count, 2)
        XCTAssertEqual(MotionArtworkEndpointURLProtocol.requests(url: assetURL).count, 1)
    }

    func testCancellationHandlerCanRunBeforeResolveWaiterEnqueues() async {
        let endpoint = URL(string: "https://motion-resolve-early-cancel.invalid/lookup")!
        MotionArtworkEndpointURLProtocol.configure(
            url: endpoint,
            body: Data("{}".utf8),
            delay: 1
        )
        let gate = MotionArtworkAsyncGate()
        let client = makeClient(beforeResolveWaiterEnqueue: {
            await gate.suspend()
        })
        let input = lookupInput()
        let task = Task {
            return try await client.resolve(
                endpoint: endpoint,
                input: input,
                requestKey: "early-cancel-key",
                allowExpensiveNetwork: true
            )
        }
        await gate.waitUntilSuspended()
        task.cancel()
        for _ in 0..<20 {
            await Task.yield()
        }
        await gate.release()
        await assertCancelled(task)
        XCTAssertTrue(MotionArtworkEndpointURLProtocol.requests(host: endpoint.host!).isEmpty)
    }

    func testCancellationAfterSharedCompletionStillWinsBeforeResolveReturns() async throws {
        let endpoint = URL(string: "https://motion-resolve-late-cancel.invalid/lookup")!
        let assetURL = URL(string: "https://motion-resolve-late-cancel.invalid/art.webp")!
        MotionArtworkEndpointURLProtocol.configure(
            url: endpoint,
            body: try serviceResponseData(asset: makeAsset(url: assetURL))
        )
        MotionArtworkEndpointURLProtocol.configure(url: assetURL, body: animatedWebP())
        let gate = MotionArtworkAsyncGate()
        let client = makeClient(beforeResolveReturn: {
            await gate.suspend()
        })
        let input = lookupInput()
        let task = Task {
            try await client.resolve(
                endpoint: endpoint,
                input: input,
                requestKey: "late-cancel-key",
                allowExpensiveNetwork: true
            )
        }

        await gate.waitUntilSuspended()
        task.cancel()
        await gate.release()
        await assertCancelled(task)
        XCTAssertEqual(MotionArtworkEndpointURLProtocol.requests(url: endpoint).count, 1)
        XCTAssertEqual(MotionArtworkEndpointURLProtocol.requests(url: assetURL).count, 1)
    }

    func testTransportFailureRemainsDistinctFromCancellation() async {
        let endpoint = URL(string: "https://motion-transport-failure.invalid/lookup")!
        MotionArtworkEndpointURLProtocol.configure(url: endpoint, failure: .timedOut)
        do {
            _ = try await makeClient().lookup(
                endpoint: endpoint,
                input: lookupInput(),
                allowExpensiveNetwork: true
            )
            XCTFail("Expected a transport failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient(
        serviceResponseLimit: Int = MotionArtworkEndpointClient.maximumServiceResponseBytes,
        animatedImageLimit: Int = MotionArtworkEndpointClient.maximumAnimatedImageBytes,
        beforeResolveWaiterEnqueue: (@Sendable () async -> Void)? = nil,
        beforeResolveReturn: (@Sendable () async -> Void)? = nil
    ) -> MotionArtworkEndpointClient {
        let configuration = MotionArtworkEndpointClient.ephemeralConfiguration()
        configuration.protocolClasses = [MotionArtworkEndpointURLProtocol.self]
        return MotionArtworkEndpointClient(
            sessionConfiguration: configuration,
            now: { [fixedNow] in fixedNow },
            serviceResponseLimit: serviceResponseLimit,
            animatedImageLimit: animatedImageLimit,
            beforeResolveWaiterEnqueue: beforeResolveWaiterEnqueue,
            beforeResolveReturn: beforeResolveReturn
        )
    }

    private func lookupInput() -> MotionArtworkLookupInput {
        MotionArtworkLookupInput(
            upc: "012345678905",
            isrcs: ["US-AAA-26-00001"],
            albumArtist: "Example Artist",
            albumTitle: "Example Album",
            releaseYear: 2026,
            trackCount: 10,
            storefront: "us"
        )
    }

    private func makeAsset(
        url: URL,
        kind: MotionArtworkAssetKind = .animatedImage,
        expiresAt: Date? = nil
    ) -> MotionArtworkAsset {
        MotionArtworkAsset(
            providerIdentifier: "configured-service",
            assetIdentifier: "motion-1",
            kind: kind,
            assetURL: url,
            mimeType: kind == .animatedImage ? "image/webp" : "video/mp4",
            pixelWidth: 1_200,
            pixelHeight: 1_200,
            expiresAt: expiresAt
        )
    }

    private func serviceResponseData(asset: MotionArtworkAsset) throws -> Data {
        try MotionArtworkEndpointClient.makeJSONEncoder().encode(
            MotionArtworkServiceResponse(candidates: [
                MotionArtworkServiceCandidate(
                    album: MotionArtworkAlbumCandidate(
                        id: "album-1",
                        identity: lookupInput()
                    ),
                    assets: [asset]
                ),
            ])
        )
    }

    private func animatedWebP() -> Data {
        Data(base64Encoded:
            "UklGRoQAAABXRUJQVlA4WAoAAAACAAAAAQAAAQAAQU5JTQYAAAD/////AABBTk1GKAAAAAAAAAAAAAEAAAEAAGQAAAJWUDhMDwAAAC8BQAAABxDlj/4HIqL/AQBBTk1GKAAAAAAAAAAAAAEAAAEAAGQAAABWUDhMDwAAAC8BQAAABxDR/v4HIqL/AQA="
        )!
    }

    private func staticGIF() -> Data {
        Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!
    }

    private func waitForRequests(host: String, count: Int) async throws {
        for _ in 0..<200 {
            if MotionArtworkEndpointURLProtocol.requests(host: host).count >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(count) request(s) to \(host)")
    }

    private func assertClientError<T>(
        _ expected: MotionArtworkEndpointClientError,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected client error \(expected)")
        } catch let error as MotionArtworkEndpointClientError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func assertCancelled<T>(_ task: Task<T, any Error>) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }
}

private actor MotionArtworkAsyncGate {
    private var isSuspended = false
    private var isReleased = false
    private var suspendedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        let waiters = suspendedWaiters
        suspendedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspendedWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class MotionArtworkEndpointURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var statusCode = 200
        var headers: [String: String] = [:]
        var body = Data()
        var delay: TimeInterval = 0
        var failure: URLError.Code?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: [Response]] = [:]
    nonisolated(unsafe) private static var requestLog: [String: [URLRequest]] = [:]

    private let loadingLock = NSLock()
    private var stopped = false
    private var workItem: DispatchWorkItem?

    static func configure(
        url: URL,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data(),
        delay: TimeInterval = 0,
        failure: URLError.Code? = nil
    ) {
        configure(
            url: url,
            responses: [Response(
                statusCode: statusCode,
                headers: headers,
                body: body,
                delay: delay,
                failure: failure
            )]
        )
    }

    static func configure(url: URL, responses values: [Response]) {
        lock.lock()
        responses[url.absoluteString] = values
        lock.unlock()
    }

    static func requests(host: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestLog[host] ?? []
    }

    static func requests(url: URL) -> [URLRequest] {
        guard let host = url.host else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return (requestLog[host] ?? []).filter { $0.url == url }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            captured.httpBody = Self.readBody(from: stream)
        }

        Self.lock.lock()
        Self.requestLog[host, default: []].append(captured)
        let key = url.absoluteString
        guard var queued = Self.responses[key], !queued.isEmpty else {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = queued.removeFirst()
        Self.responses[key] = queued
        Self.lock.unlock()

        let item = DispatchWorkItem { [weak self] in
            self?.send(response: response, url: url)
        }
        loadingLock.lock()
        workItem = item
        loadingLock.unlock()
        if response.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay, execute: item)
        } else {
            item.perform()
        }
    }

    override func stopLoading() {
        loadingLock.lock()
        stopped = true
        workItem?.cancel()
        loadingLock.unlock()
    }

    private func send(response stub: Response, url: URL) {
        loadingLock.lock()
        let isStopped = stopped
        loadingLock.unlock()
        guard !isStopped else { return }

        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        var headers = stub.headers
        headers["Content-Length"] = String(stub.body.count)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readBody(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
#endif
