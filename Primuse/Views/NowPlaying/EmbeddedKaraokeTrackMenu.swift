import PrimuseKit
import SwiftUI

struct EmbeddedKaraokeTrackMenu: View {
    let playback: EmbeddedKaraokePlayback
    let select: ([Int]?) -> Void
    var companion: Song?
    var switchCompanion: (() -> Void)?

    var body: some View {
        if let inventory = playback.inventory, inventory.audioTracks.count > 1 {
            Menu {
                choice(String(localized: "embedded_audio_default"), checked: playback.requested == nil) { select(nil) }
                ForEach(inventory.audioTracks.filter { $0.stemName == nil }, id: \.ordinal) { track in
                    let title = track.name ?? String(format: String(localized: "embedded_audio_track_number"), track.ordinal + 1)
                    choice(title, checked: playback.requested == [track.ordinal]) { select([track.ordinal]) }
                }
                let stems = inventory.stemTracks
                if !stems.isEmpty {
                    Divider()
                    ForEach(stems, id: \.ordinal) { track in
                        let included = playback.requested?.contains(track.ordinal) ?? true
                        choice(track.stemName ?? "", checked: included) { select(playback.togglingStem(track)) }
                    }
                }
                if let companion, let switchCompanion {
                    Divider()
                    Button(companion.title, action: switchCompanion)
                }
            } label: {
                Label("embedded_audio_tracks", systemImage: playback.isPreparing ? "hourglass" : "slider.horizontal.3")
            }
            .accessibilityIdentifier("karaoke.embeddedAudioTracks")
            if playback.failed {
                Text("playback_error_decode").font(.caption)
            }
        }
    }

    private func choice(_ title: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if checked { Label(title, systemImage: "checkmark") } else { Text(verbatim: title) }
        }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}
