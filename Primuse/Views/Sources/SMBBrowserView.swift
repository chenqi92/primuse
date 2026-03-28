import SwiftUI
import PrimuseKit

struct SMBBrowserView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]

    private let connector: any MusicSourceConnector

    init(source: MusicSource, selectedDirectories: Binding<[String]>) {
        self.source = source
        self._selectedDirectories = selectedDirectories
        self.connector = SMBSource(
            sourceID: source.id,
            host: source.host ?? "",
            port: source.port ?? 445,
            sharePath: source.shareName ?? "",
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
