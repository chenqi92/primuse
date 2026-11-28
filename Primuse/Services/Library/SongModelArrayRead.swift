import Foundation
import PrimuseKit

/// 只有整库数组答得了的读(删文件时判断共用的旁挂文件、整库候选池……),iPhone 与 Mac 共用(6c 单元 4 U2b)。
/// 歌曲模型在内存里时直接读,与原来相同;放掉了(或这次启动没装)时先占用模型(`.userAction`)、等它装回来
/// 再读,读完放手。等不到(超过 `timeout`)时是 nil:「答不了」,调用方不能把它当成「没有歌」。
@MainActor
enum SongModelArrayRead {
    /// 等模型装回来的上限。整库装载在大曲库上要十几秒(P3 15b、19b 的数字),给足余量。
    static let defaultTimeout: Duration = .seconds(60)

    static func read<T>(
        _ library: MusicLibrary,
        timeout: Duration = defaultTimeout,
        _ body: @MainActor () -> T
    ) async -> T? {
        if library.isReady { return body() }
        guard let token = await hold(library, timeout: timeout) else { return nil }
        defer { token.end() }
        return body()
    }

    /// 占着歌曲模型做完 `body`:删文件、提交这类从头到尾都要整库数组的操作(UA)。模型在内存里时也登记占用,
    /// 做到一半(网盘上逐个删可能要很久)不会在后台被放掉;放掉了先装回来。`timeout` 内装不回来时不做,nil。
    static func holding<T>(
        _ library: MusicLibrary,
        timeout: Duration = defaultTimeout,
        _ body: @MainActor () async -> T
    ) async -> T? {
        guard let token = await hold(library, timeout: timeout) else { return nil }
        defer { token.end() }
        return await body()
    }

    /// 拿一个 `.userAction` 占用(日志里分得清是一个操作、不是一个页面),等模型在内存里(模型本来就在时也登记,
    /// 用完 `end()`);`timeout` 内没等到(或任务取消)时撤掉占用,nil。给一段跨几个等待的操作用(AI 歌单的生成)。
    static func hold(_ library: MusicLibrary, timeout: Duration = defaultTimeout) async -> MusicLibrary.SongModelHold? {
        // 占用放在自己的任务里,超时就取消它:`holdSongModel` 被取消时撤掉这次占用、不再等。
        let acquisition = Task { @MainActor in await library.holdSongModel(.userAction) }
        let timer = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            acquisition.cancel()
        }
        let hold = await acquisition.value
        timer.cancel()
        guard library.isReady else {
            hold.end()
            plog("🧠 residency array read gave up: the song model did not come back within \(timeout)")
            return nil
        }
        return hold
    }

    /// 删一首歌的源文件时,同目录里与它共用的旁挂文件(歌词、封面)删不删:曲库里还有别的歌用着就不删。
    /// 要看曲库里其余所有的歌(含停用源),只有整库数组答得了;答不了时不删,留着文件。
    static func deletesSidecars(
        for song: Song,
        in library: MusicLibrary,
        timeout: Duration = defaultTimeout
    ) async -> Bool {
        let retained = await read(library, timeout: timeout) {
            // crash-pattern: allow legacy-library-api 删文件前判断共用的旁挂文件,要整库;放掉了先装回来,答不了不删
            library.songs.filter { $0.id != song.id }
        }
        guard let retained else { return false }
        return SourceManager.sidecarDeletionSongIDs(deleting: [song], retaining: retained).contains(song.id)
    }
}
