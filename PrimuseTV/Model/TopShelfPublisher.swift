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
/// 电台用自带的台标;只听电台、没有曲库的用户也能在主屏看到内容。
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

    struct RadioDraft: Sendable {
        let station: RadioStation
        let playURL: String
    }

    /// `radioLogoSource`:镜像台的音乐源和凭据。只在台标缓存没命中时才回主线程要,
    /// 发布时不预先解析(那要读钥匙串)。
    static func publish(
        recent: [Draft],
        radio: [RadioDraft],
        albums: [Draft],
        radioLogoSource: @escaping @MainActor @Sendable (String) -> TVRadioLogoSourceContext?
    ) async {
        // 没配 App Group(旧版 / 未签 entitlement)时 containerURL 为 nil,直接跳过。
        guard !Task.isCancelled, TopShelfStore.containerURL != nil else { return }

        var sections: [TopShelfSection] = []
        let recentItems = await items(from: recent)
        if !recentItems.isEmpty {
            sections.append(TopShelfSection(id: "recent", title: PMString("ext.tv.topShelf.recent"), items: recentItems))
        }
        let radioItems = await radioItems(from: radio, radioLogoSource: radioLogoSource)
        if !radioItems.isEmpty {
            sections.append(TopShelfSection(id: "radio", title: PMString("ext.tv.radio.title"), items: radioItems))
        }
        let albumItems = await items(from: albums)
        if !albumItems.isEmpty {
            sections.append(TopShelfSection(id: "albums", title: PMString("ext.tv.topShelf.library"), items: albumItems))
        }
        guard !Task.isCancelled else { return }
        let stored = TopShelfStore.load()
        // 本次要用的封面都已落盘之后再清理,正要复用的旧文件不会先被删掉。
        pruneStaleCovers(keeping: referencedCovers(in: sections).union(referencedCovers(in: stored?.sections ?? [])))
        // 每次播放、每次电台列表变化都会发布一次,内容多半没变:不重写、也不打扰系统。
        guard stored?.sections != sections else { return }
        TopShelfStore.save(TopShelfPayload(sections: sections))
        // 通知系统 Top Shelf 内容已变,促其在下次机会重新向扩展取数据(否则停留旧值/空)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private static func referencedCovers(in sections: [TopShelfSection]) -> Set<String> {
        Set(sections.flatMap(\.items).compactMap(\.imageFileName))
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

    private static func radioItems(
        from drafts: [RadioDraft],
        radioLogoSource: @escaping @MainActor @Sendable (String) -> TVRadioLogoSourceContext?
    ) async -> [TopShelfItem] {
        // 台标并发取(同时下载数由 TVRadioLogoLoader 限住),逐个等的话 10 个台最坏要两分钟,
        // 而每次播放、每次电台重载都会触发一次发布。镜像台的音乐源台标也受同一个闸门限制,
        // 并且与卡片共用 `songCover` 的请求去重,同一张图不会取两次。
        let logos = await withTaskGroup(of: (Int, Data?).self) { group in
            for (index, draft) in drafts.enumerated() {
                let station = draft.station
                group.addTask {
                    (index, await TVRadioLogoLoader.data(for: station, sourceContext: radioLogoSource))
                }
            }
            var byIndex: [Int: Data] = [:]
            for await (index, data) in group {
                if let data { byIndex[index] = data }
            }
            return byIndex
        }
        var out: [TopShelfItem] = []
        for (index, d) in drafts.enumerated() {
            guard !Task.isCancelled else { return [] }
            let station = d.station
            out.append(TopShelfItem(id: station.id, title: station.name,
                                    subtitle: station.tvPlaybackSubtitle,
                                    imageFileName: radioCover(for: station, logo: logos[index]),
                                    playURL: d.playURL))
        }
        return out
    }

    /// 电台封面文件按**输入**命名(台标字节的摘要,或占位的种子与图标),文件已在就直接复用:
    /// 每次发布不再把十张 608/1216 像素的图重新画一遍、编码一遍、写一遍。
    private static func radioCover(for station: RadioStation, logo: Data?) -> String? {
        if let logo {
            let name = inputCoverName(key: station.id, variant: "logo-v1", input: sha256Hex(logo))
            if let name = existingOrRendered(name, render: { radioLogoCover(logo) }) {
                return name
            }
        }
        return placeholderCoverFile(seed: station.id, symbolName: "radio.fill")
    }

    /// 占位图只由种子和图标决定,同样按输入命名、画过一次就复用。
    private static func placeholderCoverFile(seed: String, symbolName: String? = nil) -> String? {
        let name = inputCoverName(key: seed, variant: "placeholder-v1", input: symbolName ?? "brand")
        return existingOrRendered(name) { placeholderCover(seed: seed, symbolName: symbolName) }
    }

    /// 必须是跨启动稳定的摘要(不能用 `Hasher`,它每次启动换种子,文件名就对不上了)。
    /// 改了渲染方式要升 `variant` 的版本号,让系统不再命中旧图。
    private static func inputCoverName(key: String, variant: String, input: String) -> String {
        sha256Hex(Data("\(key)|topshelf-\(variant)|\(input)".utf8), bytes: 16) + ".jpg"
    }

    private static func existingOrRendered(_ name: String, render: () -> Data?) -> String? {
        guard let dir = TopShelfStore.coversDirectory else { return nil }
        let dest = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return name }
        guard !Task.isCancelled, let output = render() else { return nil }
        do {
            try output.write(to: dest, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    private static func sha256Hex(_ data: Data, bytes: Int = 12) -> String {
        SHA256.hash(data: data).prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// 台标尺寸五花八门(常见几十像素的 favicon、透明底 PNG),统一铺满到深色方形底上,
    /// 与 app 内电台卡片的 scaledToFill 裁切一致。
    private static func radioLogoCover(_ data: Data) -> Data? {
        guard let logo = UIImage(data: data), logo.size.width > 0, logo.size.height > 0 else { return nil }
        // 同一个文件同时给 1x 与 2x 的位置用：画布跟着台标本身的像素走，大图保住 2x 的细节，
        // 几十像素的 favicon 也不必放大到 1216。
        let side: CGFloat = min(1216, max(608, min(logo.size.width, logo.size.height)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { rc in
            UIColor(white: 0.11, alpha: 1).setFill()
            rc.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let scale = max(side / logo.size.width, side / logo.size.height)
            let w = logo.size.width * scale
            let h = logo.size.height * scale
            logo.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        return image.jpegData(compressionQuality: 0.9)
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
        guard TopShelfStore.coversDirectory != nil, !key.isEmpty else { return nil }
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
        guard !Task.isCancelled else { return nil }
        guard let output = data.flatMap({ $0.isEmpty ? nil : $0 }) else {
            return placeholderCoverFile(seed: key)
        }
        return writeCover(output, key: key)
    }

    private static func writeCover(_ output: Data, key: String) -> String? {
        guard !key.isEmpty else { return nil }
        // 把实际图像内容纳入 URL：占位后来被真实封面替换时，tvOS 不会继续命中旧图缓存。
        // 文件名由内容决定，已经写过的同一张图不再重写。
        let name = sha256Hex(Data("\(key)|topshelf-art-v3|\(sha256Hex(output))".utf8), bytes: 16) + ".jpg"
        return existingOrRendered(name) { output }
    }

    /// 文件名随内容或输入变化，更新后的封面会换新文件。仅清理一周前且不在 `referenced`
    /// （本次与上一次发布引用到的）里的 JPEG，既限制长期缓存增长，也给 Top Shelf 扩展的旧快照留出读取窗口。
    private static func pruneStaleCovers(keeping referenced: Set<String>) {
        guard let dir = TopShelfStore.coversDirectory else { return }
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

    private static func placeholderCover(seed: String, symbolName: String? = nil) -> Data? {
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

            let symbolConfig = UIImage.SymbolConfiguration(pointSize: side * 0.23, weight: .semibold)
            let icon = symbolName.flatMap { UIImage(systemName: $0, withConfiguration: symbolConfig) }
                ?? UIImage(named: "BrandGlyph")
                ?? UIImage(systemName: "music.note", withConfiguration: symbolConfig)
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
