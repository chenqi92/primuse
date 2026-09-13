#if os(tvOS)
import Foundation
import PrimuseKit

/// 把各处抛出的错误统一翻译成电视上看得懂、且指明下一步该做什么的一句话。
///
/// 之前每个界面各自 `catch`,漏掉的分支直接把 `error.localizedDescription` 显示出来,
/// 电视上就会出现「未能完成操作。(PrimuseKit.StreamResolveError 错误 3。)」这种
/// 既读不懂、又占三行把右侧面板撑乱的文案。
enum TVSourceErrorText {
    static func message(error: Error) -> String {
        switch SourceFailureClassifier.kind(for: error) {
        case .needsTwoFactor:
            return PMString("ext.tv.source.error.needs2FA")
        case .authFailed:
            return PMString("ext.tv.test.authFailed")
        case .missingCredential:
            return PMString("ext.tv.test.missingCredential")
        case .certificateRejected:
            return PMString("ext.tv.source.error.certificate")
        case .unreachable:
            return PMString("ext.tv.source.error.unreachable")
        case .serverError(let status):
            guard let status else { return PMString("ext.tv.source.error.unreachable") }
            return PMString("ext.tv.playback.httpError", status)
        case .unsupported:
            return PMString("ext.tv.source.error.unsupported")
        case .cancelled:
            return ""
        case .unknown:
            return error.localizedDescription
        }
    }

    /// 取消不是错误,不该在界面上留一条红字。
    static func isSilent(_ error: Error) -> Bool {
        SourceFailureClassifier.kind(for: error) == .cancelled
    }
}
#endif
