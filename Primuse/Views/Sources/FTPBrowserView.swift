import SwiftUI
import PrimuseKit

struct FTPBrowserView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]

    private let connector: any MusicSourceConnector

    init(source: MusicSource, selectedDirectories: Binding<[String]>) {
        self.source = source
        self._selectedDirectories = selectedDirectories
        self.connector = FTPSource(
            sourceID: source.id,
            host: source.host ?? "",
            port: source.port,
            basePath: source.basePath,
            username: source.username ?? "",
            password: KeychainService.getPassword(for: source.id) ?? "",
            encryption: source.ftpEncryption ?? .none
        )
    }

    var body: some View {
        ConnectorDirectoryBrowserView(
            source: source,
            connector: connector,
            selectedDirectories: $selectedDirectories
        )
    }
}
