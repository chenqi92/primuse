#if os(tvOS)
import Foundation
import CryptoKit
import UIKit
import TVServices
import PrimuseKit

/// 把 Top Shelf 展示数据 + 封面预取到 App Group 共享容器,供 Top Shelf 扩展读取。
///
/// 扩展是独立进程,读不到主 app 私有的曲库快照,也没有源凭据。所以由主 app 侧在
/// 曲库刷新后,把「最近播放 / 资料库专辑」连同封面缩略图一次性写到共享容器,扩展
/// 直接读本地文件秒开。封面复用 `TVArtworkLoader`(本地缓存 → iTunes 在线取)。
enum TopShelfPublisher {
    struct Draft: Sendable {
        let id: String
        let title: String
        let subtitle: String
        let artist: String
        let album: String
        let coverKey: String
        let songID: String?
        let coverRef: String?
        let playURL: String
    }

    static func publish(recent: [Draft], albums: [Draft]) async {
        // 没配 App Group(旧版 / 未签 entitlement)时 containerURL 为 nil,直接跳过。
        guard !Task.isCancelled, TopShelfStore.containerURL != nil else { return }
        pruneStaleCovers()

        var sections: [TopShelfSection] = []
        let recentItems = await items(from: recent)
        if !recentItems.isEmpty {
            sections.append(TopShelfSection(id: "recent", title: PMString("ext.tv.topShelf.recent"), items: recentItems))
        }
        let albumItems = await items(from: albums)
        if !albumItems.isEmpty {
            sections.append(TopShelfSection(id: "albums", title: PMString("ext.tv.topShelf.library"), items: albumItems))
        }
        guard !Task.isCancelled else { return }
        TopShelfStore.save(TopShelfPayload(sections: sections))
        // 通知系统 Top Shelf 内容已变,促其在下次机会重新向扩展取数据(否则停留旧值/空)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private static func items(from drafts: [Draft]) async -> [TopShelfItem] {
        var out: [TopShelfItem] = []
        for d in drafts {
            guard !Task.isCancelled else { return [] }
            let file = await cover(
                key: d.id,
                coverKey: d.coverKey,
                songID: d.songID,
                coverRef: d.coverRef,
                artist: d.artist,
                album: d.album
            )
            out.append(TopShelfItem(id: d.id, title: d.title, subtitle: d.subtitle,
                                    imageFileName: file, playURL: d.playURL))
        }
        return out
    }

    /// 取封面写入 App Group 封面目录,返回文件名。优先准确的本地专辑/歌曲封面,
    /// 最后才尝试在线专辑搜索；全部取不到时画一张与 app 内卡片一致的品牌音乐占位,
    /// 保证 Top Shelf 不出现空白方块。
    private static func cover(
        key: String,
        coverKey: String,
        songID: String?,
        coverRef: String?,
        artist: String,
        album: String
    ) async -> String? {
        guard let dir = TopShelfStore.coversDirectory, !key.isEmpty else { return nil }
        var data: Data? = nil
        if !coverKey.isEmpty {
            if let cached = await MetadataAssetStore.shared.cachedAlbumCover(
                forAlbumID: coverKey
            ) {
                data = cached
            }
        }
        if data == nil, let songID, !songID.isEmpty {
            // 准确的歌曲缓存/引用优先于按文本搜索到的专辑候选。
            data = await TVArtworkLoader.shared.songCover(
                songID: songID,
                coverRef: coverRef
            )
        }
        if data == nil, !coverKey.isEmpty {
            data = await TVArtworkLoader.shared.cover(
                key: coverKey,
                artist: artist,
                album: album
            )
        }
        guard !Task.isCancelled,
              let output = data.flatMap({ $0.isEmpty ? nil : $0 })
                ?? placeholderCover(seed: key) else { return nil }

        // 把实际图像内容纳入 URL：占位后来被真实封面替换时，tvOS 不会继续命中旧图缓存。
        let imageDigest = SHA256.hash(data: output).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
        let cacheKey = "\(key)|topshelf-art-v3|\(imageDigest)"
        let name = SHA256.hash(data: Data(cacheKey.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined() + ".jpg"
        let dest = dir.appendingPathComponent(name)
        try? output.write(to: dest, options: .atomic)
        return name
    }

    /// 内容摘要会为更新后的封面生成新文件名。仅清理一周前且不被当前 payload
    /// 引用的 JPEG，既限制长期缓存增长，也给 Top Shelf 扩展的旧快照留出读取窗口。
    private static func pruneStaleCovers() {
        guard let dir = TopShelfStore.coversDirectory else { return }
        let referenced = Set(
            TopShelfStore.load()?.sections
                .flatMap(\.items)
                .compactMap(\.imageFileName) ?? []
        )
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for file in files where file.pathExtension.lowercased() == "jpg"
                && !referenced.contains(file.lastPathComponent) {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: 品牌音乐占位(与 PrimuseTV/Views 的 TVMusicPlaceholder 视觉一致)

    /// 由字符串确定性派生封面两端色(与 TVStore.tint 同算法,保证同一专辑色一致)。
    private static func tintColors(_ seed: String) -> (UIColor, UIColor) {
        var h: UInt64 = 5381
        for b in seed.utf8 { h = (h &* 33) &+ UInt64(b) }
        // 限制为少量低饱和色域，保留卡片差异但避免随机黄橙色变成大片泥棕色。
        let hues: [CGFloat] = [0.02, 0.46, 0.58, 0.69, 0.86]
        let hue = hues[Int(h % UInt64(hues.count))]
        return (UIColor(hue: hue, saturation: 0.38, brightness: 0.58, alpha: 1),
                UIColor(hue: hue, saturation: 0.30, brightness: 0.22, alpha: 1))
    }

    private static func placeholderCover(seed: String) -> Data? {
        // 1216px 可同时覆盖 Top Shelf 方形内容的 1x/2x 聚焦放大需求。
        let side: CGFloat = 1216
        let size = CGSize(width: side, height: side)
        let (c1, c2) = tintColors(seed)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { rc in
            let ctx = rc.cgContext
            let cs = CGColorSpaceCreateDeviceRGB()
            let base1 = UIColor(white: 0.17, alpha: 1)
            let base2 = UIColor(white: 0.055, alpha: 1)
            if let grad = CGGradient(colorsSpace: cs, colors: [base1.cgColor, base2.cgColor] as CFArray,
                                     locations: [0, 1]) {
                ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: side, y: side), options: [])
            }
            if let hl = CGGradient(colorsSpace: cs,
                                   colors: [c1.withAlphaComponent(0.70).cgColor,
                                            c1.withAlphaComponent(0).cgColor] as CFArray,
                                   locations: [0, 1]) {
                let c = CGPoint(x: side * 0.18, y: side * 0.12)
                ctx.drawRadialGradient(hl, startCenter: c, startRadius: 0,
                                       endCenter: c, endRadius: side * 0.82, options: [])
            }
            if let glow = CGGradient(colorsSpace: cs,
                                     colors: [c2.withAlphaComponent(0.68).cgColor,
                                              c2.withAlphaComponent(0).cgColor] as CFArray,
                                     locations: [0, 1]) {
                let c = CGPoint(x: side * 0.88, y: side * 0.92)
                ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0,
                                       endCenter: c, endRadius: side * 0.72, options: [])
            }

            let discSide = side * 0.48
            let discRect = CGRect(x: (side - discSide) / 2, y: (side - discSide) / 2,
                                  width: discSide, height: discSide)
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.07).cgColor)
            ctx.fillEllipse(in: discRect)
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.15).cgColor)
            ctx.setLineWidth(side * 0.004)
            ctx.strokeEllipse(in: discRect.insetBy(dx: side * 0.002, dy: side * 0.002))

            let icon = UIImage(named: "BrandGlyph")
                ?? UIImage(systemName: "music.note", withConfiguration:
                    UIImage.SymbolConfiguration(pointSize: side * 0.23, weight: .semibold))
            if let icon {
                let rendered = icon.withTintColor(
                    UIColor.white.withAlphaComponent(0.88),
                    renderingMode: .alwaysOriginal
                )
                let iconSide = side * 0.24
                rendered.draw(in: CGRect(x: (side - iconSide) / 2,
                                         y: (side - iconSide) / 2,
                                         width: iconSide, height: iconSide))
            }
        }
        return image.jpegData(compressionQuality: 0.9)
    }
}
#endif
