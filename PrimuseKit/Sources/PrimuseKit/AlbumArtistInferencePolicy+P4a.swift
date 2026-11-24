import Foundation

extension AlbumArtistInferencePolicy {
    private struct VerdictScopeKey: Hashable {
        let sourceID: String
        let albumTitle: String
    }

    private struct VerdictScopeState {
        var count = 0
        var hasExplicitAlbumArtist = false
        var firstArtist: String?
        var hasSecondArtist = false

        /// 只有这样的组才可能被判成「定不了案」:至少两首、没人标了专辑艺术家、
        /// 至少两种写法的艺术家(归一化后不同的键一定是不同的写法)。
        var mayBeUnconfirmed: Bool { count >= 2 && !hasExplicitAlbumArtist && hasSecondArtist }
    }

    /// 与 `unconfirmedAlbumArtistTrackIDs(for:)` 结果相同,但不需要整库的 `Track` 数组。
    ///
    /// `forEachTrack` 会被调两遍,每遍按同一顺序交出同一批歌:第一遍只按 (源, 专辑名) 给每组记几个特征
    /// (组数与专辑同阶),第二遍只收可能定不了案的组里的歌,再交给原来的判定。各组互不影响,
    /// 组内先后不变,所以结果与整库一次判定完全一样。
    public static func unconfirmedAlbumArtistTrackIDs(
        streaming forEachTrack: ((Track) -> Void) -> Void
    ) -> Set<String> {
        var scopes: [VerdictScopeKey: VerdictScopeState] = [:]
        forEachTrack { track in
            guard let albumTitle = track.trimmedAlbumTitle else { return }
            let key = VerdictScopeKey(sourceID: track.sourceID, albumTitle: albumTitle)
            var state = scopes[key] ?? VerdictScopeState()
            state.count += 1
            if track.hasExplicitAlbumArtist { state.hasExplicitAlbumArtist = true }
            if let artist = track.effectiveArtist, !state.hasSecondArtist {
                if let first = state.firstArtist {
                    if first != artist { state.hasSecondArtist = true }
                } else {
                    state.firstArtist = artist
                }
            }
            scopes[key] = state
        }
        let candidateKeys = Set(scopes.lazy.filter { $0.value.mayBeUnconfirmed }.map(\.key))
        scopes = [:]
        guard !candidateKeys.isEmpty else { return [] }
        var candidates: [Track] = []
        forEachTrack { track in
            guard let albumTitle = track.trimmedAlbumTitle,
                  candidateKeys.contains(VerdictScopeKey(sourceID: track.sourceID, albumTitle: albumTitle)) else { return }
            candidates.append(track)
        }
        return unconfirmedAlbumArtistTrackIDs(for: candidates)
    }
}
