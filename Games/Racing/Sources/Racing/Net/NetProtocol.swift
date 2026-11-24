import Foundation
import simd

// MARK: - Public model

/// One car's pose. Movement is client-authoritative: each device simulates its own cars
/// and streams this; everyone else only draws it.
struct NetCarState: Equatable {
    var position = SIMD3<Float>.zero
    var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var velocity = SIMD3<Float>.zero
    /// Metres since the start line (race order on the HUD).
    var progress: Float = 0
    /// −1...1, for front-wheel visuals.
    var steer: Float = 0
    var boosting = false
}

struct MatchSettings: Equatable {
    var trackIndex = 0
    var trackSeed: UInt64 = 0
    var laps = 3
    /// Credits each human car buys in with; 0 is a friendly race.
    var stake = 0
}

struct NetCar: Equatable {
    let id: UInt8
    var ownerID: UInt8
    var name: String
    /// Opaque to the net layer (≤ `NetProtocol.maxLoadout` bytes).
    var loadout: Data
    var isBot: Bool
    var ready: Bool
    /// Taking part in the current race. False for a guest who joined mid-race: they wait
    /// in the lobby for the next one.
    var inRace = false
}

struct NetResult: Equatable {
    var carID: UInt8
    /// The car's own measured race time; nil = did not finish.
    var time: Float?
    /// Credits won from the pot (gross; the stake was paid going in).
    var payout = 0

    /// The pot (every human car's stake) goes 60/30/10 to the first three finishers,
    /// renormalised when fewer finish; rounding goes to the winner. A bot's share stays
    /// in the house, so racing bots for money is a real risk.
    static func payouts(pot: Int, finishers: Int) -> [Int] {
        guard pot > 0, finishers > 0 else { return Array(repeating: 0, count: finishers) }
        let weights = Array([6, 3, 1].prefix(finishers))
        let total = weights.reduce(0, +)
        var shares = weights.map { pot * $0 / total }
        shares[0] += pot - shares.reduce(0, +)
        return shares + Array(repeating: 0, count: finishers - shares.count)
    }
}

enum NetPhase: Equatable {
    case lobby
    /// Every racer is building the circuit. The countdown starts once they all say they're
    /// done (or `deadline` passes), so a slow device doesn't lose the start.
    case loading(deadline: Double)
    /// Everyone runs 3-2-1 against the same server clock; GO is `start`.
    case countdown(start: Double)
    case racing(start: Double)
    case results

    var description: String {
        switch self {
        case .lobby: return "Lobby"
        case .loading, .countdown, .racing: return "Racing"
        case .results: return "Results"
        }
    }
}

// MARK: - Constants

enum NetProtocol {
    /// Bump on any wire change; a guest on another version is turned away at join.
    static let version: UInt16 = 2
    static let port: UInt16 = 27911
    static let serviceType = "_arcline._udp"
    static let tickRate = 30.0
    static let maxCars = 8
    static let maxLoadout = 400
    static let maxName = 24
    /// Seconds without a packet before the other side is given up on.
    static let timeout = 8.0
    static let countdown = 4.0
    /// Longest the server waits for every racer to load the circuit.
    static let loadTimeout = 30.0
    /// After the first human finishes, the rest have this long before they're DNF.
    static let finishGrace = 30.0
}

// MARK: - Messages

/// Client to server. Reliable unless noted.
enum ClientMsg: UInt8 {
    case join = 1           // u16 version, string name, blob loadout
    case ready              // bool
    case settings           // settings (host)
    case addBot             // string name, blob loadout (host)
    case removeBot          // u8 car (host)
    case start              // (host)
    case finish             // u8 car, f32 race time
    case leave              // unreliable, sent three times
    case returnToLobby      // (host)
    case states             // unreliable: f64 stamp (server clock), u8 n, n × (u8 car, state)
    case ping               // unreliable: f64 client clock
    case loadout            // blob: replaces the sender's own car's loadout
    case kick               // u8 car: removes its owner (host)
    case loaded             // the circuit is built; ready for the countdown
}

/// Server to client. Reliable unless noted.
enum ServerMsg: UInt8 {
    case accept = 1         // u8 client id, u8 own car, f64 server time, string server name
    case disconnect         // string reason; unreliable, sent three times
    case roster             // u8 n, n × (u8 id, u8 owner, u8 flags, string name)
    case loadout            // u8 car, blob
    case settings           // settings
    case phase              // u8 kind, f64 start
    case finish             // u8 car, f32 time
    case results            // u8 n, n × (u8 car, f32 time or NaN, i32 payout)
    case snapshot           // unreliable: f64 server time, u8 n, n × (u8 car, f32 age, state)
    case pong               // unreliable: f64 echoed client clock, f64 server time
}

/// Connectionless, after the 0xFFFFFFFF marker.
enum OutOfBandMsg: UInt8 {
    case infoRequest = 1    // u16 version
    case infoResponse       // u16 version, string name, u8 cars, u8 max, u8 phase kind, settings
}

// MARK: - Encoding

extension NetCarState {
    /// 32 bytes: full-precision position and progress (they are what the eye and the race
    /// order are most sensitive to), 16-bit orientation and velocity, 8-bit steer.
    func write(to w: inout MsgWriter) {
        w.vec3(position)
        var q = simd_normalize(orientation.vector)
        if q.w < 0 { q = -q }
        for i in 0..<4 { w.i16(Self.fixed(q[i], 32767)) }
        for i in 0..<3 { w.i16(Self.fixed(velocity[i], 50)) }
        w.f32(progress)
        w.i8(Int8(clamping: Self.fixed(steer, 127)))
        w.u8(boosting ? 1 : 0)
    }

    /// Fixed point, saturating; NaN (a physics blow-up) goes out as zero rather than trapping.
    private static func fixed(_ x: Float, _ scale: Float) -> Int16 {
        let v = (x * scale).rounded()
        return v.isFinite ? Int16(max(-32767, min(32767, v))) : 0
    }

    init(from r: inout MsgReader) {
        position = r.vec3()
        var q = SIMD4<Float>()
        for i in 0..<4 { q[i] = Float(r.i16()) / 32767 }
        orientation = simd_length(q) > 0.5 ? simd_quatf(vector: simd_normalize(q)) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        for i in 0..<3 { velocity[i] = Float(r.i16()) / 50 }
        progress = r.f32()
        steer = Float(r.i8()) / 127
        boosting = r.u8() & 1 != 0
    }
}

extension MatchSettings {
    func write(to w: inout MsgWriter) {
        w.u16(UInt16(clamping: trackIndex))
        w.u64(trackSeed)
        w.u8(UInt8(clamping: laps))
        w.u32(UInt32(clamping: stake))
    }

    init(from r: inout MsgReader) {
        trackIndex = Int(r.u16())
        trackSeed = r.u64()
        laps = Int(r.u8())
        stake = Int(r.u32())
    }
}

extension NetPhase {
    func write(to w: inout MsgWriter) {
        switch self {
        case .lobby: w.u8(0); w.f64(0)
        case .countdown(let start): w.u8(1); w.f64(start)
        case .racing(let start): w.u8(2); w.f64(start)
        case .results: w.u8(3); w.f64(0)
        case .loading(let deadline): w.u8(4); w.f64(deadline)
        }
    }

    init(from r: inout MsgReader) {
        let kind = r.u8(), start = r.f64()
        switch kind {
        case 1: self = .countdown(start: start)
        case 2: self = .racing(start: start)
        case 3: self = .results
        case 4: self = .loading(deadline: start)
        default: self = .lobby
        }
    }
}

extension MsgWriter {
    /// A framed message as standalone data, ready to queue or append.
    static func message(_ type: UInt8, _ body: (inout MsgWriter) -> Void = { _ in }) -> Data {
        var w = MsgWriter()
        w.message(type, body)
        return w.data
    }
}
