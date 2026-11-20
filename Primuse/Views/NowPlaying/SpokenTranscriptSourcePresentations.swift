import PrimuseKit
import SwiftUI

/// 「重新读取服务器文字稿」要换掉用户自己编辑、导入的那份时的确认(#461)。
/// 播放页的修饰链已经很长,单独成一个修饰。
struct SpokenTranscriptSourcePresentations: ViewModifier {
    @Binding var replaceSong: Song?
    let onConfirmReplace: (Song) -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                Text("transcript_server_replace_title"),
                isPresented: Binding(
                    get: { replaceSong != nil },
                    set: { if !$0 { replaceSong = nil } }
                ),
                presenting: replaceSong
            ) { song in
                Button("transcript_server_replace_action") { onConfirmReplace(song) }
                Button("cancel", role: .cancel) {}
            } message: { _ in
                Text("transcript_server_replace_message")
            }
    }
}
