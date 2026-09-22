#if os(iOS) || os(macOS)
import MusicKit
import SwiftUI

/// 把系统的 Apple Music 订阅页接进来。
///
/// 之前没订阅的用户点一首目录曲，只会收到一条「需要订阅 Apple Music」的横幅，
/// 到此为止 —— 想订阅还得自己退出去开 Apple Music App 找入口。`musicSubscriptionOffer`
/// 是 Apple 给的官方出口，直接在本 App 里走完订阅流程。
///
/// 只在 `MusicSubscription.canBecomeSubscriber` 为真时才会被触发（见
/// `AppleMusicService.requestSubscriptionOffer`）：地区不支持的用户弹出来也订不了，
/// 那种情况仍然只给说明文字。
extension View {
    func appleMusicSubscriptionOffer() -> some View {
        modifier(AppleMusicSubscriptionOfferModifier())
    }
}

private struct AppleMusicSubscriptionOfferModifier: ViewModifier {
    @Environment(AppleMusicService.self) private var appleMusic

    func body(content: Content) -> some View {
        content.musicSubscriptionOffer(
            isPresented: Binding(
                get: { appleMusic.subscriptionOfferRequested },
                set: { appleMusic.subscriptionOfferRequested = $0 }
            ),
            options: offerOptions
        )
    }

    private var offerOptions: MusicSubscriptionOffer.Options {
        var options = MusicSubscriptionOffer.Options()
        // `.playMusic` 让订阅页的文案对准「订阅后就能播这首」，而不是泛泛的推广。
        options.messageIdentifier = .playMusic
        if let rawID = appleMusic.subscriptionOfferItemID {
            options.itemID = MusicItemID(rawValue: rawID)
        }
        return options
    }
}
#endif
