import Foundation
import Network
import QuartzCore

/// A race found on the LAN, as its host describes itself.
struct LANServerInfo: Equatable {
    var name: String
    var endpoint: NWEndpoint
    var players: Int
    var maxPlayers: Int
    /// "Lobby", "Racing" or "Results".
    var phase: String
    var trackIndex: Int
    var settings: MatchSettings
    var protocolVersion: UInt16
    /// Same wire version as this build; joining anything else will be refused.
    var isCompatible: Bool { protocolVersion == NetProtocol.version }
}

/// Finds races: browses Bonjour for `_arcline._udp`, then asks each host for its info
/// (name, cars, track, phase) every couple of seconds over a connectionless UDP query,
/// dropping hosts that stop answering. `query(host:port:)` probes a direct address too.
final class LANBrowser: @unchecked Sendable {
    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "arcline.browser")
    private let lock = NSLock()
    private var published: [LANServerInfo] = []
    private var lastError: String?

    // Confined to `queue`.
    private var browser: NWBrowser?
    private var timer: DispatchSourceTimer?
    private var probes: [NWEndpoint: NWConnection] = [:]
    private var found: [NWEndpoint: (info: LANServerInfo, seen: Double)] = [:]

    init() {}
    deinit { timer?.cancel(); browser?.cancel() }

    /// Sorted by name. Safe from any thread.
    var servers: [LANServerInfo] { lock.lock(); defer { lock.unlock() }; return published }
    /// Why browsing isn't working (local network permission denied, no Wi-Fi), if known.
    var error: String? { lock.lock(); defer { lock.unlock() }; return lastError }

    func start() {
        queue.async { self.beginBrowsing() }
    }

    func stop() {
        queue.async {
            self.browser?.cancel()
            self.browser = nil
            self.timer?.cancel()
            self.timer = nil
            for connection in self.probes.values { connection.cancel() }
            self.probes.removeAll()
            self.found.removeAll()
            self.publish()
        }
    }

    /// Probes a host directly (no Bonjour needed); it shows up in `servers` if it answers.
    func query(host: String, port: UInt16 = NetProtocol.port) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        queue.async {
            self.probe(endpoint)
            self.startPolling()
        }
    }

    private func beginBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: NetProtocol.serviceType, domain: nil), using: .udp)
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error), .waiting(let error): self?.setError("\(error)")
            case .ready: self?.setError(nil)
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        browser.start(queue: queue)
        self.browser = browser
        startPolling()
    }

    private func startPolling() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        let endpoints = Set(results.map(\.endpoint))
        for (endpoint, connection) in probes where !endpoints.contains(endpoint) {
            if case .service = endpoint {
                connection.cancel()
                probes[endpoint] = nil
                found[endpoint] = nil
            }
        }
        for endpoint in endpoints { probe(endpoint) }
        publish()
    }

    private func probe(_ endpoint: NWEndpoint) {
        let connection: NWConnection
        if let existing = probes[endpoint] {
            connection = existing
        } else {
            connection = NWConnection(to: endpoint, using: .udp)
            probes[endpoint] = connection
            connection.start(queue: queue)
            receive(on: connection, from: endpoint)
        }
        var w = MsgWriter()
        w.u8(OutOfBandMsg.infoRequest.rawValue)
        w.u16(NetProtocol.version)
        connection.send(content: NetChannel.outOfBand(w.data), completion: .idempotent)
    }

    private func receive(on connection: NWConnection, from endpoint: NWEndpoint) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data, let info = Self.parse(data, endpoint) {
                self.found[endpoint] = (info, CACurrentMediaTime())
                self.publish()
            }
            switch connection.state {
            case .cancelled, .failed: return
            default: break
            }
            if error != nil {
                self.queue.asyncAfter(deadline: .now() + 0.5) { self.receive(on: connection, from: endpoint) }
            } else {
                self.receive(on: connection, from: endpoint)
            }
        }
    }

    private static func parse(_ packet: Data, _ endpoint: NWEndpoint) -> LANServerInfo? {
        guard let body = NetChannel.outOfBandBody(packet) else { return nil }
        var r = MsgReader(body)
        guard r.u8() == OutOfBandMsg.infoResponse.rawValue else { return nil }
        let version = r.u16(), name = r.string(), players = Int(r.u8()), maxPlayers = Int(r.u8()), kind = r.u8()
        let settings = MatchSettings(from: &r)
        guard !r.overflow else { return nil }
        let phase = ["Lobby", "Racing", "Racing", "Results", "Racing"][Int(min(kind, 4))]
        return LANServerInfo(name: name, endpoint: endpoint, players: players, maxPlayers: maxPlayers, phase: phase,
                             trackIndex: settings.trackIndex, settings: settings, protocolVersion: version)
    }

    private func poll() {
        let now = CACurrentMediaTime()
        let before = found.count
        found = found.filter { now - $0.value.seen < 6 }
        for endpoint in probes.keys { probe(endpoint) }
        if found.count != before { publish() }
    }

    private func publish() {
        let list = found.values.map(\.info).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lock.lock()
        let changed = list != published
        published = list
        lock.unlock()
        if changed { DispatchQueue.main.async { self.onChange?() } }
    }

    private func setError(_ error: String?) {
        lock.lock()
        lastError = error
        lock.unlock()
        DispatchQueue.main.async { self.onChange?() }
    }
}
