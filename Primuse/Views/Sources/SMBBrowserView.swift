import SwiftUI
import PrimuseKit

struct SMBBrowserView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]

    private let connector: any MusicSourceConnector
    private let onConfirm: ((Bool) -> Void)?
    private let onEditAddress: (() -> Void)?

    init(
        source: MusicSource,
        connector: any MusicSourceConnector,
        selectedDirectories: Binding<[String]>,
        onConfirm: ((Bool) -> Void)? = nil,
        onEditAddress: (() -> Void)? = nil
    ) {
        self.source = source
        self._selectedDirectories = selectedDirectories
        self.connector = connector
        self.onConfirm = onConfirm
        self.onEditAddress = onEditAddress
    }

    var body: some View {
        ConnectorDirectoryBrowserView(
            source: source,
            connector: connector,
            selectedDirectories: $selectedDirectories,
            onConfirm: onConfirm,
            onEditAddress: onEditAddress
        )
    }
}
