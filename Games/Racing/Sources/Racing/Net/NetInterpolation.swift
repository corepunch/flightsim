import Foundation
import simd

struct RemoteCarSample {
    let state: NetCarState
    let allowsCollision: Bool
}

/// A remote car's recent poses on the server clock. Remote cars are drawn a little in
/// the past (`RaceClient.interpolationDelay`) so there are nearly always two real samples
/// to blend between; positions use a cubic Hermite through both positions and velocities,
/// which keeps fast cars on their arc where a straight lerp would cut corners.
struct SnapshotBuffer {
    /// How far past the newest sample a car is carried on its velocity before it holds.
    static let maxExtrapolation = 0.25
    private static let history = 1.0

    private(set) var samples: [(time: Double, state: NetCarState)] = []

    var newestTime: Double? { samples.last?.time }

    mutating func insert(_ state: NetCarState, at time: Double) {
        if let last = samples.last {
            guard time > last.time else { return }   // already have it
            // A respawn or a new grid: blending across it would sweep the car through
            // the scenery, so start over.
            let dt = Float(time - last.time)
            let reach = max(simd_length(state.velocity), simd_length(last.state.velocity)) * dt * 1.5 + 3
            if dt > 1 || simd_distance(state.position, last.state.position) > reach { samples.removeAll() }
        }
        samples.append((time, state))
        while samples.count > 2, let first = samples.first, time - first.time > Self.history { samples.removeFirst() }
    }

    /// A held pose remains visible after extrapolation stops, but it is no
    /// longer safe to use as a solid obstacle in another player's race.
    func remoteSample(at t: Double) -> RemoteCarSample? {
        guard let newestTime, let state = sample(at: t) else { return nil }
        return RemoteCarSample(state: state, allowsCollision: t - newestTime <= Self.maxExtrapolation)
    }

    func sample(at t: Double) -> NetCarState? {
        guard let newest = samples.last, let oldest = samples.first else { return nil }
        if t >= newest.time {
            var s = newest.state
            s.position += s.velocity * Float(min(t - newest.time, Self.maxExtrapolation))
            return s
        }
        if t <= oldest.time { return oldest.state }

        var i = samples.count - 1
        while i > 1, samples[i - 1].time > t { i -= 1 }
        let a = samples[i - 1], b = samples[i]
        let span = Float(b.time - a.time)
        let u = Float((t - a.time) / (b.time - a.time))
        let u2 = u * u, u3 = u2 * u
        let h00 = 2 * u3 - 3 * u2 + 1, h10 = u3 - 2 * u2 + u
        let h01 = -2 * u3 + 3 * u2, h11 = u3 - u2

        var s = a.state
        s.position = h00 * a.state.position + h10 * span * a.state.velocity
                   + h01 * b.state.position + h11 * span * b.state.velocity
        s.velocity = simd_mix(a.state.velocity, b.state.velocity, SIMD3(repeating: u))
        s.orientation = simd_slerp(a.state.orientation, b.state.orientation, u)
        s.progress = a.state.progress + (b.state.progress - a.state.progress) * u
        s.steer = a.state.steer + (b.state.steer - a.state.steer) * u
        s.boosting = u < 0.5 ? a.state.boosting : b.state.boosting
        return s
    }
}

/// Estimates server time from ping/pong pairs. The sample with the lowest round trip in
/// the recent window has the least queueing in it, so its half-RTT guess is the most
/// honest; the offset eases towards it so the clock never visibly jumps.
struct ClockSync {
    private var samples: [(rtt: Double, offset: Double)] = []
    /// server time − local monotonic time.
    private(set) var offset: Double = 0
    /// Smoothed round trip, seconds.
    private(set) var rtt: Double = 0
    private(set) var synced = false

    /// A first rough guess (from the accept message) until real samples arrive.
    mutating func seed(serverTime: Double, localTime: Double) {
        if !synced { offset = serverTime - localTime }
    }

    mutating func add(sent: Double, serverTime: Double, received: Double) {
        let roundTrip = max(0, received - sent)
        samples.append((roundTrip, serverTime + roundTrip / 2 - received))
        if samples.count > 16 { samples.removeFirst() }
        let best = samples.min { $0.rtt < $1.rtt }!
        if synced {
            offset += (best.offset - offset) * 0.25
            rtt += (roundTrip - rtt) * 0.2
        } else {
            offset = best.offset
            rtt = roundTrip
            synced = true
        }
    }
}
