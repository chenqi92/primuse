import Foundation

/// Decides whether a primary-node decode pump may keep scheduling audio.
///
/// A committed crossfade rotates the play ID to the incoming track while the
/// outgoing track still has to play the whole ramp, so strict play-ID equality
/// would retire the outgoing pump at the commit boundary and let the fading
/// track run dry once its decoded lookahead is exhausted. The outgoing owner
/// keeps a scheduling grace for exactly as long as the transition is live;
/// completing, failing or cancelling it clears the grace.
public enum CrossfadePumpContinuationPolicy {
    public static func mayContinue<ID: Equatable>(
        playID: ID,
        currentPlayID: ID?,
        isCrossfading: Bool,
        outgoingPlayID: ID?
    ) -> Bool {
        if currentPlayID == playID { return true }
        guard isCrossfading else { return false }
        return outgoingPlayID == playID
    }
}

/// 解码泵手里那块「保留到最后」的缓冲该如何收尾。当前所有者要挂 track-end /
/// gapless 回调; 交叉淡入宽限期内的换出泵只补音频、不挂回调 (那些回调属于
/// 已经轮换走的 playID, 否则会替已退休的曲目推进队列); 其余情况一律丢弃。
public enum PrimaryPumpFinalBufferPolicy {
    public enum Disposition: Equatable, Sendable {
        /// 当前所有者: 正常走带 track-end / gapless 回调的收尾调度。
        case scheduleWithTrackEnd
        /// 交叉淡入换出轨: 按普通缓冲补上, 不挂任何回调。
        case scheduleOutgoingTail
        /// 已被取代且没有宽限资格: 丢弃。
        case drop
    }

    public static func disposition<ID: Equatable>(
        playID: ID,
        currentPlayID: ID?,
        isCrossfading: Bool,
        outgoingPlayID: ID?
    ) -> Disposition {
        if currentPlayID == playID { return .scheduleWithTrackEnd }
        guard CrossfadePumpContinuationPolicy.mayContinue(
            playID: playID,
            currentPlayID: currentPlayID,
            isCrossfading: isCrossfading,
            outgoingPlayID: outgoingPlayID
        ) else { return .drop }
        return .scheduleOutgoingTail
    }
}
