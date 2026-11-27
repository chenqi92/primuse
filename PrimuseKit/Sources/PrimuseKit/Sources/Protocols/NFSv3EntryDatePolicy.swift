import Foundation

/// NFSv3 目录项的修改时间,照搬之前 NFSKit 客户端的算法:纳秒先整除到微秒再
/// 换算成秒。修改时间进了歌曲的文件版本(`nfs:<大小>:<微秒>`),算法一变,已扫描
/// 的歌会被当成换了文件。
public enum NFSv3EntryDatePolicy {
    public static func modifiedDate(seconds: Int, nanoseconds: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds)
            + TimeInterval(Int(nanoseconds) / 1000) / 1_000_000)
    }
}
