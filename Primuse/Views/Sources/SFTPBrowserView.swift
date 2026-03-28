import SwiftUI
import PrimuseKit

struct SFTPBrowserView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]

    private let connector: any MusicSourceConnector

    init(source: MusicSource, selectedDirectories: Binding<[String]>) {
        self.source = source
        self._selectedDirectories = selectedDirectories
        self.connector = SFTPSource(
            sourceID: source.id,
            host: source.host ?? "",
            port: source.port,
            basePath: source.basePath,
            username: source.username ?? "",
            secret: KeychainService.getPassword(for: source.id) ?? "",
            authType: source.authType
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
