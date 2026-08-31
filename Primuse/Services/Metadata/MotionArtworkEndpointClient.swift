import Foundation
import PrimuseKit

enum MotionArtworkEndpointClientError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidAssetURL
    case unsupportedAssetKind(MotionArtworkAssetKind)
    case invalidHTTPResponse
    case malformedServiceResponse
    case rejectedRedirect
    case unexpectedHTTPStatus(Int)
    case responseTooLarge(maximumBytes: Int)
    case notAnimatedImage
}

struct MotionArtworkEndpointDownload: Equatable, Sendable {
    let asset: MotionArtworkAsset
    let data: Data
    let descriptor: ArtworkDescriptor
}

enum MotionArtworkEndpointDownloadResult: Equatable, Sendable {
    case downloaded(MotionArtworkEndpointDownload)
    case notFound
    case temporarilyUnavailable(retryAfter: Date?)
}

/// A single end-to-end outcome for a configured-service lookup and its asset
/// download. Callers should use `resolve` so identical visible artwork layers
/// share both network hops and cannot race a late failure against a success.
enum MotionArtworkEndpointResolveResult: Equatable, Sendable {
    case downloaded(MotionArtworkEndpointDownload)
    case notFound
    case ambiguous([MotionArtworkAlbumCandidate])
    case unsupported
    case temporarilyUnavailable(retryAfter: Date?)
}

/// Rejects URLSession's automatic redirect handling. Redirects are replayed by
/// the client only after the lookup or asset policy has validated every hop.
private final class MotionArtworkNoRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Talks only to the Motion Artwork service URL explicitly configured by the
/// user. This client does not discover endpoints or inspect private Apple data.
actor MotionArtworkEndpointClient {
    static let shared = MotionArtworkEndpointClient()

    static let maximumServiceResponseBytes = 512 * 1_024
    static let maximumAnimatedImageBytes = 32 * 1_024 * 1_024

    private static let lookupTimeout: TimeInterval = 15
    private static let downloadTimeout: TimeInterval = 30
    private static let sensitiveRedirectHeaders = [
        "Authorization",
        "Proxy-Authorization",
        "Cookie",
        "Cookie2",
        "Referer",
    ]

    private struct ResolveRequestIdentity: Hashable, Sendable {
        let requestKey: String
        let endpoint: URL
        let input: MotionArtworkLookupInput
        let allowExpensiveNetwork: Bool
    }

    private struct InFlightResolve {
        let id: UUID
        var producer: Task<Void, Never>?
        var waiters: [
            UUID: CheckedContinuation<MotionArtworkEndpointResolveResult, any Error>
        ]
    }

    private enum RequestPurpose: Sendable {
        case lookup(configuredEndpoint: URL)
        case asset(configuredEndpoint: URL)
    }

    private let session: URLSession
    private let now: @Sendable () -> Date
    private let serviceResponseLimit: Int
    private let animatedImageLimit: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let beforeResolveWaiterEnqueue: (@Sendable () async -> Void)?
    private let beforeResolveReturn: (@Sendable () async -> Void)?
    private var inFlightResolutions: [ResolveRequestIdentity: InFlightResolve] = [:]

    init(
        sessionConfiguration: URLSessionConfiguration? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        serviceResponseLimit: Int = MotionArtworkEndpointClient.maximumServiceResponseBytes,
        animatedImageLimit: Int = MotionArtworkEndpointClient.maximumAnimatedImageBytes,
        beforeResolveWaiterEnqueue: (@Sendable () async -> Void)? = nil,
        beforeResolveReturn: (@Sendable () async -> Void)? = nil
    ) {
        precondition(
            serviceResponseLimit > 0
                && serviceResponseLimit <= Self.maximumServiceResponseBytes
        )
        precondition(
            animatedImageLimit > 0
                && animatedImageLimit <= Self.maximumAnimatedImageBytes
        )
        let configuration = sessionConfiguration ?? Self.ephemeralConfiguration()
        session = URLSession(
            configuration: configuration,
            delegate: MotionArtworkNoRedirectDelegate(),
            delegateQueue: nil
        )
        self.now = now
        self.serviceResponseLimit = serviceResponseLimit
        self.animatedImageLimit = animatedImageLimit
        self.beforeResolveWaiterEnqueue = beforeResolveWaiterEnqueue
        self.beforeResolveReturn = beforeResolveReturn
        encoder = Self.makeJSONEncoder()
        decoder = Self.makeJSONDecoder()
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Resolves and downloads one animated image, coalescing the complete
    /// operation by the caller's stable disk/request key plus request inputs.
    /// Cancelling one waiter leaves the shared producer running; only the final
    /// waiter's cancellation tears down the producer.
    func resolve(
        endpoint: URL,
        input: MotionArtworkLookupInput,
        requestKey: String,
        allowExpensiveNetwork: Bool
    ) async throws -> MotionArtworkEndpointResolveResult {
        guard Self.isValidEndpoint(endpoint) else {
            throw MotionArtworkEndpointClientError.invalidEndpoint
        }
        try Task.checkCancellation()

        let identity = ResolveRequestIdentity(
            requestKey: requestKey,
            endpoint: endpoint,
            input: input,
            allowExpensiveNetwork: allowExpensiveNetwork
        )
        let waiterID = UUID()
        let result = try await withTaskCancellationHandler {
            if let beforeResolveWaiterEnqueue {
                await beforeResolveWaiterEnqueue()
            }
            return try await withCheckedThrowingContinuation { continuation in
                enqueueResolveWaiter(
                    continuation,
                    waiterID: waiterID,
                    identity: identity,
                    endpoint: endpoint,
                    input: input,
                    allowExpensiveNetwork: allowExpensiveNetwork
                )
            }
        } onCancel: {
            Task {
                await self.cancelResolveWaiter(
                    waiterID: waiterID,
                    identity: identity
                )
            }
        }
        if let beforeResolveReturn {
            await beforeResolveReturn()
        }
        try Task.checkCancellation()
        return result
    }

    func lookup(
        endpoint: URL,
        input: MotionArtworkLookupInput,
        allowExpensiveNetwork: Bool
    ) async throws -> MotionArtworkLookupResult {
        guard Self.isValidEndpoint(endpoint) else {
            throw MotionArtworkEndpointClientError.invalidEndpoint
        }
        return try await lookupUncoalesced(
            endpoint: endpoint,
            input: input,
            allowExpensiveNetwork: allowExpensiveNetwork
        )
    }

    func download(
        asset: MotionArtworkAsset,
        configuredEndpoint endpoint: URL,
        allowExpensiveNetwork: Bool
    ) async throws -> MotionArtworkEndpointDownloadResult {
        guard Self.isValidEndpoint(endpoint) else {
            throw MotionArtworkEndpointClientError.invalidEndpoint
        }
        return try await downloadUncoalesced(
            asset: asset,
            configuredEndpoint: endpoint,
            allowExpensiveNetwork: allowExpensiveNetwork
        )
    }

    private func enqueueResolveWaiter(
        _ continuation: CheckedContinuation<MotionArtworkEndpointResolveResult, any Error>,
        waiterID: UUID,
        identity: ResolveRequestIdentity,
        endpoint: URL,
        input: MotionArtworkLookupInput,
        allowExpensiveNetwork: Bool
    ) {
        // Cancellation can race the handler registration and continuation
        // enqueue. Re-check in the caller task before publishing the waiter so
        // an early onCancel callback can never leave an orphaned continuation.
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if var inFlight = inFlightResolutions[identity] {
            inFlight.waiters[waiterID] = continuation
            inFlightResolutions[identity] = inFlight
            return
        }

        let inFlightID = UUID()
        inFlightResolutions[identity] = InFlightResolve(
            id: inFlightID,
            producer: nil,
            waiters: [waiterID: continuation]
        )
        let producer = Task { [weak self] in
            guard let self else { return }
            let result: Result<MotionArtworkEndpointResolveResult, any Error>
            do {
                result = .success(try await self.resolveUncoalesced(
                    endpoint: endpoint,
                    input: input,
                    allowExpensiveNetwork: allowExpensiveNetwork
                ))
            } catch {
                result = .failure(error)
            }
            await self.completeResolution(
                identity: identity,
                inFlightID: inFlightID,
                result: result
            )
        }
        inFlightResolutions[identity]?.producer = producer
    }

    private func cancelResolveWaiter(
        waiterID: UUID,
        identity: ResolveRequestIdentity
    ) {
        guard var inFlight = inFlightResolutions[identity],
              let continuation = inFlight.waiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        guard inFlight.waiters.isEmpty else {
            inFlightResolutions[identity] = inFlight
            return
        }
        inFlightResolutions.removeValue(forKey: identity)
        inFlight.producer?.cancel()
    }

    private func completeResolution(
        identity: ResolveRequestIdentity,
        inFlightID: UUID,
        result: Result<MotionArtworkEndpointResolveResult, any Error>
    ) {
        guard let inFlight = inFlightResolutions[identity],
              inFlight.id == inFlightID else {
            return
        }
        inFlightResolutions.removeValue(forKey: identity)
        for continuation in inFlight.waiters.values {
            continuation.resume(with: result)
        }
    }

    private func resolveUncoalesced(
        endpoint: URL,
        input: MotionArtworkLookupInput,
        allowExpensiveNetwork: Bool
    ) async throws -> MotionArtworkEndpointResolveResult {
        let lookup = try await lookupUncoalesced(
            endpoint: endpoint,
            input: input,
            allowExpensiveNetwork: allowExpensiveNetwork
        )
        try Task.checkCancellation()
        switch lookup {
        case .asset(let asset):
            let download = try await downloadUncoalesced(
                asset: asset,
                configuredEndpoint: endpoint,
                allowExpensiveNetwork: allowExpensiveNetwork
            )
            switch download {
            case .downloaded(let payload):
                return .downloaded(payload)
            case .notFound:
                return .notFound
            case .temporarilyUnavailable(let retryAfter):
                return .temporarilyUnavailable(retryAfter: retryAfter)
            }
        case .notFound:
            return .notFound
        case .ambiguous(let candidates):
            return .ambiguous(candidates)
        case .unsupported:
            return .unsupported
        case .temporarilyUnavailable(let retryAfter):
            return .temporarilyUnavailable(retryAfter: retryAfter)
        }
    }

    private func lookupUncoalesced(
        endpoint: URL,
        input: MotionArtworkLookupInput,
        allowExpensiveNetwork: Bool
    ) async throws -> MotionArtworkLookupResult {
        try Task.checkCancellation()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.lookupTimeout
        request.httpBody = try encoder.encode(MotionArtworkServiceRequest(input: input))
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        Self.applyNetworkPolicy(
            allowExpensiveNetwork: allowExpensiveNetwork,
            to: &request
        )

        let (data, response) = try await perform(
            request,
            maximumBytes: serviceResponseLimit,
            purpose: .lookup(configuredEndpoint: endpoint)
        )
        let http = try Self.validatedHTTPResponse(
            response,
            purpose: .lookup(configuredEndpoint: endpoint)
        )

        switch http.statusCode {
        case 200...299:
            let serviceResponse = try decodeServiceResponse(data)
            return MotionArtworkServiceResolver.resolve(
                input: input,
                response: serviceResponse,
                now: now()
            )
        case 404:
            return .notFound
        case 409:
            let serviceResponse = try decodeServiceResponse(data)
            guard serviceResponse.schemaVersion
                    == MotionArtworkServiceRequest.currentSchemaVersion else {
                return .unsupported
            }
            return .ambiguous(serviceResponse.candidates.map(\.album))
        case 429, 500...599:
            return .temporarilyUnavailable(
                retryAfter: Self.retryAfterDate(from: http, now: now())
            )
        default:
            throw MotionArtworkEndpointClientError.unexpectedHTTPStatus(http.statusCode)
        }
    }

    private func downloadUncoalesced(
        asset: MotionArtworkAsset,
        configuredEndpoint endpoint: URL,
        allowExpensiveNetwork: Bool
    ) async throws -> MotionArtworkEndpointDownloadResult {
        guard asset.kind == .animatedImage else {
            throw MotionArtworkEndpointClientError.unsupportedAssetKind(asset.kind)
        }
        guard Self.isAuthorizedAssetURL(
            asset.assetURL,
            configuredEndpoint: endpoint
        ) else {
            throw MotionArtworkEndpointClientError.invalidAssetURL
        }
        try Task.checkCancellation()

        var request = URLRequest(url: asset.assetURL)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.downloadTimeout
        request.setValue(
            MotionArtworkServiceResolver.supportedAnimatedImageMIMETypes
                .sorted()
                .joined(separator: ", "),
            forHTTPHeaderField: "Accept"
        )
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        Self.applyNetworkPolicy(
            allowExpensiveNetwork: allowExpensiveNetwork,
            to: &request
        )

        let (data, response) = try await perform(
            request,
            maximumBytes: animatedImageLimit,
            purpose: .asset(configuredEndpoint: endpoint)
        )
        let http = try Self.validatedHTTPResponse(
            response,
            purpose: .asset(configuredEndpoint: endpoint)
        )

        switch http.statusCode {
        case 200...299:
            try Task.checkCancellation()
            guard let descriptor = try await Self.inspectAnimatedImage(data),
                  descriptor.isAnimated else {
                throw MotionArtworkEndpointClientError.notAnimatedImage
            }
            try Task.checkCancellation()
            return .downloaded(
                MotionArtworkEndpointDownload(
                    asset: asset,
                    data: data,
                    descriptor: descriptor
                )
            )
        case 404:
            return .notFound
        case 429, 500...599:
            return .temporarilyUnavailable(
                retryAfter: Self.retryAfterDate(from: http, now: now())
            )
        default:
            throw MotionArtworkEndpointClientError.unexpectedHTTPStatus(http.statusCode)
        }
    }

    nonisolated static func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = lookupTimeout
        configuration.timeoutIntervalForResource = downloadTimeout
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return configuration
    }

    nonisolated static func isValidEndpoint(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              NetworkEndpointIdentity(url: url) != nil else {
            return false
        }
        return true
    }

    /// Assets stay on the endpoint explicitly authorized by the user, with the
    /// sole cross-endpoint exception of the conventional same-host 80-to-443
    /// upgrade. Arbitrary CDN hostnames are not accepted because Foundation
    /// does not expose a way to pin a separately validated DNS answer to the
    /// connection, so a preflight lookup would remain vulnerable to rebinding.
    nonisolated static func isAuthorizedAssetURL(
        _ url: URL,
        configuredEndpoint endpoint: URL
    ) -> Bool {
        guard isValidEndpoint(endpoint), isValidEndpoint(url) else { return false }
        return HTTPRedirectSecurityPolicy.allows(from: endpoint, to: url)
    }

    nonisolated static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601String(from: date))
        }
        return encoder
    }

    nonisolated static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = iso8601Date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO 8601 date"
                )
            }
            return date
        }
        return decoder
    }

    nonisolated static func redirectedLookupRequest(
        from original: URLRequest,
        response: HTTPURLResponse,
        configuredEndpoint endpoint: URL
    ) -> URLRequest? {
        guard let redirected = HTTPRedirectRequestPolicy.redirectedRequest(
            from: original,
            response: response
        ), let destination = redirected.url,
           HTTPRedirectSecurityPolicy.allows(from: endpoint, to: destination) else {
            return nil
        }
        return removingSensitiveHeaders(from: redirected)
    }

    nonisolated static func redirectedAssetRequest(
        from original: URLRequest,
        response: HTTPURLResponse,
        configuredEndpoint endpoint: URL
    ) -> URLRequest? {
        guard let redirected = HTTPMediaRedirectRequestPolicy.redirectedRequest(
            from: original,
            response: response
        ), let destination = redirected.url,
           isAuthorizedAssetURL(destination, configuredEndpoint: endpoint) else {
            return nil
        }
        return removingSensitiveHeaders(from: redirected)
    }

    private func decodeServiceResponse(_ data: Data) throws -> MotionArtworkServiceResponse {
        do {
            return try decoder.decode(MotionArtworkServiceResponse.self, from: data)
        } catch {
            throw MotionArtworkEndpointClientError.malformedServiceResponse
        }
    }

    private func perform(
        _ request: URLRequest,
        maximumBytes: Int,
        purpose: RequestPurpose,
        redirectCount: Int = 0
    ) async throws -> (Data, URLResponse) {
        do {
            let result = try await TrustedHTTPTransport.data(
                for: request,
                session: session,
                maxBytes: maximumBytes
            )
            try Task.checkCancellation()
            guard let http = result.1 as? HTTPURLResponse else {
                throw MotionArtworkEndpointClientError.invalidHTTPResponse
            }
            guard Self.isRedirectStatus(http.statusCode) else {
                return result
            }
            guard redirectCount < HTTPRedirectRequestPolicy.maximumRedirects else {
                throw URLError(.httpTooManyRedirects)
            }
            guard let redirected = Self.redirectedRequest(
                from: request,
                response: http,
                purpose: purpose
            ) else {
                throw MotionArtworkEndpointClientError.rejectedRedirect
            }
            return try await perform(
                redirected,
                maximumBytes: maximumBytes,
                purpose: purpose,
                redirectCount: redirectCount + 1
            )
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if (error as? URLError)?.code == .dataLengthExceedsMaximum {
                throw MotionArtworkEndpointClientError.responseTooLarge(
                    maximumBytes: maximumBytes
                )
            }
            throw error
        }
    }

    private nonisolated static func redirectedRequest(
        from original: URLRequest,
        response: HTTPURLResponse,
        purpose: RequestPurpose
    ) -> URLRequest? {
        switch purpose {
        case .lookup(let endpoint):
            return redirectedLookupRequest(
                from: original,
                response: response,
                configuredEndpoint: endpoint
            )
        case .asset(let endpoint):
            return redirectedAssetRequest(
                from: original,
                response: response,
                configuredEndpoint: endpoint
            )
        }
    }

    private nonisolated static func removingSensitiveHeaders(
        from request: URLRequest
    ) -> URLRequest {
        var sanitized = request
        for header in sensitiveRedirectHeaders {
            sanitized.setValue(nil, forHTTPHeaderField: header)
        }
        return sanitized
    }

    private nonisolated static func validatedHTTPResponse(
        _ response: URLResponse,
        purpose: RequestPurpose
    ) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse,
              let finalURL = http.url else {
            throw MotionArtworkEndpointClientError.invalidHTTPResponse
        }
        switch purpose {
        case .lookup(let endpoint):
            guard isValidEndpoint(finalURL),
                  HTTPRedirectSecurityPolicy.allows(from: endpoint, to: finalURL) else {
                throw MotionArtworkEndpointClientError.invalidHTTPResponse
            }
        case .asset(let endpoint):
            guard isAuthorizedAssetURL(
                finalURL,
                configuredEndpoint: endpoint
            ) else {
                throw MotionArtworkEndpointClientError.invalidHTTPResponse
            }
        }
        return http
    }

    private nonisolated static func isRedirectStatus(_ statusCode: Int) -> Bool {
        [301, 302, 303, 307, 308].contains(statusCode)
    }

    private nonisolated static func applyNetworkPolicy(
        allowExpensiveNetwork: Bool,
        to request: inout URLRequest
    ) {
        request.allowsExpensiveNetworkAccess = allowExpensiveNetwork
        request.allowsConstrainedNetworkAccess = allowExpensiveNetwork
    }

    private nonisolated static func inspectAnimatedImage(
        _ data: Data
    ) async throws -> ArtworkDescriptor? {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let descriptor = ArtworkImageCompatibility.inspect(
                data,
                limits: .default
            )
            try Task.checkCancellation()
            return descriptor
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private nonisolated static func iso8601Date(from value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private nonisolated static func retryAfterDate(
        from response: HTTPURLResponse,
        now: Date
    ) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }

        let formats = [
            "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
            "EEEE',' dd-MMM-yy HH':'mm':'ss zzz",
            "EEE MMM d HH':'mm':'ss yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}
