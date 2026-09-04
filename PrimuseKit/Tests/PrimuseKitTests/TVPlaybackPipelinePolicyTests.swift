import Foundation
import Testing
@testable import PrimuseKit

@Suite("tvOS playback pipeline policies")
struct TVPlaybackPipelinePolicyTests {
    @Test("CUE seeks and progress stay relative to the virtual track")
    func cueTimelineMapping() {
        let segment = TVPlaybackSegment(
            cueStartTime: 61.5,
            cueEndTime: 125,
            storedDuration: 63.5
        )
        #expect(segment.physicalTime(forLogicalTime: 0) == 61.5)
        #expect(segment.physicalTime(forLogicalTime: 10) == 71.5)
        #expect(segment.logicalTime(forPhysicalTime: 70) == 8.5)
        #expect(segment.logicalDuration == 63.5)
        #expect(segment.hasReachedPhysicalEnd(124.98))
    }

    @Test("The final CUE track derives its physical end from stored duration")
    func finalCueTrackDerivesEnd() {
        let segment = TVPlaybackSegment(
            cueStartTime: 180,
            cueEndTime: nil,
            storedDuration: 42
        )
        #expect(segment.physicalEnd == 222)
        #expect(segment.physicalTime(forLogicalTime: 100) == 222)
    }

    @Test("Opus decodes locally, AU remains native, and Subsonic WMA becomes MP3")
    func formatRouting() {
        #expect(TVPlaybackFormatRoutingPolicy.delivery(
            for: .opus,
            isVideo: false,
            serverTranscodesWMA: false
        ) == .decodedTemporaryFile(fileExtension: "opus", inspectWAVAfterDownload: false))
        #expect(TVPlaybackFormatRoutingPolicy.delivery(
            for: .au,
            isVideo: false,
            serverTranscodesWMA: false
        ) == .avPlayer(fileExtension: "au"))
        #expect(TVPlaybackFormatRoutingPolicy.delivery(
            for: .wma,
            isVideo: false,
            serverTranscodesWMA: true
        ) == .avPlayer(fileExtension: "mp3"))
    }

    @Test("DTS-in-WAV never enters native range playback")
    func dtsWAVRouting() {
        #expect(TVPlaybackFormatRoutingPolicy.delivery(
            for: .wav,
            isVideo: false,
            serverTranscodesWMA: false,
            wavProbeOutcome: .dts
        ) == .decodedTemporaryFile(fileExtension: "dts", inspectWAVAfterDownload: false))
        #expect(TVPlaybackFormatRoutingPolicy.delivery(
            for: .wav,
            isVideo: false,
            serverTranscodesWMA: false,
            wavProbeOutcome: .unavailable
        ) == .decodedTemporaryFile(fileExtension: "wav", inspectWAVAfterDownload: true))
    }

    @Test("Range responses must match the requested physical window")
    func strictRangeValidation() {
        #expect(TVHTTPRangeResponsePolicy.validate(
            statusCode: 206,
            contentRange: "bytes 100-199/1000",
            contentLength: 100,
            contentEncoding: nil,
            requestedOffset: 100,
            requestedLength: 100,
            isLiveStream: false
        )?.expectedBodyLength == 100)
        #expect(TVHTTPRangeResponsePolicy.validate(
            statusCode: 206,
            contentRange: "bytes 0-99/1000",
            contentLength: 100,
            contentEncoding: nil,
            requestedOffset: 100,
            requestedLength: 100,
            isLiveStream: false
        ) == nil)
        #expect(TVHTTPRangeResponsePolicy.validate(
            statusCode: 200,
            contentRange: nil,
            contentLength: 1000,
            contentEncoding: nil,
            requestedOffset: 0,
            requestedLength: 2,
            isLiveStream: false
        ) == nil)
        #expect(TVHTTPRangeResponsePolicy.validate(
            statusCode: 416,
            contentRange: "bytes */1000",
            contentLength: 0,
            contentEncoding: nil,
            requestedOffset: 1000,
            requestedLength: 100,
            isLiveStream: false
        )?.expectedBodyLength == 0)
    }

    @Test("Live streams accept an unknown-length successful response")
    func liveResponseValidation() {
        #expect(TVHTTPRangeResponsePolicy.validate(
            statusCode: 200,
            contentRange: nil,
            contentLength: nil,
            contentEncoding: nil,
            requestedOffset: 0,
            requestedLength: -1,
            isLiveStream: true
        ) != nil)
    }

    @Test("Temporary downloads preserve a storage reserve")
    func downloadBudget() {
        let available = TVDecodedDownloadStoragePolicy.reservedCapacity + 1_024
        let budget = TVDecodedDownloadStoragePolicy.writableBudget(
            availableCapacity: available
        )
        #expect(budget == 1_024)
        #expect(TVDecodedDownloadStoragePolicy.accepts(
            contentLength: 1_024,
            writableBudget: budget
        ))
        #expect(!TVDecodedDownloadStoragePolicy.accepts(
            contentLength: 1_025,
            writableBudget: budget
        ))
    }

    @Test("Radio headers keep authentication initially and strip all custom tokens cross-origin")
    func radioHeaderBoundary() {
        let custom = [
            "Authorization": "Bearer secret",
            "X-Plex-Token": "secret-2",
            "User-Agent": "RequiredAgent/1",
            "Bad\r\nHeader": "injected",
        ]
        let merged = TVRadioRequestHeaderPolicy.merged(customHeaders: custom)
        #expect(merged["Authorization"] == "Bearer secret")
        #expect(merged["X-Plex-Token"] == "secret-2")
        #expect(merged["User-Agent"] == "RequiredAgent/1")
        #expect(merged["Icy-MetaData"] == "1")
        #expect(merged["Accept-Encoding"] == "identity")
        #expect(!merged.keys.contains("Bad\r\nHeader"))

        var request = URLRequest(url: URL(string: "https://cdn.example/audio")!)
        for (name, value) in merged {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let stripped = TVRadioRequestHeaderPolicy.strippingCustomHeaders(
            from: request,
            customHeaderNames: Array(custom.keys)
        )
        #expect(stripped.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(stripped.value(forHTTPHeaderField: "X-Plex-Token") == nil)
        #expect(stripped.value(forHTTPHeaderField: "Icy-MetaData") == "1")
        #expect(stripped.value(forHTTPHeaderField: "User-Agent") == "Primuse/Radio")
    }

    @Test("Radio redirects preserve credentials only on the approved endpoint")
    func radioRedirectBoundary() throws {
        let custom = [
            "Authorization": "Bearer secret",
            "X-Plex-Token": "secret-2",
        ]
        var original = URLRequest(url: URL(string: "http://radio.example/live.flac")!)
        for (name, value) in TVRadioRequestHeaderPolicy.merged(customHeaders: custom) {
            original.setValue(value, forHTTPHeaderField: name)
        }

        let sameEndpointResponse = try #require(HTTPURLResponse(
            url: original.url!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "/next.flac"]
        ))
        let sameEndpoint = try #require(TVRadioRedirectRequestPolicy.redirectedRequest(
            from: original,
            response: sameEndpointResponse,
            customHeaders: custom
        ))
        #expect(sameEndpoint.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(sameEndpoint.value(forHTTPHeaderField: "X-Plex-Token") == "secret-2")

        let crossEndpointResponse = try #require(HTTPURLResponse(
            url: original.url!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "https://cdn.example/live.flac"]
        ))
        let crossEndpoint = try #require(TVRadioRedirectRequestPolicy.redirectedRequest(
            from: original,
            response: crossEndpointResponse,
            customHeaders: custom
        ))
        #expect(crossEndpoint.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(crossEndpoint.value(forHTTPHeaderField: "X-Plex-Token") == nil)
        #expect(crossEndpoint.value(forHTTPHeaderField: "Icy-MetaData") == "1")
        #expect(crossEndpoint.value(forHTTPHeaderField: "Accept-Encoding") == "identity")

        let downgradeResponse = try #require(HTTPURLResponse(
            url: URL(string: "https://radio.example:8443/live.flac")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "http://radio.example:8080/live.flac"]
        ))
        #expect(TVRadioRedirectRequestPolicy.redirectedRequest(
            from: original,
            response: downgradeResponse,
            customHeaders: custom
        ) == nil)
    }
}
