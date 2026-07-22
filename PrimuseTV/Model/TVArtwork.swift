#if os(tvOS)
import SwiftUI
import UIKit
import CryptoKit
import PrimuseKit

/// tvOS 封面加载:本地缓存 → iTunes Search API 在线取 → 落盘缓存。
/// 本地曲库的封面缓存没同步到 tvOS,所以这里按「艺术家 + 专辑名」在线取真实封面;
/// 取不到时各卡片回退到程序化封面。纯 URLSession,自包含。
actor TVArtworkLoader {
    static let shared = TVArtworkLoader()

    private var inFlight: [String: Task<Data?, Never>] = [:]
    private var negative: Set<String> = []   // 查不到的,本次会话不再反复请求

    private var cacheDir: URL {
        let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        let dir = base.appendingPathComponent("PrimuseTVArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func diskURL(_ key: String) -> URL {
        let h = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(h).jpg")
    }

    /// 按 (artist, album) 取专辑封面 Data;key 用于缓存去重(一般传 albumID)。
    func cover(key: String, artist: String, album: String) async -> Data? {
        guard !key.isEmpty, !(artist.isEmpty && album.isEmpty) else { return nil }
        let disk = diskURL(key)
        if let data = try? Data(contentsOf: disk) { return data }
        if negative.contains(key) { return nil }
        if let t = inFlight[key] { return await t.value }
        let task = Task<Data?, Never> {
            let data = await Self.fetchITunes(term: "\(artist) \(album)".trimmingCharacters(in: .whitespaces))
            if let data { try? data.write(to: disk, options: .atomic) }
            return data
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if result == nil { negative.insert(key) }
        return result
    }

    private static func fetchITunes(term: String) async -> Data? {
        guard !term.isEmpty,
              var comps = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = comps.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = json?["results"] as? [[String: Any]] ?? []
            guard let art = results.first?["artworkUrl100"] as? String else { return nil }
            let hi = art.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let imgURL = URL(string: hi) else { return nil }
            let (imgData, _) = try await URLSession.shared.data(from: imgURL)
            return imgData.isEmpty ? nil : imgData
        } catch {
            return nil
        }
    }
}

/// 封面视图:加载到真实封面就显示,否则用程序化封面占位/兜底。
struct TVArtworkView: View {
    var coverKey: String          // 缓存键(专辑 id)
    var artist: String
    var album: String
    // 程序化兜底参数
    var tint: Color
    var tint2: Color
    var glyph: String
    var size: CGFloat
    var height: CGFloat? = nil
    var radius: CGFloat = 0

    @State private var image: UIImage? = nil
    @State private var loadedKey: String? = nil

    var body: some View {
        let h = height ?? size
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                TVCoverArt(tint: tint, tint2: tint2, glyph: glyph, size: size, height: h)
            }
        }
        .frame(width: size, height: h)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: coverKey) {
            guard loadedKey != coverKey else { return }
            // key 变了:先清掉上一张专辑的封面,回到程序化占位再取新图
            image = nil
            let key = coverKey
            // ① 扫描时从文件读出的内嵌专辑封面(本机缓存,无需联网)优先
            if !key.isEmpty,
               let data = await MetadataAssetStore.shared.cachedAlbumCover(forAlbumID: key),
               let ui = UIImage(data: data) {
                guard key == coverKey else { return }
                image = ui
                loadedKey = key
                return
            }
            // ② 否则按 (艺术家, 专辑) 在线取真实封面
            if let data = await TVArtworkLoader.shared.cover(key: key, artist: artist, album: album),
               let ui = UIImage(data: data) {
                // 回填前校验 key 仍是当前值,防止慢加载串图
                guard key == coverKey else { return }
                image = ui
            }
            loadedKey = key
        }
    }

    init(album a: TVAlbum, size: CGFloat, height: CGFloat? = nil, radius: CGFloat = 0) {
        self.coverKey = a.id; self.artist = a.artist; self.album = a.title
        self.tint = a.tint; self.tint2 = a.tint2; self.glyph = a.glyph
        self.size = size; self.height = height; self.radius = radius
    }
    init(coverKey: String, artist: String, album: String, tint: Color, tint2: Color,
         glyph: String, size: CGFloat, height: CGFloat? = nil, radius: CGFloat = 0) {
        self.coverKey = coverKey; self.artist = artist; self.album = album
        self.tint = tint; self.tint2 = tint2; self.glyph = glyph
        self.size = size; self.height = height; self.radius = radius
    }
}
#endif
