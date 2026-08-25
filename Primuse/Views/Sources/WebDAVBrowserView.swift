import SwiftUI
import PrimuseKit

struct WebDAVBrowserView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]

    private let connector: any MusicSourceConnector
    private let onConfirm: ((Bool) -> Void)?

    init(
        source: MusicSource,
        connector: any MusicSourceConnector,
        selectedDirectories: Binding<[String]>,
        onConfirm: ((Bool) -> Void)? = nil
    ) {
        self.source = source
        self._selectedDirectories = selectedDirectories
        self.connector = connector
        self.onConfirm = onConfirm
    }

    var body: some View {
        ConnectorDirectoryBrowserView(
            source: source,
            connector: connector,
            selectedDirectories: $selectedDirectories,
            onConfirm: onConfirm
        )
    }
}
