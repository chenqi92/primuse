import Foundation

/// An add / edit source form that was not finished. Switching to another app
/// to copy an address or a password can get the suspended process ended by the
/// system, and the form only lived in view state, so coming back meant starting
/// over. The form is written down when the scene leaves the foreground and put
/// back on the next launch. Secrets are not part of it — the app keeps those in
/// the device-only Keychain.
///
/// Enumerations are stored as raw values so a renamed or removed case decodes
/// to the form's default instead of discarding the whole draft.
public struct AddSourceDraft: Codable, Equatable, Sendable {
    public struct AddressRow: Codable, Equatable, Sendable {
        public var address: String
        public var portText: String
        public var transport: String
        public var showsAdvancedOptions: Bool
        public var treatDotlessTokenAsHostname: Bool

        public init(
            address: String,
            portText: String,
            transport: String,
            showsAdvancedOptions: Bool,
            treatDotlessTokenAsHostname: Bool
        ) {
            self.address = address
            self.portText = portText
            self.transport = transport
            self.showsAdvancedOptions = showsAdvancedOptions
            self.treatDotlessTokenAsHostname = treatDotlessTokenAsHostname
        }
    }

    public var sourceType: String
    /// The source being edited; `nil` while adding a new one.
    public var editingSourceID: String?
    public var name: String
    public var host: String
    public var port: String
    public var useSsl: Bool
    public var publicHost: String
    public var publicPort: String
    public var publicUseSsl: Bool
    public var localPathPrefix: String
    public var publicBasePath: String
    public var vendorIdentifier: String
    public var synologyConnectionMode: String
    public var fnMusicConnectionMode: String
    public var username: String
    public var basePath: String
    public var shareName: String
    public var exportPath: String
    public var authType: String
    public var ftpEncryption: String
    /// 旧草稿里没有这一项, 读出来是 nil。
    public var ftpDataConnectionMode: String?
    public var nfsVersion: String
    public var autoConnect: Bool
    public var rememberDevice: Bool
    public var addressRows: [AddressRow]

    public init(
        sourceType: String,
        editingSourceID: String?,
        name: String,
        host: String,
        port: String,
        useSsl: Bool,
        publicHost: String,
        publicPort: String,
        publicUseSsl: Bool,
        localPathPrefix: String,
        publicBasePath: String,
        vendorIdentifier: String,
        synologyConnectionMode: String,
        fnMusicConnectionMode: String,
        username: String,
        basePath: String,
        shareName: String,
        exportPath: String,
        authType: String,
        ftpEncryption: String,
        ftpDataConnectionMode: String? = nil,
        nfsVersion: String,
        autoConnect: Bool,
        rememberDevice: Bool,
        addressRows: [AddressRow]
    ) {
        self.sourceType = sourceType
        self.editingSourceID = editingSourceID
        self.name = name
        self.host = host
        self.port = port
        self.useSsl = useSsl
        self.publicHost = publicHost
        self.publicPort = publicPort
        self.publicUseSsl = publicUseSsl
        self.localPathPrefix = localPathPrefix
        self.publicBasePath = publicBasePath
        self.vendorIdentifier = vendorIdentifier
        self.synologyConnectionMode = synologyConnectionMode
        self.fnMusicConnectionMode = fnMusicConnectionMode
        self.username = username
        self.basePath = basePath
        self.shareName = shareName
        self.exportPath = exportPath
        self.authType = authType
        self.ftpEncryption = ftpEncryption
        self.ftpDataConnectionMode = ftpDataConnectionMode
        self.nfsVersion = nfsVersion
        self.autoConnect = autoConnect
        self.rememberDevice = rememberDevice
        self.addressRows = addressRows
    }
}

/// The secret fields of the same form. Kept apart so they can never end up in
/// the plain draft record.
public struct AddSourceDraftSecrets: Equatable, Sendable {
    public var password: String
    public var sshKey: String
    public var fnConnectAccessCode: String

    public init(password: String = "", sshKey: String = "", fnConnectAccessCode: String = "") {
        self.password = password
        self.sshKey = sshKey
        self.fnConnectAccessCode = fnConnectAccessCode
    }

    public var isEmpty: Bool {
        password.isEmpty && sshKey.isEmpty && fnConnectAccessCode.isEmpty
    }
}

public enum AddSourceDraftPolicy {
    /// A form left longer than this is not "switched out to copy something"
    /// any more; it is dropped instead of reopening on its own.
    public static let restoreWindow: TimeInterval = 30 * 60
    /// A clock that moved backwards must not keep an old draft alive.
    public static let clockSkewAllowance: TimeInterval = 5 * 60
    static let formatVersion = 1

    struct StoredRecord: Codable {
        var version: Int
        var savedAt: Date
        var draft: AddSourceDraft
    }

    /// Worth keeping only when the form differs from what it opened with. A
    /// restored form compares against the blank form it was filled into, so
    /// leaving it alone and switching out again keeps it.
    public static func shouldPersist(
        current: AddSourceDraft,
        currentSecrets: AddSourceDraftSecrets,
        pristine: AddSourceDraft,
        pristineSecrets: AddSourceDraftSecrets
    ) -> Bool {
        current != pristine || currentSecrets != pristineSecrets
    }

    public static func isRestorable(savedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        return age >= -clockSkewAllowance && age <= restoreWindow
    }

    public static func encode(_ draft: AddSourceDraft, savedAt: Date) -> Data? {
        try? JSONEncoder().encode(
            StoredRecord(version: formatVersion, savedAt: savedAt, draft: draft)
        )
    }

    /// The stored draft if it is still worth reopening. A record from another
    /// format version, an unreadable one or a stale one yields `nil`, and the
    /// caller then removes it together with its secrets.
    public static func restorableDraft(from data: Data, now: Date) -> AddSourceDraft? {
        guard let record = try? JSONDecoder().decode(StoredRecord.self, from: data),
              record.version == formatVersion,
              isRestorable(savedAt: record.savedAt, now: now) else {
            return nil
        }
        return record.draft
    }
}
