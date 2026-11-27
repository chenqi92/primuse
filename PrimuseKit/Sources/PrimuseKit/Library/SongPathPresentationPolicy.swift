import Foundation

/// Produces a credential-free path suitable for song details and search UI.
///
/// Source adapters do not all store the same kind of value in `Song.filePath`:
/// some use a relative path, some use a local sandbox URL, and a few use an
/// opaque provider identifier. Keep that storage detail out of the UI and never
/// surface URL authorities, queries or fragments where credentials commonly
/// live.
public enum SongPathPresentationPolicy {
    /// Server catalogs report filesystem paths separately from their playback identifiers.
    public static func displayPath(for song: Song, sourceType: MusicSourceType? = nil) -> String? {
        displayPath(filePath: song.filePath, sourceID: song.sourceID, sourceType: sourceType,
                    serverFilePath: song.serverFilePath)
    }

    public static func providerPath(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        let inspected = (path.removingPercentEncoding ?? path).lowercased()
        guard !path.isEmpty, !path.hasSuffix("/"),
              !inspected.contains("://"), !inspected.hasPrefix("data:"), !inspected.hasPrefix("file:"),
              !inspected.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !credentialMarkers.contains(where: inspected.contains) else { return nil }
        if path.hasPrefix("//") {
            guard let share = path.dropFirst(2).firstIndex(of: "/") else { return nil }
            path = String(path[share...])
        }
        guard path.contains("/") || !(path as NSString).pathExtension.isEmpty else { return nil }
        return path
    }

    public static func needsServerFilePathRefresh(for song: Song, sourceType: MusicSourceType?) -> Bool {
        guard sourceType?.isServerLibrary == true else { return false }
        guard let existing = providerPath(song.serverFilePath) else { return true }
        return !existing.contains("/")
    }

    public static func resolvedServerFilePath(existing rawExisting: String?, fetched rawFetched: String?) -> String? {
        let existing = providerPath(rawExisting)
        let fetched = providerPath(rawFetched)
        guard let fetched else { return existing }
        guard let existing else { return fetched }
        if !existing.contains("/"), fetched.contains("/") {
            return fetched
        }
        return existing
    }

    private static let credentialMarkers = [
        "access_token=", "authorization=", "credential=", "password=", "signature=",
        "token=", "api_key=", "api-key=", "apikey=", "x-amz-credential=", "x-amz-signature=",
    ]

    public static func displayPath(
        filePath rawPath: String,
        sourceID: String,
        sourceType: MusicSourceType? = nil,
        serverFilePath: String? = nil
    ) -> String? {
        guard sourceID != AppleMusicLibraryIdentity.sourceID,
              sourceType != .appleMusic,
              sourceType != .appleMusicLibrary else { return nil }
        if let serverFilePath { return serverFilePath }
        guard sourceType?.isServerLibrary != true, sourceType != .upnp else { return nil }

        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let nfsPath = nfsDisplayPath(trimmed) {
            return normalizedDisplayPath(nfsPath, allowsBareName: true)
        }

        let path: String
        if looksLikeWindowsPath(trimmed) {
            path = trimmed
        } else if (trimmed.contains("://") || trimmed.hasPrefix("file:")),
                  let components = URLComponents(string: trimmed),
                  components.scheme != nil {
            // `path` intentionally excludes the authority, user info, query
            // and fragment. Those values may contain signed-URL credentials.
            path = components.percentEncodedPath.removingPercentEncoding
                ?? components.percentEncodedPath
        } else {
            path = valueBeforeQueryOrFragment(trimmed)
        }

        return normalizedDisplayPath(path)
    }

    /// 不算显示路径就能排除的歌。一两个字的搜索要逐首看路径, 显示路径却要解码、折叠、
    /// 去掉 URL 认证段, 几十万首每首算一遍要好几秒, 留着结果又是上百 MB。
    ///
    /// 返回 `false` 时 `displayPath(filePath:sourceID:sourceType:)` 一定不含 `query`
    /// (同样按 `localizedCaseInsensitiveContains` 比); 返回 `true` 只表示要算出来再看。
    /// 显示路径只从原始路径里删字符, 或者换出 `/`、空格、`~/`、`Documents/`, 再就是解百分号
    /// 编码和 NFS 的 base64 —— 碰到后两种原始路径, 或者查询里带这些分隔字符, 一律不预筛。
    public static func displayPathMayContain(filePath rawPath: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if rawPath.utf8.contains(UInt8(ascii: "%"))
            || rawPath.drop(while: \.isWhitespace).hasPrefix("nfs::") {
            return true
        }
        if query.unicodeScalars.contains(where: { scalar in
            scalar == "/" || scalar == "\\" || scalar == "~" || scalar == "%"
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }) {
            return true
        }
        // 汉字没有大小写, 不会和 ASCII 字符算作相等: 纯 ASCII 的路径(服务器源的
        // `/songs/<id>.flac`)里不可能找到, 连逐字比较都省掉。
        if query.unicodeScalars.contains(where: isHanScalar),
           !rawPath.utf8.contains(where: { $0 >= 0x80 }) {
            return false
        }
        return rawPath.localizedCaseInsensitiveContains(query)
    }

    private static func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private static func normalizedDisplayPath(
        _ rawPath: String,
        allowsBareName: Bool = false
    ) -> String? {
        var path = valueBeforeQueryOrFragment(rawPath)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        path = path.removingPercentEncoding ?? path
        path = path.components(separatedBy: .newlines).joined(separator: " ")
        while path.contains("//") {
            path = path.replacingOccurrences(of: "//", with: "/")
        }

        let folded = path.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        guard !credentialMarkers.contains(where: folded.contains) else { return nil }

        if (path.contains("/Containers/") || path.hasPrefix("/private/var/mobile/")),
           let documentsRange = path.range(of: "/Documents/") {
            path = "Documents/" + path[documentsRange.upperBound...]
        } else if path.hasSuffix("/Documents"),
                  path.contains("/Containers/") {
            path = "Documents"
        } else if let homeRelative = homeRelativePath(path) {
            path = homeRelative
        }

        let hasPathSeparator = path.contains("/")
        let pathExtension = (path as NSString).pathExtension
        guard allowsBareName || path == "Documents" || hasPathSeparator || !pathExtension.isEmpty else {
            // Cloud-drive and media-server adapters often store an opaque item
            // ID here. A bare ID is not meaningful to the user.
            return nil
        }

        return path
    }

    private static func valueBeforeQueryOrFragment(_ value: String) -> String {
        let boundary = [value.firstIndex(of: "?"), value.firstIndex(of: "#")]
            .compactMap { $0 }
            .min()
        return boundary.map { String(value[..<$0]) } ?? value
    }

    private static func looksLikeWindowsPath(_ value: String) -> Bool {
        guard value.count >= 3 else { return false }
        let characters = Array(value.prefix(3))
        return characters[0].isLetter
            && characters[1] == ":"
            && (characters[2] == "\\" || characters[2] == "/")
    }

    private static func homeRelativePath(_ path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 3,
              components[0] == "Users" || components[0] == "home" else { return nil }
        return "~/" + components.dropFirst(2).joined(separator: "/")
    }

    private static func nfsDisplayPath(_ value: String) -> String? {
        guard value.hasPrefix("nfs::") else { return nil }
        let tokens = value.dropFirst("nfs::".count).components(separatedBy: "::")
        guard tokens.count == 2,
              let exportPath = decodeBase64URLToken(tokens[0]),
              let relativePath = decodeBase64URLToken(tokens[1]) else { return nil }

        let exportName = exportPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .last
            .map(String.init)
        let children = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return ([exportName].compactMap { $0 } + children).joined(separator: "/")
    }

    private static func decodeBase64URLToken(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
