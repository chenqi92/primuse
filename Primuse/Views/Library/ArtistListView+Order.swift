import Foundation
import PrimuseKit
import SwiftUI

#if os(iOS)
/// 资料库艺人页一次排序的输入：列法 + 曲库给的那份数组。曲库每次发布都换一份新数组，
/// 所以数组按存储地址与个数认（同 `AlbumGridOrderRequest`）；排好的结果留着那份数组，
/// 它的地址在被留着期间不会分给别的数组。
struct ArtistBrowseOrderRequest: Hashable, Sendable {
    let mode: ArtistBrowseMode
    private let sourceAddress: Int
    private let sourceCount: Int

    init(mode: ArtistBrowseMode, artists: [Artist]) {
        self.mode = mode
        sourceCount = artists.count
        sourceAddress = artists.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { Int(bitPattern: $0) } ?? 0
        }
    }

    func matches(_ artists: [Artist]) -> Bool {
        self == ArtistBrowseOrderRequest(mode: mode, artists: artists)
    }
}

/// 按读音排好的艺人，连同字母条。
struct ArtistBrowseOrdered: Sendable {
    let request: ArtistBrowseOrderRequest
    let source: [Artist]
    let items: [Artist]
    let railModel: LibraryIndexRailModel?

    /// 在后台调用。「未知艺术家」排最后。
    static func prepare(
        request: ArtistBrowseOrderRequest, source: [Artist], unknownArtistName: String
    ) -> ArtistBrowseOrdered? {
        let layout = LibraryArtistBrowseLayoutBuilder.layout(artists: source, unknownArtistName: unknownArtistName)
        guard !Task.isCancelled else { return nil }
        let model = LibraryIndexRailModel(sections: layout.sections)
        return ArtistBrowseOrdered(
            request: request, source: source, items: layout.items,
            railModel: layout.items.count >= 24 && model.isUseful ? model : nil
        )
    }
}

/// 最近一次排好的结果：换页回来、iPad 侧栏和资料库里同时开着都不必重排。
/// 不是 Observable：结果由各页自己的 @State 交付。
@MainActor
final class ArtistBrowseOrderCache {
    static let shared = ArtistBrowseOrderCache()
    private var latest: ArtistBrowseOrdered?

    func entry(for request: ArtistBrowseOrderRequest) -> ArtistBrowseOrdered? {
        latest?.request == request ? latest : nil
    }

    func store(_ entry: ArtistBrowseOrdered) {
        let previous = latest
        latest = entry
        Task.detached(priority: .utility) { withExtendedLifetime(previous) {} }
    }
}
#endif
