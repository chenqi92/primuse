#if os(macOS)
import Observation
import SwiftUI

/// Mac 首页的快照跟着歌曲模型放掉(6c 单元 4 U2a)。
extension MacHomeView.Model {
    /// 开始跟着这个曲库的歌曲模型:放掉时把快照里整库那两份列表(「最近添加」的全部专辑、全部艺人)减到
    /// 首页显示的那一段。快照挂在主窗口上,不减的话放掉的专辑、艺人数组一直被它留在内存里。
    /// 用观察而不是视图的 onChange:放掉发生在 App 隐藏、首页不在屏幕上的时候。
    func followSongModelResidency(of library: MusicLibrary) {
        guard !followsSongModelResidency else { return }
        followsSongModelResidency = true
        observeSongModelResidency(of: library)
    }

    private func observeSongModelResidency(of library: MusicLibrary) {
        withObservationTracking {
            _ = library.isReady
        } onChange: { [weak self, weak library] in
            Task { @MainActor in
                guard let self, let library else { return }
                if !library.isReady { self.songModelWasReleased() }
                self.observeSongModelResidency(of: library)
            }
        }
    }

    /// 首页上看到的不变(那一段与总数都在);「查看全部」再要全部时装回模型,首页下次出来按整库数组重算。
    func songModelWasReleased() {
        let trimmed = snapshot.keepingShownLists()
        guard trimmed.recentlyAddedAlbums.count != snapshot.recentlyAddedAlbums.count
            || trimmed.artists.count != snapshot.artists.count else { return }
        snapshot = trimmed
        signature = nil
    }
}

/// 首页「查看全部」那一页在等歌曲模型装回来时的样子:标题与总数照常,列表处转圈。
struct MacHomeCollectionLoading: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, minHeight: 160)
    }
}
#endif
