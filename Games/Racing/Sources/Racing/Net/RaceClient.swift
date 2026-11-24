import Foundation
import Network
import QuartzCore

/// One device's view of a LAN race, host or guest alike (the host's runs over loopback to
/// its own `RaceServer`). Streams this device's cars at 30 Hz, keeps the server clock,
/// mirrors the roster/settings/phase/results, and buffers everyone else's cars so they
/// can be drawn smoothly a little in the past.
///
/// Public state is safe to read from any thread; `send(states:)` and `remoteStates()` are
/// meant for the render thread. Callbacks always arrive on the main queue.
final class RaceClient: @unchecked Sendable {
    let isHost: Bool
    var onChange: (() -> Void)?
    var onDisconnect: ((String) -> Void)?

    private let name: String
    private let queue = DispatchQueue(label: "arcline.client", qos: .userInteractive)
    private let lock = NSLock()
    /// The race this device hosts (nil for a guest, and after leaving).
    private(set) var server: RaceServer?

    // Confined to `queue`.
    private var channel: NetChannel?
    private var timer: DispatchSourceTimer?
    private var closed = false
    private var lastPing = -Double.infinity
    private var pings = 0

    // Guarded by `lock`.
    private var shared = Shared()

    private struct Shared {
        var localID: UInt8?
        var ownCarID: UInt8?
        var serverName = ""
        var roster: [NetCar] = []
        var loadouts: [UInt8: Data] = [:]
        var settings = MatchSettings()
        var phase = NetPhase.lobby
        var results: [NetResult] = []
        var finishTimes: [UInt8: Float] = [:]
        var clock = ClockSync()
        var buffers: [UInt8: SnapshotBuffer] = [:]
        var outgoing: [UInt8: NetCarState] = [:]
        var outgoingStamp = 0.0
        var outgoingDirty = false
        var lastSent = -Double.infinity
        var notifyPending = false
        var interpolationDelay = 0.1
        var disconnected = false
    }

    private init(isHost: Bool, name: String, settings: MatchSettings = MatchSettings()) {
        self.isHost = isHost
        self.name = name
        shared.settings = settings
    }

    deinit { timer?.cancel() }

    // MARK: - Connecting

    /// Creates and owns a `RaceServer` (open on the LAN) and joins it over loopback.
    /// `room` is what the browser lists; it defaults to the driver's name.
    static func host(name: String, room: String? = nil, loadout: Data, settings: MatchSettings) throws -> RaceClient {
        let server = RaceServer(name: room ?? name, settings: settings)
        try server.start()
        let client = RaceClient(isHost: true, name: name, settings: settings)
        client.server = server
        let link = server.connectLoopback(on: client.queue) { [weak client] data in client?.received(data) }
        client.begin(link, loadout: loadout)
        return client
    }

    static func join(_ server: LANServerInfo, name: String, loadout: Data) -> RaceClient {
        join(server.endpoint, name: name, loadout: loadout)
    }

    static func join(_ endpoint: NWEndpoint, name: String, loadout: Data) -> RaceClient {
        let client = RaceClient(isHost: false, name: name)
        let link = UDPLink(NWConnection(to: endpoint, using: .udp))
        link.start(queue: client.queue,
                   receive: { [weak client] data in client?.received(data) },
                   failed: { [weak client] error in client?.queue.async { client?.disconnect("Network error: \(error)") } })
        client.begin(link, loadout: loadout)
        return client
    }

    /// Direct IP, for testing or when Bonjour is unavailable.
    static func join(host: String, port: UInt16 = NetProtocol.port, name: String, loadout: Data) -> RaceClient {
        join(.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any), name: name, loadout: loadout)
    }

    private func begin(_ link: DatagramLink, loadout: Data) {
        queue.async {
            let channel = NetChannel(link: link)
            self.channel = channel
            channel.queueReliable(MsgWriter.message(ClientMsg.join.rawValue) { w in
                w.u16(NetProtocol.version)
                w.string(self.name, maxBytes: 63)
                w.blob(loadout.prefix(NetProtocol.maxLoadout))
            })
            self.startTicking()
        }
    }

    private func startTicking() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / NetProtocol.tickRate, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    // MARK: - State

    var localID: UInt8? { locked { $0.localID } }
    var serverName: String { locked { $0.serverName } }
    var settings: MatchSettings { locked { $0.settings } }
    var results: [NetResult] { locked { $0.results } }
    /// Finish times reported so far this race, by car.
    var finishTimes: [UInt8: Float] { locked { $0.finishTimes } }
    var isConnected: Bool { locked { $0.localID != nil && !$0.disconnected } }

    /// Roster in join order, loadouts included.
    var cars: [NetCar] { locked { $0.roster } }

    /// Own car first, then (on the host) its bots.
    var myCarIDs: [UInt8] { locked { Self.myCars($0) } }

    /// The phase, with GO taken from the local estimate of the server clock so every
    /// device leaves the grid together, not when the server's next message lands.
    var phase: NetPhase {
        locked { s in
            if case .countdown(let start) = s.phase, Self.serverTime(s) >= start { return .racing(start: start) }
            return s.phase
        }
    }

    /// Estimated server time now.
    /// The last phase announced by the server, without the local GO prediction.
    var reportedPhase: NetPhase { locked { $0.phase } }

    var serverTime: Double { locked { Self.serverTime($0) } }
    /// Smoothed round trip in seconds.
    var ping: Double { locked { $0.clock.rtt } }

    /// How far in the past remote cars are drawn; a few snapshot intervals hides jitter.
    var interpolationDelay: Double {
        get { locked { $0.interpolationDelay } }
        set { locked { $0.interpolationDelay = newValue } }
    }

    /// Host only: every guest is ready (bots always are, the host is by starting).
    var canStart: Bool {
        locked { s in
            isHost && s.phase == .lobby && s.roster.allSatisfy { $0.isBot || $0.ready || $0.ownerID == s.localID }
        }
    }

    private func locked<T>(_ body: (inout Shared) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&shared)
    }

    private static func serverTime(_ s: Shared) -> Double { CACurrentMediaTime() + s.clock.offset }

    private static func myCars(_ s: Shared) -> [UInt8] {
        guard let localID = s.localID else { return [] }
        let bots = s.roster.filter { $0.ownerID == localID && $0.id != s.ownCarID }.map(\.id)
        return (s.ownCarID.map { [$0] } ?? []) + bots
    }

    // MARK: - Commands

    func setReady(_ ready: Bool) { sendReliable(.ready) { $0.bool(ready) } }

    /// Replaces this player's own car loadout (lobby car swap).
    func updateLoadout(_ loadout: Data) { sendReliable(.loadout) { $0.blob(loadout.prefix(NetProtocol.maxLoadout)) } }

    func updateSettings(_ s: MatchSettings) {
        guard isHost else { return }
        sendReliable(.settings) { s.write(to: &$0) }
    }

    func addBot(name: String, loadout: Data) {
        guard isHost else { return }
        sendReliable(.addBot) { $0.string(name, maxBytes: 63); $0.blob(loadout.prefix(NetProtocol.maxLoadout)) }
    }

    func removeBot(_ id: UInt8) {
        guard isHost else { return }
        sendReliable(.removeBot) { $0.u8(id) }
    }

    /// Host only: removes the guest who owns `carID`.
    func kick(carID: UInt8) {
        guard isHost else { return }
        sendReliable(.kick) { $0.u8(carID) }
    }

    /// Host only; the server ignores it unless everyone is ready.
    func startRace() {
        guard isHost else { return }
        sendReliable(.start)
    }

    /// Host only, after results.
    func returnToLobby() {
        guard isHost else { return }
        sendReliable(.returnToLobby)
    }

    /// `time` is this device's own measured race time for the car: ordering by it is fair
    /// regardless of each device's latency to the host.
    /// The circuit is built here: the server can start the countdown once everyone has said so.
    func reportLoaded() { sendReliable(.loaded) }

    func reportFinish(carID: UInt8, time: Float) {
        sendReliable(.finish) { $0.u8(carID); $0.f32(time) }
    }

    /// Call every frame from any thread; the latest states go out at 30 Hz, stamped with
    /// the server time they were taken at.
    func send(states: [UInt8: NetCarState]) {
        locked { s in
            let mine = Set(Self.myCars(s))
            s.outgoing = states.filter { mine.contains($0.key) }
            s.outgoingStamp = Self.serverTime(s)
            s.outgoingDirty = true
        }
    }

    /// Other cars as they should be drawn now. Excludes this device's own cars.
    func remoteStates() -> [UInt8: NetCarState] {
        remoteSamples().mapValues { $0.state }
    }

    func remoteStates(at renderTime: Double) -> [UInt8: NetCarState] {
        remoteSamples(at: renderTime).mapValues { $0.state }
    }

    /// Read the visual pose and collision freshness together from the same buffer.
    func remoteSamples(at renderTime: Double? = nil) -> [UInt8: RemoteCarSample] {
        locked { s in
            let t = renderTime ?? (Self.serverTime(s) - s.interpolationDelay)
            let mine = Set(Self.myCars(s))
            var out: [UInt8: RemoteCarSample] = [:]
            for (id, buffer) in s.buffers where !mine.contains(id) {
                if let sample = buffer.remoteSample(at: t) { out[id] = sample }
            }
            return out
        }
    }

    /// Leaves quietly (no `onDisconnect`). On the host this closes the race for everyone.
    func leave() {
        queue.async {
            guard !self.closed else { return }
            let bye = MsgWriter.message(ClientMsg.leave.rawValue)
            for _ in 0..<3 { self.channel?.transmit(bye) }
            self.close()
            self.server?.stop(reason: "The host left the race")
            self.server = nil
        }
    }

    private func sendReliable(_ type: ClientMsg, _ body: @escaping (inout MsgWriter) -> Void = { _ in }) {
        let message = MsgWriter.message(type.rawValue, body)
        queue.async { if !self.closed { self.channel?.queueReliable(message) } }
    }

    // MARK: - Network

    private func tick() {
        guard !closed, let channel else { return }
        if channel.idle > NetProtocol.timeout {
            disconnect(localID == nil ? "Couldn't reach the host" : "Lost connection to the host")
            return
        }
        let now = CACurrentMediaTime()
        var w = MsgWriter()
        // Ping fast until the clock has settled, then a few times a second to track drift.
        if now - lastPing >= (pings < 10 ? 0.05 : 0.2) {
            lastPing = now
            pings += 1
            w.message(ClientMsg.ping.rawValue) { $0.f64(now) }
        }
        locked { s in
            guard s.outgoingDirty, s.localID != nil, !s.outgoing.isEmpty else { return }
            s.outgoingDirty = false
            let states = s.outgoing, stamp = s.outgoingStamp
            w.message(ClientMsg.states.rawValue) { w in
                w.f64(stamp)
                w.u8(UInt8(min(states.count, NetProtocol.maxCars)))
                for (id, state) in states.prefix(NetProtocol.maxCars) {
                    w.u8(id)
                    state.write(to: &w)
                }
            }
        }
        channel.transmit(w.data)
    }

    private func received(_ packet: Data) {
        guard !closed, let channel, let payload = channel.process(packet) else { return }
        let arrived = CACurrentMediaTime()
        var r = MsgReader(payload)
        var changed = false
        while let (type, body) = r.message(), !closed {
            if handle(type, body, arrived) { changed = true }
        }
        if changed && !closed { notifyChange() }
    }

    /// Returns whether something `onChange` listeners care about changed.
    private func handle(_ type: UInt8, _ body: MsgReader, _ arrived: Double) -> Bool {
        var r = body
        guard let message = ServerMsg(rawValue: type) else { return false }
        switch message {
        case .pong:
            let sent = r.f64(), time = r.f64()
            guard !r.overflow else { return false }
            locked { $0.clock.add(sent: sent, serverTime: time, received: arrived) }
            return false

        case .snapshot:
            let time = r.f64()
            let count = Int(r.u8())
            var states: [(UInt8, Double, NetCarState)] = []
            for _ in 0..<count {
                let id = r.u8(), age = r.f32()
                states.append((id, time - Double(age), NetCarState(from: &r)))
            }
            guard !r.overflow else { return false }
            locked { s in
                guard s.phase != .lobby else { return }
                for (id, stamp, state) in states where s.roster.contains(where: { $0.id == id && $0.inRace }) {
                    s.buffers[id, default: SnapshotBuffer()].insert(state, at: stamp)
                }
            }
            return false

        case .accept:
            let clientID = r.u8(), carID = r.u8(), time = r.f64(), name = r.string()
            guard !r.overflow else { return false }
            locked { s in
                s.localID = clientID
                s.ownCarID = carID
                s.serverName = name
                s.clock.seed(serverTime: time, localTime: arrived)
            }
            return true

        case .disconnect:
            let reason = r.string()
            disconnect(reason.isEmpty ? "Disconnected by the host" : reason)
            return false

        case .roster:
            let count = Int(r.u8())
            var roster: [(UInt8, UInt8, UInt8, String)] = []
            for _ in 0..<count { roster.append((r.u8(), r.u8(), r.u8(), r.string())) }
            guard !r.overflow else { return false }
            locked { s in
                s.roster = roster.map { id, owner, flags, name in
                    NetCar(id: id, ownerID: owner, name: name, loadout: s.loadouts[id] ?? Data(),
                           isBot: flags & 1 != 0, ready: flags & 2 != 0, inRace: flags & 4 != 0)
                }
                let ids = Set(roster.map(\.0))
                s.buffers = s.buffers.filter { ids.contains($0.key) }
                s.loadouts = s.loadouts.filter { ids.contains($0.key) }
            }
            return true

        case .loadout:
            let id = r.u8(), loadout = r.blob()
            guard !r.overflow else { return false }
            locked { s in
                s.loadouts[id] = loadout
                if let i = s.roster.firstIndex(where: { $0.id == id }) { s.roster[i].loadout = loadout }
            }
            return true

        case .settings:
            let settings = MatchSettings(from: &r)
            guard !r.overflow, r.remaining == 0 else { return false }
            locked { $0.settings = settings }
            return true

        case .phase:
            let phase = NetPhase(from: &r)
            guard !r.overflow else { return false }
            locked { s in
                switch phase {
                case .lobby, .loading:
                    // Clear old poses before a newly loaded scene can read them.
                    s.buffers.removeAll()
                    s.outgoing.removeAll()
                    s.outgoingDirty = false
                    s.finishTimes.removeAll()
                    s.results.removeAll()
                case .countdown, .racing, .results:
                    break
                }
                s.phase = phase
            }
            return true

        case .finish:
            let id = r.u8(), time = r.f32()
            guard !r.overflow else { return false }
            locked { $0.finishTimes[id] = time }
            return true

        case .results:
            let count = Int(r.u8())
            guard !r.overflow, count <= NetProtocol.maxCars, r.remaining == count * 5 else { return false }
            var results: [NetResult] = []
            var ids = Set<UInt8>()
            for _ in 0..<count {
                let id = r.u8(), time = r.f32()
                guard ids.insert(id).inserted, time.isNaN || (time.isFinite && time > 0) else { return false }
                results.append(NetResult(carID: id, time: time.isNaN ? nil : time))
            }
            guard !r.overflow else { return false }
            locked { $0.results = results }
            return true
        }
    }

    private func notifyChange() {
        let first = locked { s -> Bool in
            defer { s.notifyPending = true }
            return !s.notifyPending
        }
        guard first else { return }
        DispatchQueue.main.async {
            self.locked { $0.notifyPending = false }
            self.onChange?()
        }
    }

    private func close() {
        closed = true
        timer?.cancel()
        timer = nil
        channel?.link.close()
        locked { $0.disconnected = true }
    }

    private func disconnect(_ reason: String) {
        guard !closed else { return }
        close()
        server?.stop(reason: "The host left the race")
        server = nil
        DispatchQueue.main.async { self.onDisconnect?(reason) }
    }
}
