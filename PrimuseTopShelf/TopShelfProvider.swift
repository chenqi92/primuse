import Foundation
import TVServices
import PrimuseKit

/// Apple TV 顶部「内容展示」(Top Shelf)。
///
/// 读 App Group 里主 app 预取好的 `topshelf.json` + 封面缩略图,渲染成可滚动的分区
/// 内容(最近播放 / 资料库专辑);点击经 deep link(`primuse://`)唤起主 app 播放。
/// 扩展是独立进程,这里零网络、零凭据,直接读本地共享文件,秒开。
final class TopShelfProvider: TVTopShelfContentProvider {

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let payload = TopShelfStore.load() else {
            completionHandler(nil)
            return
        }

        let sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = payload.sections.compactMap { section in
            let items: [TVTopShelfSectionedItem] = section.items.map { item in
                let shelf = TVTopShelfSectionedItem(identifier: item.id)
                shelf.title = item.title
                shelf.imageShape = .square
                if let progress = item.playbackProgress, progress.isFinite {
                    shelf.playbackProgress = min(1, max(0, progress))
                }

                if let name = item.imageFileName,
                   let url = TopShelfStore.coverURL(name),
                   FileManager.default.fileExists(atPath: url.path) {
                    shelf.setImageURL(url, for: .screenScale1x)
                    shelf.setImageURL(url, for: .screenScale2x)
                }

                if let target = URL(string: item.playURL) {
                    let action = TVTopShelfAction(url: target)
                    shelf.displayAction = action
                    shelf.playAction = action
                }
                return shelf
            }
            guard !items.isEmpty else { return nil }
            let collection = TVTopShelfItemCollection(items: items)
            collection.title = section.title
            return collection
        }

        guard !sections.isEmpty else {
            completionHandler(nil)
            return
        }
        completionHandler(TVTopShelfSectionedContent(sections: sections))
    }
}
