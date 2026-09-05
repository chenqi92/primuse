import Foundation
import Network
import Darwin

/// Listener state and file handles are confined to `queue`; events contain values only.
public final class WiFiTransferServer: @unchecked Sendable {
    public enum Event: Sendable {
        case ready(url: String)
        case progress(path: String, received: Int64, total: Int64)
        case changed(path: String, deleted: Bool)
        case uploadEnded
        case invitation(WiFiTransferInvitation)
        case transferEnded
        case stopped(error: String?)
    }

    public let accessCode: String
    private let root: URL
    private let page: Data
    private let host: String?
    private let identity: WiFiTransferIdentity?
    private var browserEnabled: Bool
    private let event: @Sendable (Event) -> Void
    private let willChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.welape.primuse.wifi-transfer", qos: .utility)
    private var listener: NWListener?
    private var files: WiFiTransferFiles?
    private var connections: [UUID: Client] = [:]
    private var authorization: WiFiTransferAuthorization
    private var authority = ""
    private struct NativeTransfer {
        let invitation: WiFiTransferInvitation
        var state = "waiting"
        var completed = 0
        var received: Int64 = 0
        var lastActivity = Date()
    }
    private var nativeTransfer: NativeTransfer?

    public init(root: URL, page: String, identity: WiFiTransferIdentity? = nil,
                browserEnabled: Bool = true, willChange: @escaping @Sendable () -> Void = {},
                event: @escaping @Sendable (Event) -> Void) {
        self.root = root
        self.page = Data(page.utf8)
        self.host = Self.localAddress()
        self.identity = identity
        self.browserEnabled = browserEnabled
        self.event = event
        self.willChange = willChange
        accessCode = String(format: "%06d", Int.random(in: 0...999999))
        authorization = WiFiTransferAuthorization(code: accessCode)
    }

    init(root: URL, page: String, testingHost: String, event: @escaping @Sendable (Event) -> Void) {
        self.root = root
        self.page = Data(page.utf8)
        host = testingHost
        identity = nil
        browserEnabled = true
        self.event = event
        willChange = {}
        accessCode = String(format: "%06d", Int.random(in: 0...999999))
        authorization = WiFiTransferAuthorization(code: accessCode)
    }

    public func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            guard let host else { event(.stopped(error: "network")); return }
            do {
                files = try WiFiTransferFiles(root: root)
                let parameters = NWParameters.tcp
                parameters.prohibitedInterfaceTypes = [.cellular]
                parameters.includePeerToPeer = false
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else { return }
                        self.authority = "\(host):\(port.rawValue)"
                        if let identity = self.identity {
                            listener.service = NWListener.Service(
                                name: identity.serviceName, type: "_primuse-xfer._tcp", domain: nil,
                                txtRecord: NWTXTRecord(["id": identity.id, "name": identity.name,
                                                        "platform": identity.platform, "v": "1",
                                                        "address": "http://\(self.authority)"])
                            )
                        }
                        self.event(.ready(url: "http://\(self.authority)"))
                    case .waiting, .failed:
                        self.stopOnQueue(error: "network")
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
            } catch {
                stopOnQueue(error: "unavailable")
            }
        }
    }

    public func stop() { queue.async { [self] in stopOnQueue(error: nil) } }

    public func setBrowserEnabled(_ enabled: Bool) {
        queue.async { [self] in
            browserEnabled = enabled
            if !enabled {
                for client in Array(connections.values) where client.upload != nil
                    && client.request?.headers["x-primuse-transfer"] == nil { finish(client.id) }
            }
        }
    }

    public func answer(invitationID: String, accepted: Bool) {
        queue.async { [self] in
            guard nativeTransfer?.invitation.id == invitationID else { return }
            nativeTransfer?.state = accepted ? "accepted" : "rejected"
            nativeTransfer?.lastActivity = Date()
            if !accepted { event(.transferEnded) }
        }
    }

    private func stopOnQueue(error: String?) {
        listener?.cancel()
        listener = nil
        for client in connections.values { client.connection.cancel() }
        connections.removeAll()
        files = nil
        nativeTransfer = nil
        event(.stopped(error: error))
    }

    private final class Client {
        let id = UUID()
        let connection: NWConnection
        var header = Data()
        var upload: WiFiTransferFiles.Upload?
        var request: WiFiTransferRequest?
        var lastActivity = Date()
        var lastProgress = Date.distantPast
        var responded = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 4 else { connection.cancel(); return }
        let client = Client(connection)
        connections[client.id] = client
        let id = client.id
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish(id)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(client.id)
        checkTimeout(client.id)
    }

    private func checkTimeout(_ id: UUID) {
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, let client = self.connections[id] else { return }
            if Date().timeIntervalSince(client.lastActivity) >= 30 { self.finish(id) }
            else { self.checkTimeout(id) }
        }
    }

    private func finish(_ id: UUID) {
        guard let client = connections.removeValue(forKey: id) else { return }
        if client.upload != nil { event(.uploadEnded) }
        client.connection.cancel()
    }

    private func receive(_ id: UUID) {
        guard let client = connections[id], !client.responded else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, let client = self.connections[id], !client.responded else { return }
            do {
                if let data, !data.isEmpty {
                    client.lastActivity = Date()
                    if client.request == nil {
                        client.header.append(data)
                        if let range = client.header.range(of: Data("\r\n\r\n".utf8)) {
                            let request = try WiFiTransferRequest(client.header.subdata(in: 0..<range.lowerBound))
                            let body = client.header.subdata(in: range.upperBound..<client.header.count)
                            client.header.removeAll()
                            client.request = request
                            try self.route(request, client: client)
                            if !client.responded { try self.append(body, client: client) }
                        } else if client.header.count > 16 * 1024 {
                            throw WiFiTransferError.invalidRequest
                        }
                    } else { try self.append(data, client: client) }
                }
                if !client.responded {
                    if complete || error != nil { self.finish(id) }
                    else { self.receive(id) }
                }
            } catch {
                let failure = error as? WiFiTransferError ?? .unavailable
                self.respond(client, status: failure.status, json: ["error": failure.rawValue])
            }
        }
    }

    private func route(_ request: WiFiTransferRequest, client: Client) throws {
        guard request.headers["host"] == authority else { throw WiFiTransferError.invalidRequest }
        if let origin = request.headers["origin"], origin != "http://" + authority {
            throw WiFiTransferError.unauthorized
        }
        if request.headers["sec-fetch-site"] == "cross-site" { throw WiFiTransferError.unauthorized }
        if request.method == "GET", request.route == "/", request.contentLength == 0 {
            guard browserEnabled else { throw WiFiTransferError.browserDisabled }
            respond(client, status: 200, body: page, type: "text/html; charset=utf-8")
            return
        }
        guard let files else { throw WiFiTransferError.unavailable }
        try authorization.validate(request.headers["x-primuse-code"])
        if request.route == "/api/info", request.method == "GET", request.contentLength == 0 {
            let free = (try? FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            respond(client, status: 200, body: try JSONEncoder().encode(WiFiTransferDestination(identity: identity, availableBytes: free)))
            return
        }
        if request.route == "/api/transfer", request.contentLength == 0 {
            try routeTransfer(request, client: client)
            return
        }
        guard request.route == "/api/files" || request.route == "/api/folders" else {
            throw WiFiTransferError.notFound
        }
        if let ticket = request.headers["x-primuse-transfer"] {
            guard request.method == "PUT", request.route == "/api/files",
                  let transfer = nativeTransfer, transfer.invitation.id == ticket,
                  transfer.state == "accepted" else { throw WiFiTransferError.unauthorized }
            guard transfer.completed < transfer.invitation.fileCount,
                  request.contentLength <= transfer.invitation.byteCount - transfer.received else {
                throw WiFiTransferError.invalidRequest
            }
            nativeTransfer?.lastActivity = Date()
        } else if !browserEnabled { throw WiFiTransferError.browserDisabled }
        switch (request.method, request.route) {
        case ("PUT", "/api/files"):
            // Serial uploads bound disk reservations and preserve audio/sidecar ordering.
            guard !connections.values.contains(where: { $0.upload != nil }) else { throw WiFiTransferError.conflict }
            client.upload = try files.beginUpload(path: request.path, size: request.contentLength)
        case ("GET", "/api/files") where request.contentLength == 0:
            let body = try JSONEncoder().encode(files.list(request.path))
            respond(client, status: 200, body: body)
        case ("DELETE", "/api/files") where request.contentLength == 0:
            guard !connections.values.contains(where: { $0.upload != nil }) else { throw WiFiTransferError.conflict }
            willChange()
            try files.delete(request.path)
            event(.changed(path: request.path, deleted: true))
            respond(client, status: 200, json: ["ok": true])
        case ("POST", "/api/folders") where request.contentLength == 0:
            try files.makeDirectory(request.path)
            respond(client, status: 200, json: ["ok": true])
        default: throw WiFiTransferError.invalidRequest
        }
    }

    private func append(_ data: Data, client: Client) throws {
        guard let upload = client.upload, let files else { throw WiFiTransferError.invalidRequest }
        try upload.append(data)
        if Date().timeIntervalSince(client.lastProgress) >= 0.2 || upload.receivedSize == upload.expectedSize {
            event(.progress(path: upload.path, received: upload.receivedSize, total: upload.expectedSize))
            client.lastProgress = Date()
        }
        if upload.receivedSize == upload.expectedSize {
            willChange()
            try files.commit(upload)
            if client.request?.headers["x-primuse-transfer"] != nil {
                nativeTransfer?.completed += 1
                nativeTransfer?.received += upload.receivedSize
                nativeTransfer?.lastActivity = Date()
            }
            event(.changed(path: upload.path, deleted: false))
            client.upload = nil
            event(.uploadEnded)
            respond(client, status: 201, json: ["ok": true])
        }
    }

    private func routeTransfer(_ request: WiFiTransferRequest, client: Client) throws {
        switch request.method {
        case "POST":
            guard nativeTransfer == nil || nativeTransfer?.state == "rejected" else { throw WiFiTransferError.conflict }
            guard let countText = request.headers["x-primuse-file-count"], let count = Int(countText), (1...10000).contains(count),
                  let bytesText = request.headers["x-primuse-byte-count"], let bytes = Int64(bytesText), bytes > 0,
                  let sender = request.headers["x-primuse-sender"]?.removingPercentEncoding,
                  !sender.isEmpty, sender.count <= 100 else { throw WiFiTransferError.invalidRequest }
            let invitation = WiFiTransferInvitation(id: UUID().uuidString, sender: sender, fileCount: count, byteCount: bytes)
            nativeTransfer = NativeTransfer(invitation: invitation)
            event(.invitation(invitation))
            checkTransferTimeout(invitation.id)
        case "GET":
            guard nativeTransfer?.invitation.id == request.path else { throw WiFiTransferError.notFound }
        case "DELETE":
            guard nativeTransfer?.invitation.id == request.path else { throw WiFiTransferError.notFound }
            for active in Array(connections.values) where active.request?.headers["x-primuse-transfer"] == request.path { finish(active.id) }
            nativeTransfer = nil
            event(.transferEnded)
            respond(client, status: 200, json: ["ok": true])
            return
        default: throw WiFiTransferError.invalidRequest
        }
        guard let transfer = nativeTransfer else { throw WiFiTransferError.notFound }
        respond(client, status: 200, body: try JSONEncoder().encode(WiFiTransferTicket(id: transfer.invitation.id, state: transfer.state)))
    }

    private func checkTransferTimeout(_ id: String) {
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, let transfer = self.nativeTransfer, transfer.invitation.id == id else { return }
            let uploading = self.connections.values.contains { $0.request?.headers["x-primuse-transfer"] == id && $0.upload != nil }
            if !uploading && Date().timeIntervalSince(transfer.lastActivity) > (transfer.state == "waiting" ? 120 : 300) {
                self.nativeTransfer = nil
                self.event(.transferEnded)
            } else { self.checkTransferTimeout(id) }
        }
    }

    private func respond(_ client: Client, status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        respond(client, status: status, body: body)
    }

    private func respond(_ client: Client, status: Int, body: Data, type: String = "application/json") {
        guard !client.responded else { return }
        client.responded = true
        var response = Data(("HTTP/1.1 \(status) Response\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
            + "Referrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n"
            + "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n\r\n").utf8)
        response.append(body)
        let id = client.id
        client.connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.finish(id) })
    }

    private static func localAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let entry = current.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name).hasPrefix("en"),
                  entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}
