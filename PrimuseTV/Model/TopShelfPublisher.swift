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
        let playURL: String
    }

    static func publish(recent: [Draft], albums: [Draft]) async {
        // 没配 App Group(旧版 / 未签 entitlement)时 containerURL 为 nil,直接跳过。
        guard TopShelfStore.containerURL != nil else { return }

        var sections: [TopShelfSection] = []
        let recentItems = await items(from: recent)
        if !recentItems.isEmpty {
            sections.append(TopShelfSection(id: "recent", title: "最近播放", items: recentItems))
        }
        let albumItems = await items(from: albums)
        if !albumItems.isEmpty {
            sections.append(TopShelfSection(id: "albums", title: "资料库", items: albumItems))
        }
        TopShelfStore.save(TopShelfPayload(sections: sections))
        // 通知系统 Top Shelf 内容已变,促其在下次机会重新向扩展取数据(否则停留旧值/空)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private static func items(from drafts: [Draft]) async -> [TopShelfItem] {
        var out: [TopShelfItem] = []
        for d in drafts {
            let file = await cover(key: d.id, artist: d.artist, album: d.album, title: d.title)
            out.append(TopShelfItem(id: d.id, title: d.title, subtitle: d.subtitle,
                                    imageFileName: file, playURL: d.playURL))
        }
        return out
    }

    /// 取封面写入 App Group 封面目录,返回文件名。优先在线真实封面(TVArtworkLoader 内部缓存,
    /// 命中后下次走缓存),取不到则画一张与 app 内卡片一致的程序化占位(渐变 + 唱片纹 + 首字),
    /// 保证 Top Shelf 不出现空白方块。
    private static func cover(key: String, artist: String, album: String, title: String) async -> String? {
        guard let dir = TopShelfStore.coversDirectory, !key.isEmpty else { return nil }
        let name = SHA256.hash(data: Data(key.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined() + ".jpg"
        let dest = dir.appendingPathComponent(name)
        if let data = await TVArtworkLoader.shared.cover(key: key, artist: artist, album: album),
           !data.isEmpty {
            try? data.write(to: dest, options: .atomic)
            return name
        }
        if let placeholder = placeholderCover(seed: key, glyph: glyph(title)) {
            try? placeholder.write(to: dest, options: .atomic)
            return name
        }
        return nil
    }

    // MARK: 程序化占位封面(与 PrimuseTV/Views 的 TVCoverArt 视觉一致)

    private static func glyph(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "♪" : String(t.prefix(1))
    }

    /// 由字符串确定性派生封面两端色(与 TVStore.tint 同算法,保证同一专辑色一致)。
    private static func tintColors(_ seed: String) -> (UIColor, UIColor) {
        var h: UInt64 = 5381
        for b in seed.utf8 { h = (h &* 33) &+ UInt64(b) }
        let hue = CGFloat(h % 360) / 360.0
        return (UIColor(hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1),
                UIColor(hue: hue, saturation: 0.62, brightness: 0.22, alpha: 1))
    }

    private static func placeholderCover(seed: String, glyph: String) -> Data? {
        let side: CGFloat = 512
        let size = CGSize(width: side, height: side)
        let (c1, c2) = tintColors(seed)
        let image = UIGraphicsImageRenderer(size: size).image { rc in
            let ctx = rc.cgContext
            let cs = CGColorSpaceCreateDeviceRGB()
            if let grad = CGGradient(colorsSpace: cs, colors: [c1.cgColor, c2.cgColor] as CFArray,
                                     locations: [0, 1]) {
                ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: side, y: side), options: [])
            }
            if let hl = CGGradient(colorsSpace: cs,
                                   colors: [UIColor.white.withAlphaComponent(0.30).cgColor,
                                            UIColor.white.withAlphaComponent(0).cgColor] as CFArray,
                                   locations: [0, 1]) {
                let c = CGPoint(x: side * 0.30, y: side * 0.25)
                ctx.drawRadialGradient(hl, startCenter: c, startRadius: 0,
                                       endCenter: c, endRadius: side * 0.6, options: [])
            }
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.18).cgColor)
            ctx.setLineWidth(1.2)
            for r in [0.42, 0.34, 0.26] as [CGFloat] {
                let d = side * r
                ctx.strokeEllipse(in: CGRect(x: side/2 - d, y: side/2 - d, width: d * 2, height: d * 2))
            }
            let fontSize: CGFloat = glyph.count > 1 ? side * 0.26 : side * 0.40
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
                .paragraphStyle: para,
            ]
            let s = NSAttributedString(string: glyph, attributes: attrs)
            let bb = s.size()
            s.draw(at: CGPoint(x: (side - bb.width) / 2, y: (side - bb.height) / 2))
        }
        return image.jpegData(compressionQuality: 0.9)
    }
}
#endif
