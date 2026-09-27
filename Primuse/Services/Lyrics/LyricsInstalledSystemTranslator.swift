import Foundation
import PrimuseKit
import Translation

/// Apple Translation restricted to language packs already on the device.
/// It never shows the system download or language-confirmation UI, which
/// stays behind the explicit "Translate Lyrics" action.
@available(iOS 26.0, macOS 26.0, *)
struct LyricsInstalledSystemTranslator: LyricsInstalledSystemTranslating {
    func isInstalled(from source: String, to target: String) async -> Bool {
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target)
        )
        return status == .installed
    }

    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String?] {
        let session = TranslationSession(
            installedSource: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)
        )
        var results = [String?](repeating: nil, count: texts.count)
        let requests = texts.enumerated().compactMap { index, text -> TranslationSession.Request? in
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
        guard !requests.isEmpty else { return results }
        for response in try await session.translations(from: requests) {
            guard let identifier = response.clientIdentifier, let index = Int(identifier),
                  results.indices.contains(index) else { continue }
            results[index] = response.targetText
        }
        return results
    }
}

enum LyricsSystemTranslationBridge {
    /// The bridge when this system can build sessions from installed packs.
    static var installedPacks: (any LyricsInstalledSystemTranslating)? {
        if #available(iOS 26.0, macOS 26.0, *) {
            return LyricsInstalledSystemTranslator()
        }
        return nil
    }
}
