import SwiftUI
import PrimuseKit

/// 播放速度旁的「升降调」(#332)。iPhone 播放页的速度键和「更多」菜单里各放一个,紧跟在速度后面。
/// 单独成一个视图:播放页那条修饰链已经长到编译器推断不过来,菜单里的分支别再往那个文件里塞。
///
/// 用不了的时候(投放、高保真直通)不置灰:系统菜单里置灰的项点不动,所以第二行写原因,
/// 点了弹说明,高保真直通那条能一键切到音效输出。有声内容与电台保持原声,不给这一项。
struct NowPlayingPitchMenuItem: View {
    @Binding var semitones: Int
    let availability: PlaybackPitchPolicy.Availability
    let onShowUnavailableNotice: () -> Void

    var body: some View {
        switch availability {
        case .available:
            Picker(selection: $semitones) {
                ForEach(PlaybackPitchPolicy.choices, id: \.self) { value in
                    Text(verbatim: PlaybackPitchText.valueLabel(value)).tag(value)
                }
            } label: {
                Label(PlaybackPitchText.menuTitle(semitones), systemImage: PlaybackPitchText.symbol)
            }
            .pickerStyle(.menu)
        case .appleMusic, .casting, .highFidelity:
            Button(action: onShowUnavailableNotice) {
                Label {
                    Text("karaoke_key")
                    if let reason = PlaybackPitchText.shortReason(availability) {
                        Text(verbatim: reason)
                    }
                } icon: {
                    Image(systemName: PlaybackPitchText.symbol)
                }
            }
        case .notOffered:
            EmptyView()
        }
    }
}

/// 升降调的界面文字,iPhone 与 Mac 的播放器菜单、设置共用。
enum PlaybackPitchText {
    static let symbol = "tuningfork"

    /// 「原调」或带正负号的半音数。
    static func valueLabel(_ semitones: Int) -> String {
        PlaybackPitchPolicy.signedLabel(semitones) ?? String(localized: "karaoke_key_original")
    }

    /// 菜单项的标题:原调时只写「升降调」,移了调就带上数,和旁边速度那一项同一写法。
    static func menuTitle(_ semitones: Int) -> String {
        let title = String(localized: "karaoke_key")
        guard let value = PlaybackPitchPolicy.signedLabel(semitones) else { return title }
        return "\(title) \(value)"
    }

    /// 菜单里第二行的短原因。Apple Music 时速度与升降调整项都不出现,用不到。
    static func shortReason(_ availability: PlaybackPitchPolicy.Availability) -> String? {
        switch availability {
        case .highFidelity: String(localized: "eq_menu_high_fidelity_unavailable")
        case .casting: String(localized: "playback_pitch_casting_unavailable")
        case .appleMusic, .available, .notOffered: nil
        }
    }

    /// 点了用不了的那一项弹出的说明。
    static func message(_ availability: PlaybackPitchPolicy.Availability) -> String? {
        switch availability {
        case .highFidelity: String(localized: "playback_pitch_unavailable_high_fidelity")
        case .casting: String(localized: "playback_pitch_unavailable_casting")
        case .appleMusic: String(localized: "playback_pitch_unavailable_apple_music")
        case .available, .notOffered: nil
        }
    }
}
