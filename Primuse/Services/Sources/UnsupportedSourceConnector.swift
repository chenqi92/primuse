import Foundation
import PrimuseKit

actor UnsupportedSourceConnector: MusicSourceConnector {
    let sourceID: String
    private let sourceType: MusicSourceType

    init(sourceID: String, sourceType: MusicSourceType) {
        self.sourceID = sourceID
        self.sourceType = sourceType
    }

    func connect() async throws {
        throw unsupportedError
    }

    func disconnect() async {}

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        throw unsupportedError
    }

    func localURL(for path: String) async throws -> URL {
        throw unsupportedError
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw unsupportedError
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        throw unsupportedError
    }

    private var unsupportedError: SourceError {
        .connectionFailed("\(sourceType.displayName) is not implemented yet")
    }
}
