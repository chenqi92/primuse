import SwiftUI
import PrimuseKit

struct WebDAVBrowserView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]

    private let connector: any MusicSourceConnector

    init(source: MusicSource, selectedDirectories: Binding<[String]>) {
        self.source = source
        self._selectedDirectories = selectedDirectories
        self.connector = WebDAVSource(
            sourceID: source.id,
            host: source.host ?? "",
            port: source.port,
            basePath: source.basePath,
            username: source.username ?? "",
            password: KeychainService.getPassword(for: source.id) ?? ""
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
