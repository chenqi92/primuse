import Foundation

public struct GoogleDriveSidecarReference: Equatable, Sendable {
    public let sourceFileID: String
    public let suffix: String

    public init(sourceFileID: String, suffix: String) {
        self.sourceFileID = sourceFileID
        self.suffix = suffix
    }
}

public enum GoogleDriveSidecarPolicy {
    public static func reference(from virtualPath: String) -> GoogleDriveSidecarReference? {
        let suffix: String
        if virtualPath.hasSuffix("-cover.jpg") {
            suffix = "-cover.jpg"
        } else if let lyricsExtension = PrimuseConstants.supportedLyricsExtensions.first(where: {
            virtualPath.hasSuffix(".\($0)")
        }) {
            suffix = ".\(lyricsExtension)"
        } else {
            return nil
        }

        let sourceFileID = String(virtualPath.dropLast(suffix.count))
        guard !sourceFileID.isEmpty else { return nil }
        return GoogleDriveSidecarReference(sourceFileID: sourceFileID, suffix: suffix)
    }

    public static func targetName(sourceFileName: String, suffix: String) -> String {
        (sourceFileName as NSString).deletingPathExtension + suffix
    }

    public static func preferredLyricsSuffix(
        sourceFileName: String,
        siblingNames: [String]
    ) -> String {
        let baseName = (sourceFileName as NSString).deletingPathExtension.lowercased()
        let existingNames = Set(siblingNames.map { $0.lowercased() })
        for ext in PrimuseConstants.supportedLyricsExtensions {
            if existingNames.contains("\(baseName).\(ext)") {
                return ".\(ext)"
            }
        }
        return ".lrc"
    }

    public static func mimeType(for suffix: String) -> String? {
        switch suffix.lowercased() {
        case ".lrc":
            return "text/plain; charset=utf-8"
        case ".ttml":
            return "application/ttml+xml"
        case "-cover.jpg":
            return "image/jpeg"
        default:
            return nil
        }
    }
}
