import CoreGraphics
import SwiftUI
import PrimuseKit

/// 批量添加页里那枚小小的台标缩略图。
///
/// 用户在勾选之前就该看到台标 —— 在线目录搜"jazz"能出几十条同名台，
/// 一张图比一行 URL 有用得多。
///
/// 刻意不传 `songID`：这些候选还不是电台，没有稳定身份，写进按 songID 组织的
/// 封面磁盘缓存只会留下一堆再也不会被读到的文件。这里只吃内存缓存，
/// 页面关掉就随之释放。
struct RadioCandidateLogoView: View {
    let urlString: String?
    var size: CGFloat = 40
    var cornerRadius: CGFloat = 8

    @Environment(SourceManager.self) private var sourceManager
    @State private var image: PlatformImage?
    @State private var backdrop: RadioLogoBackdrop?

    var body: some View {
        ZStack {
            if let image, let backdrop {
                // 透明底的台标不能直接压在占位图上，那圈同心环会从台标后面透出来。
                // 台标由 .task 裸赋值,曲线只能附在过渡上。
                backdrop.color
                    .pmFadeTransition(motion: .contentAppear)
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .pmFadeTransition(motion: .contentAppear)
            } else {
                // 清单没给台标、或者那张图读不出来时，显示和电台列表一样的默认台标 ——
                // 同一个电台在勾选前后不该长得不一样。
                RadioStationPlaceholderArtwork()
                    .pmFadeTransition(motion: .contentAppear)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: urlString) {
            image = nil
            backdrop = nil
            guard let urlString, !urlString.isEmpty else { return }
            let resolved = await CachedArtworkView.resolveImage(
                coverRef: urlString,
                songID: nil,
                size: size,
                sourceID: nil,
                filePath: nil,
                fileFormat: nil,
                sourceManager: sourceManager
            )
            guard !Task.isCancelled, let resolved else { return }
            let sampled = SendableRadioArtworkCGImage(value: resolved.platformCGImage)
            let sampling = Task.detached(priority: .utility) {
                RadioLogoBackdropSampler.backdrop(for: sampled.value)
            }
            let logoBackdrop = await sampling.value
            guard !Task.isCancelled else { return }
            // 台标和衬底同一次赋值，别先露一帧没垫底的台标。
            image = resolved
            backdrop = logoBackdrop
        }
    }
}
