import Foundation
import PrimuseKit

struct RemoteFileItem: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: Date?
}

protocol MusicSourceConnector: Sendable {
    var sourceID: String { get }
    func connect() async throws
    func disconnect() async
    func listFiles(at path: String) async throws -> [RemoteFileItem]
    func localURL(for path: String) async throws -> URL
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error>
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error>
}
