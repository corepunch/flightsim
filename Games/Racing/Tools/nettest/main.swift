import Foundation
import Network
import simd

setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok   \(what)" : "FAIL \(what)")
    if !ok { failures += 1 }
}
@discardableResult
func wait(_ timeout: Double, _ cond: () -> Bool) -> Bool {
    let end = Date() + timeout
    while Date() < end {
        if cond() { return true }
        RunLoop.main.run(until: Date() + 0.005)
    }
    return cond()
}

// Analytic trajectories: each car circles its own centre at 20 m/s.
func truth(_ id: UInt8, _ t: Double) -> NetCarState {
    let r: Float = 40, w: Float = 0.5, a = w * Float(t) + Float(id)
    let c = SIMD3<Float>(Float(id) * 100, 0, 0)
    var s = NetCarState()
    s.position = c + SIMD3(r * cos(a), 0, r * sin(a))
    s.velocity = SIMD3(-r * w * sin(a), 0, r * w * cos(a))
    s.orientation = simd_quatf(angle: -a, axis: SIMD3(0, 1, 0))
    s.progress = Float(t) * 20
    s.steer = 0.3
    return s
}

// A large respawn jump should never interpolate through the space between poses.
do {
    var before = NetCarState()
    before.position = SIMD3(70, -2, 0)
    var after = before
    after.position = SIMD3(10, 0.6, 0)
    var buffer = SnapshotBuffer()
    buffer.insert(before, at: 1)
    buffer.insert(after, at: 1.04)
    check(buffer.sample(at: 1.02)?.position == after.position, "large respawn jump resets interpolation")
}

// Normal jitter may be extrapolated; a silent sender's frozen visual must
// stop colliding even while the connection is alive. A fresh pose restores it.
do {
    var buffer = SnapshotBuffer()
    check(buffer.remoteSample(at: 10) == nil, "no remote pose or collider before the first sample")
    var pose = NetCarState()
    pose.velocity = SIMD3(20, 0, 0)
    buffer.insert(pose, at: 10)
    let stillFresh = buffer.remoteSample(at: 10.25)
    let stale = buffer.remoteSample(at: 10.5)
    check(stillFresh?.allowsCollision == true, "ordinary extrapolation keeps the remote collider")
    check(stale?.allowsCollision == false && stale?.state.position == stillFresh?.state.position,
          "stale pose remains visible but does not collide")
    pose.position = SIMD3(11, 0, 0)
    buffer.insert(pose, at: 10.55)
    let resumed = buffer.remoteSample(at: 10.55)
    check(resumed?.allowsCollision == true && resumed?.state.position == pose.position,
          "fresh data resumes the collider at the new pose")
}

let t0 = Date()
let settings = MatchSettings(trackIndex: 2, trackSeed: 42, laps: 3, stake: 100)
let host = try RaceClient.host(name: "Host", loadout: Data([1, 2, 3]), settings: settings)
let server = host.server!
print("server on UDP \(server.port)")
check(server.port != 0, "server bound a UDP port")
check(wait(2) { host.localID != nil }, "host client accepted over loopback")

// A client aimed at a dead port, to check the 8 s timeout at the end.
var deadReason: String?
let dead = RaceClient.join(host: "127.0.0.1", port: 9, name: "Nobody", loadout: Data())
dead.onDisconnect = { deadReason = $0 }

let bigLoadout = Data((0..<400).map { UInt8($0 & 0xFF) })
let g1 = RaceClient.join(host: "127.0.0.1", port: server.port, name: "Guest One", loadout: bigLoadout)
let g2 = RaceClient.join(host: "127.0.0.1", port: server.port, name: "Guest Two", loadout: Data([9]))
var g2Reason: String?
g2.onDisconnect = { g2Reason = $0 }
var hostChanges = 0
host.onChange = { hostChanges += 1; precondition(Thread.isMainThread) }
let clients = [host, g1, g2]

check(wait(3) { clients.allSatisfy { $0.cars.count == 3 } }, "roster of 3 synced to all clients")
check(clients.allSatisfy { $0.settings == settings }, "settings synced")
check(g2.cars.first { $0.name == "Guest One" }?.loadout == bigLoadout, "400-byte loadout delivered to other guests")
check(Set(clients.compactMap(\.localID)).count == 3, "distinct client ids")
check(clients.allSatisfy { $0.myCarIDs.count == 1 }, "each client owns one car")

// Wrong protocol version is turned away with a reason.
do {
    let q = DispatchQueue(label: "rawjoin")
    var reason: String?
    let link = UDPLink(NWConnection(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: server.port)!), using: .udp))
    let channel = NetChannel(link: link)
    link.start(queue: q, receive: { data in
        guard let payload = channel.process(data) else { return }
        var r = MsgReader(payload)
        while let (type, body) = r.message() {
            if type == ServerMsg.disconnect.rawValue { var b = body; reason = b.string() }
        }
    })
    q.sync {
        channel.queueReliable(MsgWriter.message(ClientMsg.join.rawValue) { $0.u16(99); $0.string("Old"); $0.blob(Data()) })
        channel.transmit()
    }
    wait(2) { q.sync { reason != nil } }
    let got = q.sync { reason }
    check(got?.contains("version") == true, "version mismatch rejected: \(got ?? "nil")")
    link.close()
}
check(host.cars.count == 3, "rejected joiner never entered the roster")

host.addBot(name: "Robo", loadout: Data([7, 7]))
check(wait(2) { clients.allSatisfy { $0.cars.count == 4 } }, "bot added and synced")
check(host.myCarIDs.count == 2 && host.myCarIDs.first == host.cars.first { !$0.isBot && $0.ownerID == host.localID }?.id,
      "host owns its car first, then the bot")

host.startRace()
wait(0.4) { false }
check(host.phase == .lobby, "start refused while guests aren't ready")
g1.setReady(true); g2.setReady(true)
check(wait(2) { host.canStart }, "all guests ready")
server.finishGrace = 1.5
host.startRace()
check(wait(2) { clients.allSatisfy { if case .loading = $0.phase { return true } else { return false } } }, "all clients loading")
host.reportLoaded(); g1.reportLoaded()
wait(0.5) { false }
check(clients.allSatisfy { if case .loading = $0.phase { return true } else { return false } }, "countdown waits for the last racer to load")
g2.reportLoaded()
check(wait(2) { clients.allSatisfy { if case .countdown = $0.phase { return true } else { return false } } }, "all clients in countdown")
let starts = clients.map { c -> Double in if case .countdown(let s) = c.phase { return s } else { return -1 } }
check(Set(starts).count == 1 && abs(starts[0] - server.time - 4) < 0.1, "identical countdown start ≈ now + 4 s")
wait(0.6) { false }   // let clock sync settle
for (i, c) in clients.enumerated() {
    let skew = c.serverTime - server.time
    print(String(format: "     client %d clock skew %.3f ms, ping %.3f ms", i, skew * 1000, c.ping * 1000))
    check(abs(skew) < 0.005, "client \(i) server clock within 5 ms")
}

// Stream states from all three devices at 60 Hz and sample the interpolation.
let streaming = DispatchQueue(label: "stream")
var keepStreaming = true
let streamLock = NSLock()
streaming.async {
    while streamLock.withLock({ keepStreaming }) {
        for c in clients {
            let t = c.serverTime
            c.send(states: Dictionary(uniqueKeysWithValues: c.myCarIDs.map { ($0, truth($0, t)) }))
        }
        Thread.sleep(forTimeInterval: 1 / 60)
    }
}
var maxErr: Float = 0, maxAngle: Float = 0, samples = 0, sawAll = true
let streamEnd = Date() + 2.2
wait(0.4) { false }
while Date() < streamEnd {
    for c in clients {
        let rt = c.serverTime - c.interpolationDelay
        let remote = c.remoteStates(at: rt)
        if remote.count != 4 - c.myCarIDs.count { sawAll = false }
        for (id, s) in remote {
            let want = truth(id, rt)
            maxErr = max(maxErr, simd_distance(s.position, want.position))
            maxAngle = max(maxAngle, abs((s.orientation * want.orientation.inverse).angle).truncatingRemainder(dividingBy: 2 * .pi))
            samples += 1
        }
    }
    wait(0.02) { false }
}
streamLock.withLock { keepStreaming = false }
print(String(format: "     %d samples, max position error %.4f m, max angle error %.5f rad", samples, maxErr, min(maxAngle, 2 * .pi - maxAngle)))
check(sawAll, "every client sees every other car")
check(samples > 100 && maxErr < 0.1, "interpolated positions track the true trajectory (< 10 cm at 20 m/s)")
check(min(maxAngle, 2 * .pi - maxAngle) < 0.01, "interpolated orientation tracks the truth")
let ext = host.remoteStates(at: host.serverTime + 5)
let g1Car = g1.myCarIDs[0]
check(ext[g1Car].map { simd_distance($0.position, truth(g1Car, host.serverTime).position) < 40 } == true, "extrapolation holds after 0.25 s")
check(host.remoteSamples(at: host.serverTime + 5)[g1Car]?.allowsCollision == false,
      "live client keeps the visual pose but exposes the stale collider state")

// Finishes: arrival order differs from time order; the bot never finishes.
// A real lap cannot finish in the first tick after GO, but this synthetic
// finish can. Wait for the authoritative transition, not client prediction.
check(wait(4) { clients.allSatisfy { if case .racing = $0.reportedPhase { return true } else { return false } } }, "server confirmed racing at GO")
let botID = host.myCarIDs[1]
g1.reportFinish(carID: botID, time: 1)   // not g1's car: ignored
g1.reportFinish(carID: g1.myCarIDs[0], time: 62)
wait(0.1) { false }
g2.reportFinish(carID: g2.myCarIDs[0], time: 61)
wait(0.1) { false }
host.reportFinish(carID: host.myCarIDs[0], time: 60.5)
check(wait(1) { clients.allSatisfy { $0.finishTimes.count == 3 } }, "per-car finish notifications")
check(clients.allSatisfy { if case .racing = $0.phase { return true } else { return false } }, "still racing during the grace period")
check(wait(3) { clients.allSatisfy { $0.phase == .results && $0.results.count == 4 } }, "results after the DNF grace")
let results = g2.results
let expected: [(UInt8, Float?, Int)] = [(host.myCarIDs[0], 60.5, 180), (g2.myCarIDs[0], 61, 90), (g1.myCarIDs[0], 62, 30), (botID, nil, 0)]
check(results.map(\.carID) == expected.map(\.0) && results.map(\.time) == expected.map(\.1), "ordered by measured time, bot DNF")
check(results.map(\.payout) == expected.map(\.2), "stake pot 300 split 180/90/30: \(results.map(\.payout))")
check(clients.allSatisfy { $0.results == results }, "everyone has the same results")

host.returnToLobby()
check(wait(2) { clients.allSatisfy { $0.phase == .lobby } && !host.cars.contains { !$0.isBot && $0.ready } }, "back to lobby, ready flags reset")
check(clients.allSatisfy { $0.remoteStates().isEmpty }, "returning to lobby drops the previous grid's poses")
g1.send(states: [g1Car: truth(g1Car, g1.serverTime)])
wait(0.2) { false }
check(clients.allSatisfy { $0.remoteStates().isEmpty }, "late state sends cannot restore poses in the lobby")


// A guest arriving mid-race waits for the next one.
g2.setReady(true); g1.setReady(true)
wait(2) { host.canStart }
host.startRace()
check(wait(2) {
    clients.allSatisfy { if case .loading = $0.phase { return true } else { return false } }
}, "second race is loading on every client")
check(clients.allSatisfy { $0.remoteStates().isEmpty }, "new grids have no remote poses before the first send")
let gridPose = truth(g1Car, g1.serverTime)
g1.send(states: [g1Car: gridPose])
check(wait(2) { host.remoteStates()[g1Car] != nil }, "first pose arrives while the second grid is loading")
for c in clients { c.reportLoaded() }
check(wait(2) {
    clients.allSatisfy { if case .countdown = $0.phase { return true } else { return false } }
}, "second countdown reached")
check(host.remoteStates()[g1Car] != nil, "valid grid pose survives the loading-to-countdown transition")
let late = RaceClient.join(host: "127.0.0.1", port: server.port, name: "Late", loadout: Data())
check(wait(2) { late.cars.count == 5 }, "late joiner gets the roster")
check(late.cars.first { $0.id == late.myCarIDs.first }?.inRace == false && late.cars.filter(\.inRace).count == 4,
      "late joiner is held out of the running race")
if case .countdown = late.phase {} else if case .racing = late.phase {} else { check(false, "late joiner sees the race phase") }
late.leave()
check(wait(2) { host.cars.count == 4 }, "late joiner left")

// A guest leaves.
g1.leave()
check(wait(2) { host.cars.count == 3 && g2.cars.count == 3 }, "guest leaving drops its car from every roster")
check(host.remoteStates()[g1Car] == nil && g2.remoteStates()[g1Car] == nil,
      "departed guest no longer has a sampled pose")

// Info query and Bonjour (Bonjour is best effort headless).
let browser = LANBrowser()
browser.start()
browser.query(host: "127.0.0.1", port: server.port)
check(wait(3) { browser.servers.contains { $0.name == "Host" && $0.players == 3 && $0.trackIndex == 2 && $0.phase == "Racing" } },
      "server info query answered")
let bonjour = wait(3) { browser.servers.contains { if case .service = $0.endpoint { return true } else { return false } } }
print("     Bonjour advertised: \(server.isAdvertised), browsed: \(bonjour) (not asserted)")
browser.stop()

// Host leaves: guests are told why.
host.leave()
check(wait(3) { g2Reason != nil }, "guest disconnected when the host leaves: \(g2Reason ?? "nil")")

check(wait(max(0, 9.5 - Date().timeIntervalSince(t0))) { deadReason != nil }, "unreachable host times out: \(deadReason ?? "nil")")

print(failures == 0 ? "ALL PASSED (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s)" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
