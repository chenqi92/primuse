import Foundation

/// Google 要求能读取整个 Google Drive 的应用在 2026-11-20 前完成付费的第三方 CASA 评估,
/// Primuse 不做这项评估,改用只能访问用户所选文件的 drive.file 权限。三端的提醒都按这一天
/// 分成「将于」与「已于」两种说法。
public enum GoogleDriveAccessChangePolicy {
    public enum Phase: Equatable, Sendable {
        case upcoming
        case inEffect
    }

    /// 只记公历年月日:泰语、日语等地区的默认日历不是公历,直接拿 `Calendar.current`
    /// 去解释 2026 会落到另一个纪年。
    public static let effectiveDay = DateComponents(year: 2026, month: 11, day: 20)

    /// 生效时刻取用户所在时区这一天的零点,和界面上显示的日期对得上。
    public static func effectiveDate(in timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: effectiveDay) ?? Date.distantFuture
    }

    public static func phase(now: Date = Date(), timeZone: TimeZone = .current) -> Phase {
        now < effectiveDate(in: timeZone) ? .upcoming : .inEffect
    }
}

/// Google Drive 的 `drive.file` 权限和 Google 文件选择器(授权页上的 `trigger_onepick`)的规则。
///
/// 访问方式是音乐源上存下来的事实(`MusicSource.googleDriveAccessMode`),授权时写入,从那里读;
/// 令牌附加字段里的授权范围只用来发现「令牌和源对不上」的半迁移状态,不拿来猜模式。
public enum GoogleDrivePickerPolicy {
    public static let fileScope = "https://www.googleapis.com/auth/drive.file"
    public static let legacyFullDriveScope = "https://www.googleapis.com/auth/drive"
    public static let legacyReadOnlyDriveScope = "https://www.googleapis.com/auth/drive.readonly"

    public static let oauthScopeExtraKey = "oauth_scope"
    public static let pickedFileIDsExtraKey = "picked_file_ids"
    /// 授权时从 Drive `about.user.emailAddress` 读到的账号邮箱,只用来判断重新授权是不是换了账号。
    public static let accountEmailExtraKey = "account_email"
    public static let authorizedFilesRootPath = "/"

    /// Lists every non-trashed non-folder file the app is authorized to access
    /// under `drive.file` (files picked in Google Picker or created by Primuse).
    public static let authorizedFilesQuery =
        "trashed = false and mimeType != 'application/vnd.google-apps.folder'"

    public enum AccessMode: String, Codable, Sendable, Equatable {
        /// Per-file `drive.file` authorization obtained via Google Picker.
        case pickedFiles
        /// Pre-migration account-wide `drive` / `drive.readonly` token still held
        /// by an existing source that has not yet re-authorized.
        case legacyFullDrive
    }

    /// 没存访问方式的源是这一版之前授权的整盘源;这一版起每次授权都会写入访问方式。
    public static func effectiveMode(stored: AccessMode?) -> AccessMode {
        stored ?? .legacyFullDrive
    }

    /// 合并别的设备传来的源:对方没带访问方式(旧版本 App 存回去时会丢掉这个字段)不等于
    /// 「整盘」,留着本机知道的那个。访问方式只会由一次授权改写成另一个值,从不改回「没有」。
    public static func mergedStoredAccessMode(local: AccessMode?, remote: AccessMode?) -> AccessMode? {
        remote ?? local
    }

    /// 令牌附加字段里记下的授权范围。
    public enum GrantedScope: Sendable, Equatable {
        /// 只有 `drive.file`(可能另带非 Drive 的范围)。
        case filesOnly
        /// `drive` 或 `drive.readonly`:能读整个云端硬盘。
        case fullDrive
        /// 没记范围:这一版之前的令牌,或被旧版 App 刷新时丢了附加字段。
        case unstated
    }

    public static func grantedScope(_ rawScope: String?) -> GrantedScope {
        let scopes = scopeTokens(from: rawScope)
        if scopes.contains(legacyFullDriveScope) || scopes.contains(legacyReadOnlyDriveScope) {
            return .fullDrive
        }
        return scopes.contains(fileScope) ? .filesOnly : .unstated
    }

    public static func grantedScope(forTokenExtra extra: [String: String]?) -> GrantedScope {
        grantedScope(extra?[oauthScopeExtraKey])
    }

    /// 钥匙串里令牌附加字段的读取结果。读不出来和「没有」是两回事。
    public enum TokenExtraRead: Sendable, Equatable {
        case found([String: String]?)
        case unreadable
    }

    public enum ListingDecision: Sendable, Equatable {
        /// 旧的整盘令牌,照旧按文件夹列。
        case legacyFolders
        /// 已选文件:根目录平铺列出 App 能看到的文件。
        case pickedFiles
        /// 令牌和源的配置对不上(半迁移):不列,让用户重新选择文件。
        case requiresReselection
        /// 钥匙串此刻读不出令牌:答不了,不按任何一种模式列。
        case cannotAnswer
    }

    /// 每次列目录、对账变更之前的判断。`path` 是要列的目录(nil 表示与目录无关的调用)。
    ///
    /// 两种半迁移状态都不能返回列表:整盘源拿着 `drive.file` 令牌时按文件夹只列得到被选中的
    /// 那几个文件,已选文件源的配置里还留着文件夹时同样只列得到一部分,列不到的歌都会被当成
    /// 已经删掉。
    public static func listingDecision(
        storedMode: AccessMode?,
        tokenExtra: TokenExtraRead,
        path: String?
    ) -> ListingDecision {
        guard case .found(let extra) = tokenExtra else { return .cannotAnswer }
        switch effectiveMode(stored: storedMode) {
        case .legacyFullDrive:
            return grantedScope(forTokenExtra: extra) == .filesOnly ? .requiresReselection : .legacyFolders
        case .pickedFiles:
            // 令牌是哪种范围都按已选文件列:旧版 App 重新授权或刷新写下的令牌不记范围,读不出来;
            // 就算拿到能看整盘的令牌,平铺列出来也只会多出歌,不会让哪首歌被当成删掉。
            if let path, !isAuthorizedFilesRoot(path) { return .requiresReselection }
            return .pickedFiles
        }
    }

    public static func scopeTokens(from rawScope: String?) -> Set<String> {
        guard let rawScope else { return [] }
        return Set(
            rawScope
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter { !$0.isEmpty }
        )
    }

    /// 选择器回调里带回来的文件。
    public enum CallbackSelection: Sendable, Equatable {
        /// 没带 `picked_file_ids`,或者带了但是空的:什么都没选。
        case nothingChosen
        case chosen([String])
    }

    public static func callbackSelection(from callbackURL: URL) -> CallbackSelection {
        let ids = parsePickedFileIDs(from: callbackURL)
        return ids.isEmpty ? .nothingChosen : .chosen(ids)
    }

    public static func parsePickedFileIDs(from callbackURL: URL) -> [String] {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?
                .first(where: { $0.name == pickedFileIDsExtraKey })?
                .value else {
            return []
        }
        return parsePickedFileIDs(from: raw)
    }

    public static func parsePickedFileIDs(from raw: String?) -> [String] {
        guard let raw else { return [] }
        var seen: Set<String> = []
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func encodePickedFileIDs(_ ids: [String]) -> String? {
        var seen: Set<String> = []
        let normalized = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return normalized.isEmpty ? nil : normalized.joined(separator: ",")
    }

    public static func mergingPickedFileIDs(
        existing: [String],
        added: [String],
        replacingExisting: Bool = false
    ) -> [String] {
        let combined = replacingExisting ? added : (existing + added)
        var seen: Set<String> = []
        return combined
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 合并令牌附加字段。同一账号的已选文件累加,换账号清空。
    ///
    /// `carriesExistingScope` 为 false 时不沿用旧令牌记下的授权范围:一枚新令牌没说自己的范围
    /// (例如旧版手机代登录传来的),旧范围描述的是被替换掉的那枚令牌。
    public static func mergedTokenExtra(
        existing: [String: String]?,
        incoming: [String: String]?,
        grantedScope: String? = nil,
        replacingAccount: Bool = false,
        carriesExistingScope: Bool = true
    ) -> [String: String]? {
        var result: [String: String] = replacingAccount ? [:] : (existing ?? [:])
        if !carriesExistingScope { result.removeValue(forKey: oauthScopeExtraKey) }
        if let incoming {
            for (key, value) in incoming where key != pickedFileIDsExtraKey && key != oauthScopeExtraKey {
                result[key] = value
            }
        }

        let resolvedScope = [
            grantedScope,
            incoming?[oauthScopeExtraKey],
            replacingAccount || !carriesExistingScope ? nil : existing?[oauthScopeExtraKey],
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
        if let resolvedScope {
            result[oauthScopeExtraKey] = resolvedScope
        }

        let existingIDs = replacingAccount ? [] : parsePickedFileIDs(from: existing?[pickedFileIDsExtraKey])
        let incomingIDs = parsePickedFileIDs(from: incoming?[pickedFileIDsExtraKey])
        let mergedIDs = mergingPickedFileIDs(
            existing: existingIDs,
            added: incomingIDs,
            replacingExisting: replacingAccount
        )
        if let encoded = encodePickedFileIDs(mergedIDs) {
            result[pickedFileIDsExtraKey] = encoded
        } else {
            result.removeValue(forKey: pickedFileIDsExtraKey)
        }

        return result.isEmpty ? nil : result
    }

    /// 已选文件模式唯一的根。与 `SourceDirectorySelectionPolicy.isRootPath` 同一个「根」,
    /// 另外认 Drive API 的 `root` 别名;提醒卡片、列目录与扫描都用这一个判断。
    public static func isAuthorizedFilesRoot(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "root" || SourceDirectorySelectionPolicy.isRootPath(trimmed)
    }

    /// 源卡片上「Google Drive 接入调整」的提醒:按访问方式给,只给还在用整盘授权、而且已经
    /// 设好扫描范围的源。还没授权过的新源下一次授权就是选择文件,不用提醒。
    public static func showsLegacyAccessReminder(storedMode: AccessMode?, configuredRoots: [String]) -> Bool {
        effectiveMode(stored: storedMode) == .legacyFullDrive && !configuredRoots.isEmpty
    }

    // MARK: Account identity

    /// 两个邮箱都有、而且不区分大小写不相同时才算「能证明换了账号」。
    public static func accountDiffers(storedEmail: String?, incomingEmail: String?) -> Bool {
        guard let stored = normalizedEmail(storedEmail),
              let incoming = normalizedEmail(incomingEmail) else { return false }
        return stored != incoming
    }

    public enum AccountLink: Sendable, Equatable {
        /// 留着源原来的 `cloudAccountID`。
        case keepExisting(String)
        /// 用这次授权读到的账号标识。
        case adoptIncoming
    }

    /// 重新授权时源的账号标识。墓碑、本机排除、文件夹歌单都按 `cloudAccountID` 绑定,
    /// 同一账号换一种标识(旧源存的是 OIDC `sub`,已选文件模式读的是 `permissionId`)
    /// 会让它们全部失效。所以已有标识的源只在用户走「换账号」或者邮箱能证明不是同一账号时
    /// 才换;没存邮箱就留着。新源用新标识。
    public static func accountLink(
        existingAccountID: String?,
        storedEmail: String?,
        incomingEmail: String?,
        isExplicitAccountSwitch: Bool
    ) -> AccountLink {
        guard let existing = existingAccountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !existing.isEmpty else { return .adoptIncoming }
        if isExplicitAccountSwitch { return .adoptIncoming }
        if accountDiffers(storedEmail: storedEmail, incomingEmail: incomingEmail) { return .adoptIncoming }
        return .keepExisting(existing)
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    // MARK: Apple TV sign-in through the phone

    public struct ProxyLoginAuthorization: Sendable, Equatable {
        public var tokenExtra: [String: String]?
        public var accessMode: AccessMode
    }

    /// 电视收到手机代登录的授权。旧版手机传来的数据没有 `scope` 字段,拿到的是整盘令牌,
    /// 所以没写范围就是整盘,不能默认成 `drive.file`。
    public static func proxyLoginAuthorization(
        existingExtra: [String: String]?,
        payloadScope: String?,
        payloadPickedFileIDs: [String]?
    ) -> ProxyLoginAuthorization {
        let scope = payloadScope?.trimmingCharacters(in: .whitespacesAndNewlines)
        var incoming: [String: String] = [:]
        if let encoded = encodePickedFileIDs(payloadPickedFileIDs ?? []) {
            incoming[pickedFileIDsExtraKey] = encoded
        }
        let stated = scope?.isEmpty == false ? scope : nil
        let extra = mergedTokenExtra(
            existing: existingExtra,
            incoming: incoming,
            grantedScope: stated,
            carriesExistingScope: false
        )
        let mode: AccessMode = grantedScope(stated) == .filesOnly ? .pickedFiles : .legacyFullDrive
        return ProxyLoginAuthorization(tokenExtra: extra, accessMode: mode)
    }
}

/// Google Drive 已选文件源在一次完整列表里少了的歌怎么处理。
///
/// 「列表里没有」在 `drive.file` 下证明不了文件不在了:用户只选了一部分、旧版设备换过令牌、
/// Google 收回了授权,读起来都一样。所以选择文件之后的那一轮(扫描范围变了、没有上一份状态,
/// 或者源上还挂着这类确认)一首都不自己删:少了的歌暂存成待确认,用户确认以后下一次完整扫描
/// 只移除这些、而且仍然不在列表里的歌;选保留就一直留着,不再提示,直到又有新的歌不在列表里。
public enum GoogleDrivePickedFilesRemovalPolicy {
    public static let holdKinds: Set<SourceSyncReconciliation.Kind> = [
        .pickedFilesRemovalConfirmation,
        .pickedFilesRemovalKept,
        .pickedFilesRemovalConfirmed,
    ]

    /// 这一轮完整扫描是否走待确认:扫描范围和上一份状态对不上(选择文件会换令牌、改源,
    /// 两样都会让扫描范围变),或者源上已经挂着这类确认。
    public static func holdsRemovals(
        scopeMatchesPreviousState: Bool,
        storedKind: SourceSyncReconciliation.Kind?
    ) -> Bool {
        !scopeMatchesPreviousState || storedKind.map { holdKinds.contains($0) } == true
    }

    /// 三个集合都是一次扫描提交里的临时结果,上界是这个源这一轮不在列表里的歌数(和
    /// `ServerCatalogDeletionConfirmationPolicy.Plan` 一样),不常驻。
    public struct Outcome: Sendable, Equatable {
        /// 这一轮可以移除的歌:只有用户确认过、而且仍然不在列表里的。
        // crash-pattern: allow song-id-collection-property 扫描提交里的临时结果,至多这个源这一轮缺席的歌数
        public var removedSongIDs: Set<String>
        /// 不在列表里但照旧留着的歌。
        // crash-pattern: allow song-id-collection-property 扫描提交里的临时结果,至多这个源这一轮缺席的歌数
        public var retainedMissingSongIDs: Set<String>
        /// 存回同步状态的确认;nil 表示没有要确认的了。
        public var reconciliation: SourceSyncReconciliation.Kind?
        // crash-pattern: allow song-id-collection-property 扫描提交里的临时结果,至多这个源这一轮缺席的歌数
        public var unresolvedSongIDs: Set<String>

        public init(
            removedSongIDs: Set<String> = [],
            retainedMissingSongIDs: Set<String> = [],
            reconciliation: SourceSyncReconciliation.Kind? = nil,
            unresolvedSongIDs: Set<String> = []
        ) {
            self.removedSongIDs = removedSongIDs
            self.retainedMissingSongIDs = retainedMissingSongIDs
            self.reconciliation = reconciliation
            self.unresolvedSongIDs = unresolvedSongIDs
        }

        /// 源卡片上「要不要移除」的提示要显示的首数;不用提示时为 nil。
        public var promptCount: Int? {
            reconciliation == .pickedFilesRemovalConfirmation && !unresolvedSongIDs.isEmpty
                ? unresolvedSongIDs.count
                : nil
        }
    }

    /// - Parameters:
    ///   - missingSongIDs: 开始时属于这个源、这一轮完整列表里没有的歌。上界是这个源的歌数。
    ///   - storedKind: 源上挂着的确认。
    ///   - storedSongIDs: 那份确认里的歌。
    public static func outcome(
        missingSongIDs: Set<String>,
        storedKind: SourceSyncReconciliation.Kind?,
        storedSongIDs: Set<String>
    ) -> Outcome {
        switch storedKind {
        case .pickedFilesRemovalConfirmed:
            let removed = missingSongIDs.intersection(storedSongIDs)
            let rest = missingSongIDs.subtracting(storedSongIDs)
            return Outcome(
                removedSongIDs: removed,
                retainedMissingSongIDs: rest,
                reconciliation: rest.isEmpty ? nil : .pickedFilesRemovalConfirmation,
                unresolvedSongIDs: rest
            )
        case .pickedFilesRemovalKept:
            guard !missingSongIDs.isEmpty else { return Outcome() }
            return Outcome(
                retainedMissingSongIDs: missingSongIDs,
                reconciliation: missingSongIDs.isSubset(of: storedSongIDs)
                    ? .pickedFilesRemovalKept
                    : .pickedFilesRemovalConfirmation,
                unresolvedSongIDs: missingSongIDs
            )
        default:
            guard !missingSongIDs.isEmpty else { return Outcome() }
            return Outcome(
                retainedMissingSongIDs: missingSongIDs,
                reconciliation: .pickedFilesRemovalConfirmation,
                unresolvedSongIDs: missingSongIDs
            )
        }
    }

    /// 电视上没有选择器,用户没法在那里确认:已选文件源的完整扫描在电视上一首都不剪。
    public static func tvScanPrunesMissingSongs(source: MusicSource) -> Bool {
        !source.usesGoogleDrivePickedFiles
    }
}
