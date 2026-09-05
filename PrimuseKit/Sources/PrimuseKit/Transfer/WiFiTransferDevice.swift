import Foundation
import Network
import Observation
import OSLog

public struct WiFiTransferIdentity: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let platform: String

    public init(id: String, name: String, platform: String) {
        self.id = id
        self.name = Self.boundedName(name, maximumBytes: 120)
        self.platform = platform
    }

    var serviceName: String { Self.boundedName(name, maximumBytes: 63) }

    private static func boundedName(_ name: String, maximumBytes: Int) -> String {
        var result = ""
        var bytes = 0
        for character in name {
            let count = String(character).utf8.count
            guard bytes + count <= maximumBytes else { break }
            result.append(character)
            bytes += count
        }
        return result.isEmpty ? "Primuse" : result
    }

    public static var localID: String {
        let key = "device_transfer_identity_v1"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}

public struct WiFiTransferPeer: Identifiable, Equatable, Sendable {
    public let identity: WiFiTransferIdentity
    public let address: String
    public var id: String { identity.id }
}

public struct WiFiTransferInvitation: Identifiable, Equatable, Sendable {
    public let id: String
    public let sender: String
    public let fileCount: Int
    public let byteCount: Int64
}

public struct WiFiTransferDestination: Codable, Sendable {
    public let identity: WiFiTransferIdentity?
    public let availableBytes: Int64
}

public struct WiFiTransferTicket: Codable, Sendable {
    public let id: String
    public let state: String
}

@MainActor @Observable
public final class WiFiTransferDiscovery {
    public static let serviceType = "_primuse-xfer._tcp"
    public private(set) var peers: [WiFiTransferPeer] = []
    public private(set) var error: String?
    public private(set) var searching = false
    @ObservationIgnored private var browser: NWBrowser?
    private let localID: String

    public init(localID: String = WiFiTransferIdentity.localID) { self.localID = localID }

    nonisolated public static func failureKey(_ error: NWError) -> String {
        switch error {
        case .dns(-65570), .posix(.EACCES), .posix(.EPERM): "discoveryPermission"
        case .dns(-65555): "discoveryBonjour"
        case .posix(.ENETDOWN), .posix(.ENETUNREACH), .posix(.EHOSTUNREACH): "discoveryNetwork"
        default: "discoveryUnavailable"
        }
    }

    public func start() {
        stop()
        error = nil
        peers = []
        let services = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? []
        guard services.contains(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == Self.serviceType }) else {
            error = "discoveryConfiguration"
            return
        }
        searching = true
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            Task { @MainActor in
                guard let self, self.browser === browser else { return }
                switch state {
                case .failed(let failure), .waiting(let failure):
                    self.error = Self.failureKey(failure)
                    self.searching = false
                    self.peers = []
                    Logger(subsystem: "com.welape.yuanyin", category: "DeviceTransfer")
                        .error("Bonjour browse failed: \(String(describing: failure), privacy: .public)")
                case .ready: self.error = nil; self.searching = true
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            Task { @MainActor in
                guard let self, self.browser === browser else { return }
                let peers: [WiFiTransferPeer] = results.compactMap { result in
                    guard case .bonjour(let txt) = result.metadata else { return nil }
                    let values = txt.dictionary
                    guard values["v"] == "1", let id = values["id"], id != self.localID,
                          let address = values["address"], WiFiTransferClient.localURL(address) != nil,
                          let name = values["name"], let platform = values["platform"] else { return nil }
                    return WiFiTransferPeer(identity: .init(id: id, name: name, platform: platform), address: address)
                }.sorted {
                    let order = $0.identity.name.localizedStandardCompare($1.identity.name)
                    if order != .orderedSame { return order == .orderedAscending }
                    if $0.id != $1.id { return $0.id < $1.id }
                    return $0.address < $1.address
                }
                var seen: Set<String> = []
                self.peers = peers.filter { seen.insert($0.id).inserted }
            }
        }
        browser.start(queue: .main)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        searching = false
        error = nil
        peers = []
    }
}

public struct WiFiTransferReceivedFile: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let path: String
    public let size: Int64
    public internal(set) var received: Int64 = 0
    public internal(set) var finished = false
    public internal(set) var error: String?
    public var succeeded: Bool { finished && error == nil }
}

public struct WiFiTransferReceipt: Identifiable, Equatable, Sendable {
    public let id: String
    public let sender: String?
    public let fileCount: Int
    public let byteCount: Int64
    public internal(set) var files: [WiFiTransferReceivedFile] = []
    public internal(set) var finished = false
    public internal(set) var error: String?
    public var completed: Int { files.filter(\.succeeded).count }
    public var receivedBytes: Int64 { files.reduce(0) { $0 + ($1.succeeded ? $1.size : ($1.finished ? 0 : $1.received)) } }
    public var progress: Double { min(1, Double(receivedBytes) / Double(max(1, byteCount))) }
    public var succeeded: Bool { finished && error == nil }
}

@MainActor @Observable
public final class WiFiTransferReceiver {
    public private(set) var address: String?
    public private(set) var code = ""
    public private(set) var running = false
    public private(set) var stopping = false
    public private(set) var browserEnabled = false
    public private(set) var currentFile = ""
    public private(set) var progress: Double = 0
    public private(set) var completed = 0
    public private(set) var invitation: WiFiTransferInvitation?
    public private(set) var sender: String?
    public private(set) var error: String?
    public private(set) var receipts: [WiFiTransferReceipt] = []
    public var hasActiveTransfers: Bool { invitation != nil || receipts.contains { !$0.finished } }
    @ObservationIgnored private var server: WiFiTransferServer?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var stopReason: String?

    public init() {}

    public func start(root: URL, identity: WiFiTransferIdentity, page: String,
                      willChange: @escaping @Sendable () -> Void = {},
                      onChange: @escaping @MainActor (String, Bool) -> Void) {
        guard server == nil else { return }
        error = nil
        stopReason = nil
        completed = 0
        running = true
        stopping = false
        browserEnabled = false
        let (events, continuation) = AsyncStream.makeStream(of: WiFiTransferServer.Event.self)
        let server = WiFiTransferServer(root: root, page: page, identity: identity, browserEnabled: false,
                                        willChange: willChange) { event in
            continuation.yield(event)
            if case .stopped = event { continuation.finish() }
        }
        self.server = server
        // Preserve queue order so a committed file cannot become an interrupted
        // result when stopping immediately after the final upload.
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event, onChange: onChange)
            }
        }
        code = server.accessCode
        server.start()
    }

    func handle(_ event: WiFiTransferServer.Event, onChange: (String, Bool) -> Void = { _, _ in }) {
        switch event {
        case .ready(let url): address = url
        case .transferStarted(let request):
            sender = request.sender
            receipts.insert(.init(id: request.id, sender: request.sender, fileCount: request.fileCount,
                                  byteCount: request.byteCount), at: 0)
            trimHistory()
        case let .uploadStarted(id, path, total, transferID):
            let receiptID = transferID ?? id.uuidString
            if transferID == nil {
                receipts.insert(.init(id: receiptID, sender: nil, fileCount: 1, byteCount: total), at: 0)
                trimHistory()
            }
            if let index = receipts.firstIndex(where: { $0.id == receiptID }) {
                receipts[index].files.append(.init(id: id, path: path, size: total))
            }
        case let .progress(id, path, received, total):
            currentFile = path
            progress = Double(received) / Double(max(1, total))
            updateFile(id) { $0.received = min(received, $0.size) }
        case let .changed(path, deleted):
            if !deleted { completed += 1 }
            onChange(path, deleted)
        case let .uploadEnded(id, failure):
            updateFile(id) {
                $0.finished = true
                $0.error = failure
                if failure == nil { $0.received = $0.size }
            }
            if let index = receipts.firstIndex(where: { $0.id == id.uuidString }) {
                receipts[index].finished = true
                receipts[index].error = failure
            }
            if !receipts.contains(where: { $0.files.contains { !$0.finished && $0.received > 0 } }) {
                currentFile = ""
            }
        case .invitation(let request): invitation = request
        case let .transferEnded(id, failure):
            if invitation?.id == id { invitation = nil }
            if let index = receipts.firstIndex(where: { $0.id == id }) {
                receipts[index].finished = true
                receipts[index].error = failure
                sender = nil
            }
        case .stopped(let failure):
            running = false
            stopping = false
            server = nil
            address = nil
            currentFile = ""
            invitation = nil
            sender = nil
            browserEnabled = false
            error = stopReason ?? failure
            for index in receipts.indices where !receipts[index].finished {
                receipts[index].finished = true
                receipts[index].error = stopReason ?? failure ?? "cancelled"
            }
        }
    }

    private func updateFile(_ id: UUID, update: (inout WiFiTransferReceivedFile) -> Void) {
        for index in receipts.indices {
            if let fileIndex = receipts[index].files.firstIndex(where: { $0.id == id }) {
                update(&receipts[index].files[fileIndex])
                return
            }
        }
    }

    private func trimHistory() {
        // A small receipt history survives stopping and restarting the listener.
        while receipts.count > 10, let index = receipts.lastIndex(where: \.finished) { receipts.remove(at: index) }
    }

    public func allow(_ accepted: Bool) {
        guard let invitation else { return }
        server?.answer(invitationID: invitation.id, accepted: accepted)
        self.invitation = nil
    }

    public func setBrowserEnabled(_ enabled: Bool) {
        guard running, !stopping else { return }
        browserEnabled = enabled
        server?.setBrowserEnabled(enabled)
    }

    public func stop(reason: String? = nil) {
        guard let server, !stopping else { return }
        stopping = true
        stopReason = reason
        server.stop()
    }
}
