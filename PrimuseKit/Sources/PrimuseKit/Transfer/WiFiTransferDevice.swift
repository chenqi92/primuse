import Foundation
import Network
import Observation

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

    public func start() {
        stop()
        error = nil
        peers = []
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
                case .failed, .waiting: self.error = "network"; self.searching = false
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
    }
}

@MainActor @Observable
public final class WiFiTransferReceiver {
    public private(set) var address: String?
    public private(set) var code = ""
    public private(set) var running = false
    public private(set) var browserEnabled = false
    public private(set) var currentFile = ""
    public private(set) var progress: Double = 0
    public private(set) var completed = 0
    public private(set) var invitation: WiFiTransferInvitation?
    public private(set) var sender: String?
    public private(set) var error: String?
    @ObservationIgnored private var server: WiFiTransferServer?
    @ObservationIgnored private var generation = UUID()

    public init() {}

    public func start(root: URL, identity: WiFiTransferIdentity, page: String,
                      willChange: @escaping @Sendable () -> Void = {},
                      onChange: @escaping @MainActor (String, Bool) -> Void) {
        guard server == nil else { return }
        let generation = UUID()
        self.generation = generation
        error = nil
        completed = 0
        running = true
        browserEnabled = false
        let server = WiFiTransferServer(root: root, page: page, identity: identity, browserEnabled: false,
                                        willChange: willChange) { [weak self] event in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                switch event {
                case .ready(let url): self.address = url
                case let .progress(path, received, total):
                    self.currentFile = path
                    self.progress = Double(received) / Double(max(1, total))
                case let .changed(path, deleted):
                    if !deleted { self.completed += 1 }
                    onChange(path, deleted)
                case .uploadEnded: self.currentFile = ""
                case .invitation(let request): self.invitation = request
                case .transferEnded: self.invitation = nil; self.sender = nil
                case .stopped(let error):
                    self.running = false
                    self.server = nil
                    self.address = nil
                    self.currentFile = ""
                    self.invitation = nil
                    self.sender = nil
                    self.browserEnabled = false
                    self.error = error
                }
            }
        }
        self.server = server
        code = server.accessCode
        server.start()
    }

    public func allow(_ accepted: Bool) {
        guard let invitation else { return }
        if accepted { sender = invitation.sender }
        server?.answer(invitationID: invitation.id, accepted: accepted)
        self.invitation = nil
    }

    public func setBrowserEnabled(_ enabled: Bool) {
        browserEnabled = enabled
        server?.setBrowserEnabled(enabled)
    }

    public func stop() {
        server?.stop()
        server = nil
        generation = UUID()
        address = nil
        running = false
        currentFile = ""
        invitation = nil
        sender = nil
        browserEnabled = false
    }
}
