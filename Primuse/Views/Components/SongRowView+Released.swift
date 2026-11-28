import Foundation
import PrimuseKit

/// 歌曲行在歌曲模型不在内存里时不再逐行读目录(6c 单元 4 U9b)。
///
/// 行的正文(无障碍标签)与内容分级角标每次重画都按 id 再问一遍资料库,拿最新的内容分级。模型在内存里时那是一次
/// 字典查找,照原来;放掉了(或这次启动没装)时 `library.song(id:)` 走「待写登记 → 行缓存 → 目录」,行缓存没有时
/// 就是在主线程上同步读一次目录,而且每一行都登记了对目录全部歌曲修订号的观察(扫描时目录一秒写好几次,眼前的行
/// 跟着一起重画)。这时用行自己的那首:放掉时列表的行都是从目录按页物化的(内容变了列表模型会重新物化那一行),
/// 与按 id 读到的是目录里同一行。
@MainActor
enum SongRowLatest {
    static func song(_ song: Song, library: MusicLibrary) -> Song {
        library.isReady ? (library.song(id: song.id) ?? song) : song
    }
}
