import Foundation
import Network
import QuartzCore

enum NetError: Error, LocalizedError {
    case listenFailed(String)

    var errorDescription: String? {
        switch self {
        case .listenFailed(let reason): return "Couldn't open the race to the network: \(reason)"
        }
    }
}

/// The host-authoritative half of a LAN race. Ticks at 30 Hz on its own serial queue and
/// owns everything except movement: the roster, match settings, the countdown, the race
/// clock, finish order and results. Cars are simulated on their owners' devices; the
/// server only relays their latest poses in each tick's snapshot.
///
/// Guests reach it over UDP (advertised on Bonjour as `_arcline._udp`); the host's own
/// `RaceClient` uses `connectLoopback`, so both go through the very same protocol.
final class RaceServer: @unchecked Sendable {
    let name: String
    /// The UDP port actually bound (0 until `start()`).
    private(set) var port: UInt16 = 0
    /// Whether Bonjour is advertising the race (it can fail where mDNS is unavailable).
    private(set) var isAdvertised = false

    private let queue = DispatchQueue(label: "arcline.server", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Void>()
    private let epoch = CACurrentMediaTime()
    private var timer: DispatchSourceTimer?
    private var listener: NWListener?

    // Everything below is confined to `queue`.

    private struct Car {
        var info: NetCar
        var state: NetCarState?
        var stateTime: Double = -.infinity
    }

    private final class Peer {
        let channel: NetChannel
        let isHost: Bool
        var clientID: UInt8?
        init(channel: NetChannel, isHost: Bool) { self.channel = channel; self.isHost = isHost }
    }

    private var settings: MatchSettings
    private var phase = NetPhase.lobby
    private var cars: [Car] = []
    private var peers: [ObjectIdentifier: Peer] = [:]
    /// Every link we accept packets from, with when it was last heard. Listener flows that
    /// never become peers (info queries) are reaped after a few seconds.
    private var links: [ObjectIdentifier: (link: DatagramLink, lastSeen: Double)] = [:]
    private var hostLink: ObjectIdentifier?
    private var finishes: [UInt8: Float] = [:]
    /// Clients whose circuit is built, while loading.
    private var loaded: Set<UInt8> = []
    private var firstHumanFinish: Double?
    private var results: [NetResult] = []
    private var nextClientID: UInt8 = 1
    private var nextCarID: UInt8 = 0
    private var stopped = false
    private var grace = NetProtocol.finishGrace

    init(name: String, settings: MatchSettings) {
        self.name = name
        self.settings = settings
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { timer?.cancel(); listener?.cancel() }

    /// How long the field has after the first human finishes before the rest are DNF.
    var finishGrace: Double {
        get { onQueue { grace } }
        set { onQueue { grace = newValue } }
    }

    /// Seconds on the race clock (monotonic, shared by every client via clock sync).
    var time: Double { CACurrentMediaTime() - epoch }

    // MARK: - Lifecycle

    /// Opens the UDP listener (port 27911, or any free one if that's busy) with its Bonjour
    /// advert, and starts ticking. Throws only if no UDP socket can be opened at all.
    func start() throws {
        try openListener()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / NetProtocol.tickRate, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() { stop(reason: "The host closed the race") }

    func stop(reason: String) { onQueue { self.shutdown(reason: reason) } }

    /// The host client's end of an in-process link. `receive` is called on `clientQueue`.
    func connectLoopback(on clientQueue: DispatchQueue, receive: @escaping (Data) -> Void) -> DatagramLink {
        let (client, server) = LoopbackLink.pair(clientQueue, queue)
        client.onReceive(receive)
        server.onReceive { [weak self, weak server] data in
            guard let self, let server else { return }
            self.received(data, from: server)
        }
        onQueue {
            let id = ObjectIdentifier(server)
            self.links[id] = (server, self.time)
            if self.hostLink == nil { self.hostLink = id }
        }
        return client
    }

    /// Snapshot of the roster, for tests and debugging.
    var roster: [NetCar] { onQueue { cars.map(\.info) } }
    var currentPhase: NetPhase { onQueue { phase } }

    private func onQueue<T>(_ work: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) != nil ? work() : queue.sync(execute: work)
    }

    private func openListener() throws {
        var lastError = "unknown error"
        for (port, advertise) in [(NetProtocol.port, true), (0, true), (0, false)] {
            let listener: NWListener
            do {
                listener = port == 0 ? try NWListener(using: .udp)
                                     : try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port)!)
            } catch {
                lastError = "\(error)"
                continue
            }
            if advertise {
                listener.service = NWListener.Service(name: name, type: NetProtocol.serviceType)
                listener.serviceRegistrationUpdateHandler = { [weak self] change in
                    if case .add = change { self?.isAdvertised = true }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

            let settled = DispatchSemaphore(value: 0)
            var failure: NWError?
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready, .waiting: settled.signal()   // waiting: no network yet, loopback still works
                case .failed(let error): failure = error; settled.signal()
                default: break
                }
            }
            listener.start(queue: queue)
            _ = settled.wait(timeout: .now() + 2)
            let failed: NWError? = queue.sync {
                listener.stateUpdateHandler = { state in
                    if case .failed(let error) = state { NSLog("RaceServer: listener failed: \(error)") }
                }
                return failure
            }
            if let failed {
                lastError = "\(failed)"
                listener.cancel()
                continue
            }
            self.listener = listener
            self.port = listener.port?.rawValue ?? port
            return
        }
        throw NetError.listenFailed(lastError)
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        let link = UDPLink(connection)
        links[ObjectIdentifier(link)] = (link, time)
        link.start(queue: queue) { [weak self, weak link] data in
            guard let self, let link else { return }
            self.received(data, from: link)
        }
    }

    private func shutdown(reason: String) {
        guard !stopped else { return }
        stopped = true
        for peer in peers.values { sendDisconnect(peer, reason) }
        for entry in links.values { entry.link.close() }
        peers.removeAll()
        links.removeAll()
        timer?.cancel()
        listener?.cancel()
    }

    // MARK: - Tick

    private func tick() {
        guard !stopped else { return }
        let now = time
        for (id, entry) in links where peers[id] == nil && id != hostLink && now - entry.lastSeen > 5 {
            entry.link.close()
            links[id] = nil
        }
        for peer in Array(peers.values) where peer.channel.idle > NetProtocol.timeout {
            drop(peer, reason: nil)
            if stopped { return }
        }
        if case .loading(let deadline) = phase, everyoneLoaded() || now >= deadline {
            phase = .countdown(start: now + NetProtocol.countdown)
            broadcast(phaseMessage())
        }
        if case .countdown(let start) = phase, now >= start {
            phase = .racing(start: start)
            broadcast(phaseMessage())
        }
        if case .racing = phase { checkRaceOver(now) }
        for peer in peers.values { peer.channel.transmit(peer.clientID.map { snapshot(for: $0, now) } ?? Data()) }
    }

    private func snapshot(for clientID: UInt8, _ now: Double) -> Data {
        let list = cars.filter { $0.info.inRace && $0.state != nil && $0.info.ownerID != clientID }
        return MsgWriter.message(ServerMsg.snapshot.rawValue) { w in
            w.f64(now)
            w.u8(UInt8(list.count))
            for car in list {
                w.u8(car.info.id)
                w.f32(Float(max(0, now - car.stateTime)))
                car.state!.write(to: &w)
            }
        }
    }

    // MARK: - Receiving

    private func received(_ packet: Data, from link: DatagramLink) {
        let id = ObjectIdentifier(link)
        guard !stopped, links[id] != nil else { return }
        links[id]!.lastSeen = time
        if let body = NetChannel.outOfBandBody(packet) {
            outOfBand(body, from: link)
            return
        }
        let peer: Peer
        if let existing = peers[id] {
            peer = existing
        } else {
            peer = Peer(channel: NetChannel(link: link), isHost: id == hostLink)
            peers[id] = peer
        }
        guard let payload = peer.channel.process(packet) else { return }
        var r = MsgReader(payload)
        while let (type, body) = r.message() {
            guard peers[id] != nil, !stopped else { return }   // dropped by an earlier message
            handle(type, body, from: peer)
        }
    }

    private func outOfBand(_ body: Data, from link: DatagramLink) {
        var r = MsgReader(body)
        guard r.u8() == OutOfBandMsg.infoRequest.rawValue else { return }
        var w = MsgWriter()
        w.u8(OutOfBandMsg.infoResponse.rawValue)
        w.u16(NetProtocol.version)
        w.string(name, maxBytes: 63)
        w.u8(UInt8(cars.count))
        w.u8(UInt8(NetProtocol.maxCars))
        var p = MsgWriter()
        phase.write(to: &p)
        w.u8(p.data.first ?? 0)
        settings.write(to: &w)
        link.send(NetChannel.outOfBand(w.data))
    }

    private func handle(_ type: UInt8, _ body: MsgReader, from peer: Peer) {
        var r = body
        guard let message = ClientMsg(rawValue: type) else { return }
        let now = time

        if message == .ping {
            let sent = r.f64()
            peer.channel.transmit(MsgWriter.message(ServerMsg.pong.rawValue) { $0.f64(sent); $0.f64(self.time) })
            return
        }
        if message == .leave { drop(peer, reason: nil); return }
        if message == .join { join(peer, &r); return }
        guard let clientID = peer.clientID else { return }   // nothing else before joining

        switch message {
        case .states:
            guard phase != .lobby else { return }
            // A client's clock estimate can run slightly ahead; never let a pose claim
            // to be from the future.
            let stamp = min(r.f64(), now)
            let count = Int(r.u8())
            for _ in 0..<count {
                let carID = r.u8()
                let state = NetCarState(from: &r)
                guard !r.overflow, let i = cars.firstIndex(where: { $0.info.id == carID }),
                      cars[i].info.ownerID == clientID, cars[i].info.inRace,
                      stamp > cars[i].stateTime else { continue }
                cars[i].state = state
                cars[i].stateTime = stamp
            }

        case .ready:
            let ready = r.bool()
            guard phase == .lobby, let i = cars.firstIndex(where: { $0.info.ownerID == clientID && !$0.info.isBot }) else { return }
            cars[i].info.ready = ready
            broadcast(rosterMessage())

        case .loadout:
            let loadout = r.blob().prefix(NetProtocol.maxLoadout)
            guard let i = cars.firstIndex(where: { $0.info.ownerID == clientID && !$0.info.isBot }) else { return }
            cars[i].info.loadout = Data(loadout)
            broadcast(loadoutMessage(cars[i].info))

        case .loaded:
            guard case .loading = phase else { return }
            loaded.insert(clientID)

        case .finish:
            let carID = r.u8(), raceTime = r.f32()
            guard !r.overflow, raceTime.isFinite, raceTime > 0, case .racing = phase,
                  let car = cars.first(where: { $0.info.id == carID }),
                  car.info.ownerID == clientID, car.info.inRace, finishes[carID] == nil else { return }
            finishes[carID] = raceTime
            if !car.info.isBot, firstHumanFinish == nil { firstHumanFinish = now }
            broadcast(MsgWriter.message(ServerMsg.finish.rawValue) { $0.u8(carID); $0.f32(raceTime) })
            checkRaceOver(now)

        default:
            guard peer.isHost else { return }
            hostCommand(message, &r, clientID, now)
        }
    }

    private func hostCommand(_ message: ClientMsg, _ r: inout MsgReader, _ hostID: UInt8, _ now: Double) {
        switch message {
        case .settings:
            let s = MatchSettings(from: &r)
            guard !r.overflow, phase == .lobby, s != settings else { return }
            settings = s
            broadcast(settingsMessage())

        case .addBot:
            let name = r.string(), loadout = r.blob()
            guard !r.overflow, phase == .lobby, cars.count < NetProtocol.maxCars else { return }
            let car = addCar(owner: hostID, name: name, loadout: loadout, isBot: true)
            broadcast(loadoutMessage(car))
            broadcast(rosterMessage())

        case .removeBot:
            let carID = r.u8()
            guard phase == .lobby, let i = cars.firstIndex(where: { $0.info.id == carID && $0.info.isBot }) else { return }
            cars.remove(at: i)
            broadcast(rosterMessage())

        case .kick:
            let carID = r.u8()
            guard let car = cars.first(where: { $0.info.id == carID }), car.info.ownerID != hostID,
                  let peer = peers.values.first(where: { $0.clientID == car.info.ownerID }) else { return }
            drop(peer, reason: "The host removed you from the race")

        case .start:
            // Bots are always ready; the host shows it is by pressing start.
            guard phase == .lobby,
                  cars.allSatisfy({ $0.info.isBot || $0.info.ready || $0.info.ownerID == hostID }) else { return }
            for i in cars.indices {
                cars[i].info.inRace = true
                cars[i].state = nil
                cars[i].stateTime = -.infinity
            }
            finishes.removeAll()
            results.removeAll()
            firstHumanFinish = nil
            loaded.removeAll()
            phase = .loading(deadline: now + NetProtocol.loadTimeout)
            broadcast(rosterMessage())
            broadcast(phaseMessage())

        case .returnToLobby:
            guard phase == .results else { return }
            for i in cars.indices {
                cars[i].info.inRace = false
                if !cars[i].info.isBot { cars[i].info.ready = false }
            }
            finishes.removeAll()
            phase = .lobby
            broadcast(rosterMessage())
            broadcast(phaseMessage())

        default:
            break
        }
    }

    private func join(_ peer: Peer, _ r: inout MsgReader) {
        let version = r.u16(), name = r.string(), loadout = r.blob()
        guard !r.overflow, peer.clientID == nil else { return }
        guard version == NetProtocol.version else {
            let newer = version < NetProtocol.version ? "the host has a newer version" : "the host has an older version"
            drop(peer, reason: "Can't join: \(newer) of the game (protocol \(NetProtocol.version), yours \(version))")
            return
        }
        guard cars.count < NetProtocol.maxCars else {
            drop(peer, reason: "This race is full")
            return
        }
        var clientID = nextClientID
        while clientID == 0 || peers.values.contains(where: { $0.clientID == clientID }) { clientID &+= 1 }
        nextClientID = clientID &+ 1
        peer.clientID = clientID

        // A guest arriving mid-race waits in the lobby (inRace false) for the next one.
        let car = addCar(owner: clientID, name: name, loadout: loadout, isBot: false)
        let channel = peer.channel
        channel.queueReliable(MsgWriter.message(ServerMsg.accept.rawValue) { w in
            w.u8(clientID)
            w.u8(car.id)
            w.f64(self.time)
            w.string(self.name, maxBytes: 63)
        })
        channel.queueReliable(settingsMessage())
        for other in cars where other.info.id != car.id { channel.queueReliable(loadoutMessage(other.info)) }
        broadcast(loadoutMessage(car))
        broadcast(rosterMessage())
        channel.queueReliable(phaseMessage())
        for (carID, time) in finishes {
            channel.queueReliable(MsgWriter.message(ServerMsg.finish.rawValue) { $0.u8(carID); $0.f32(time) })
        }
        if phase == .results { channel.queueReliable(resultsMessage()) }
    }

    private func addCar(owner: UInt8, name: String, loadout: Data, isBot: Bool) -> NetCar {
        var id = nextCarID
        while cars.contains(where: { $0.info.id == id }) { id &+= 1 }
        nextCarID = id &+ 1
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let car = NetCar(id: id, ownerID: owner, name: trimmed.isEmpty ? "Driver \(id + 1)" : String(trimmed.prefix(NetProtocol.maxName)),
                         loadout: Data(loadout.prefix(NetProtocol.maxLoadout)), isBot: isBot, ready: isBot)
        cars.append(Car(info: car))
        return car
    }

    // MARK: - Leaving

    private func sendDisconnect(_ peer: Peer, _ reason: String) {
        let message = MsgWriter.message(ServerMsg.disconnect.rawValue) { $0.string(reason) }
        for _ in 0..<3 { peer.channel.transmit(message) }
    }

    /// Removes a peer and its cars. `reason` is sent to it first (nil when it already left
    /// or can't hear us). Losing the host's own client ends the race for everyone.
    private func drop(_ peer: Peer, reason: String?) {
        if let reason { sendDisconnect(peer, reason) }
        let id = ObjectIdentifier(peer.channel.link)
        peers[id] = nil
        links[id] = nil
        peer.channel.link.close()
        if peer.isHost {
            shutdown(reason: "The host left the race")
            return
        }
        guard let clientID = peer.clientID else { return }
        let gone = Set(cars.filter { $0.info.ownerID == clientID }.map(\.info.id))
        cars.removeAll { gone.contains($0.info.id) }
        for carID in gone { finishes[carID] = nil }
        broadcast(rosterMessage())
        if case .racing = phase { checkRaceOver(time) }
    }

    // MARK: - Results

    private func checkRaceOver(_ now: Double) {
        let racers = cars.filter(\.info.inRace)
        let allIn = racers.allSatisfy { finishes[$0.info.id] != nil }
        let graceOver = firstHumanFinish.map { now - $0 >= grace } ?? false
        guard allIn || graceOver else { return }

        // Ordered by each car's own measured time, so latency doesn't decide a photo finish.
        let finished = racers.filter { finishes[$0.info.id] != nil }
            .sorted { (finishes[$0.info.id]!, $0.info.id) < (finishes[$1.info.id]!, $1.info.id) }
        let unfinished = racers.filter { finishes[$0.info.id] == nil }
            .sorted { ($0.state?.progress ?? -.infinity) > ($1.state?.progress ?? -.infinity) }
        let pot = settings.stake * racers.filter { !$0.info.isBot }.count
        let payouts = NetResult.payouts(pot: pot, finishers: finished.count)
        results = finished.enumerated().map { NetResult(carID: $1.info.id, time: finishes[$1.info.id], payout: payouts[$0]) }
            + unfinished.map { NetResult(carID: $0.info.id, time: nil) }
        phase = .results
        broadcast(resultsMessage())
        broadcast(phaseMessage())
    }

    // MARK: - Messages

    private func broadcast(_ message: Data) {
        for peer in peers.values where peer.clientID != nil { peer.channel.queueReliable(message) }
    }

    private func rosterMessage() -> Data {
        MsgWriter.message(ServerMsg.roster.rawValue) { w in
            w.u8(UInt8(self.cars.count))
            for car in self.cars.map(\.info) {
                w.u8(car.id)
                w.u8(car.ownerID)
                w.u8((car.isBot ? 1 : 0) | (car.ready ? 2 : 0) | (car.inRace ? 4 : 0))
                w.string(car.name, maxBytes: 63)
            }
        }
    }

    private func loadoutMessage(_ car: NetCar) -> Data {
        MsgWriter.message(ServerMsg.loadout.rawValue) { $0.u8(car.id); $0.blob(car.loadout) }
    }

    private func settingsMessage() -> Data {
        MsgWriter.message(ServerMsg.settings.rawValue) { self.settings.write(to: &$0) }
    }

    /// Every client with a car in the race has built the circuit (bots ride with the host).
    private func everyoneLoaded() -> Bool {
        let owners = Set(cars.filter(\.info.inRace).map(\.info.ownerID))
        let connected = Set(peers.values.compactMap(\.clientID))
        return owners.intersection(connected).isSubset(of: loaded)
    }

    private func phaseMessage() -> Data {
        MsgWriter.message(ServerMsg.phase.rawValue) { self.phase.write(to: &$0) }
    }

    private func resultsMessage() -> Data {
        MsgWriter.message(ServerMsg.results.rawValue) { w in
            w.u8(UInt8(self.results.count))
            for result in self.results {
                w.u8(result.carID)
                w.f32(result.time ?? .nan)
                w.i32(Int32(clamping: result.payout))
            }
        }
    }
}
