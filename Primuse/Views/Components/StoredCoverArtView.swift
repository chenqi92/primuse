import SwiftUI

struct StoredCoverArtView: View {
    let fileName: String?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 8

    @State private var data: Data?

    var body: some View {
        CoverArtView(data: data, size: size, cornerRadius: cornerRadius)
            .task(id: fileName) {
                data = await loadData(for: fileName)
            }
    }
}

struct StoredArtworkView: View {
    let fileName: String?
    var cornerRadius: CGFloat = 16

    @State private var data: Data?

    var body: some View {
        ArtworkView(data: data, cornerRadius: cornerRadius)
            .task(id: fileName) {
                data = await loadData(for: fileName)
            }
    }
}

private func loadData(for fileName: String?) async -> Data? {
    guard let fileName, fileName.isEmpty == false else {
        return nil
    }

    if let remoteURL = URL(string: fileName), remoteURL.scheme != nil {
        do {
            let (data, response) = try await URLSession.shared.data(from: remoteURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    return await MetadataAssetStore.shared.coverData(named: fileName)
}
