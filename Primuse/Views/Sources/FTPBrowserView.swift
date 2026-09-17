import SwiftUI
import PrimuseKit

struct FTPBrowserView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]

    private let connector: any MusicSourceConnector
    private let onEditAddress: (() -> Void)?

    init(
        source: MusicSource,
        connector: any MusicSourceConnector,
        selectedDirectories: Binding<[String]>,
        onEditAddress: (() -> Void)? = nil
    ) {
        self.source = source
        self._selectedDirectories = selectedDirectories
        self.connector = connector
        self.onEditAddress = onEditAddress
    }

    var body: some View {
        ConnectorDirectoryBrowserView(
            source: source,
            connector: connector,
            selectedDirectories: $selectedDirectories,
            onEditAddress: onEditAddress
        )
    }
}
