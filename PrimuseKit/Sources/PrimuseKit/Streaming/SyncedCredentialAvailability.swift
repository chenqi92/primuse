import Foundation

/// 手机侧的密码为什么没落到这台 Apple TV 上。
///
/// TV 上的「缺凭据」其实是三种完全不同的处境:凭据包压根没传过来、传过来了但里面
/// 没有这个源、以及已经有密码(那就不该再让人拿遥控器把密码敲一遍)。分不清就只能
/// 给一句含糊的「请输入密码」,用户不知道该回手机开同步、重新扫码,还是真得手输。
public enum SyncedCredentialAvailability: Equatable, Sendable {
    /// 凭据包里已有该源可用密码 —— 无需在 TV 上手动输入。
    case available
    /// 这台 Apple TV 还没有收到过任何凭据包。
    case bundleMissing
    /// 收到过凭据包,但其中没有这个源的密码。
    case entryMissing
}

public enum SyncedCredentialAvailabilityPolicy {
    /// 只看凭据包 —— TV 本机手输的密码是另一条路径,不在这里判断。
    public static func availability(
        bundle: CredentialBundle?,
        sourceID: String
    ) -> SyncedCredentialAvailability {
        guard let bundle else { return .bundleMissing }
        guard let entry = bundle.entries[sourceID] else { return .entryMissing }
        return (entry.password ?? "").isEmpty ? .entryMissing : .available
    }
}
