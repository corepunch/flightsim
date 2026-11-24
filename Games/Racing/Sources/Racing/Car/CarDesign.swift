import Foundation
import simd

/// What a car can do. Everything the physics needs, plus 0...1 ratings for the menu bars.
struct CarSpec {
    /// Flat-out speed in m/s.
    var topSpeed: Float
    /// Drive acceleration from rest in m/s².
    var thrust: Float
    /// Front-wheel lock at a standstill, in radians.
    var steeringLock: Float
    /// Tyre grip (the wheels' friction slip).
    var grip: Float
    /// 0...1: how slippery the bodywork is against barriers. Armoured cars glance off and keep their speed.
    var armor: Float

    /// Menu ratings in the order of `CarSpec.statNames`.
    var ratings: [Float]
    static let statNames = ["SPEED", "THRUST", "AGILITY", "ARMOR"]

    init(ratings r: [Float]) {
        ratings = r
        topSpeed = 84 + 20 * r[0]
        thrust = 15 + 8 * r[1]
        steeringLock = 0.46 + 0.16 * r[2]
        grip = 4.8 + 1.5 * r[2]
        armor = r[3]
    }
}

/// A complete car: its numbers, the parts and paint it is built from, and what it wears.
/// Every car is a garage build. The player puts their own together; a generated car is one
/// its maker built to suit its ratings, so form follows function: an armoured car gets the
/// heavy frame and a plough, a strong one more engine and fat tyres, an agile one wings.
struct CarDesign {
    let seed: UInt64
    var name: String
    let className: String
    /// Who built it: lettered on the bodywork, with the race number.
    let maker: String
    let number: Int
    var spec: CarSpec
    let build: GarageBuild
    private let dimensions: GarageDimensions
    /// The racing graphics a maker gives its car, in its second colour. A player's own build
    /// has none of its own and takes its frame's, in a shade that reads on its paint.
    let livery: (style: Int, color: SIMD3<Float>)?

    let primary: SIMD3<Float>
    let accent: SIMD3<Float>
    let glow: SIMD3<Float>

    /// Overall half-width including the tyres.
    var halfWidth: Float { max(dimensions.track + dimensions.tyreWidth / 2, dimensions.bodyHalfWidth) }
    var axle: Float { dimensions.axle }
    var frontCollisionExtent: Float { dimensions.frontExtent }
    var rearCollisionExtent: Float { dimensions.rearExtent }
    var length: Float { dimensions.frontExtent + dimensions.rearExtent }

    init(garage: GarageBuild) {
        build = garage
        dimensions = GarageDimensions(garage)
        seed = 0
        name = "MY RACER"
        maker = (garage.part(at: .frame)?.title ?? "Sprint").uppercased()
        className = maker + " FRAME"
        // A number that belongs to the build: the same parts always carry the same one.
        let parts = CarSlot.allCases.compactMap { garage.part(at: $0)?.rawValue }.joined()
        number = 2 + parts.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 98 }
        spec = dimensions.spec
        livery = nil
        primary = garage.paint(for: .frame).rgb
        accent = garage.paint(for: .front).rgb
        glow = SIMD3(0.28, 0.90, 1)
    }

    /// `focus` picks the stat the car leans on, so a roster covers every style.
    init(seed: UInt64, focus: Int, hue: Float, budget: Float = 2.3) {
        self.seed = seed
        var rng = SplitMix64(seed: seed &* 0x9E3779B97F4A7C15 &+ 0xD1B54A32)

        // Stats: random, pulled towards the focus, then scaled to a common budget.
        var raw = (0..<4).map { _ in rng.float(0.25...0.75) }
        raw[focus % 4] += rng.float(0.45...0.6)
        raw[(focus + 1 + Int.random(in: 0...2, using: &rng)) % 4] -= 0.12
        let sum = raw.reduce(0, +)
        var ratings = raw.map { max(0.12, min(1, $0 * budget / sum)) }
        // Whatever clipping lost goes back to the weakest stat.
        let lost = budget - ratings.reduce(0, +)
        if lost > 0, let weakest = ratings.indices.min(by: { ratings[$0] < ratings[$1] }) {
            ratings[weakest] = min(1, ratings[weakest] + lost)
        }
        spec = CarSpec(ratings: ratings)
        let (speed, thrust, agility, armor) = (ratings[0], ratings[1], ratings[2], ratings[3])

        // The parts follow the ratings, each measured against the car's own average so that a
        // cheap car and a dear one are read the same way. Where they have no opinion, the seed decides.
        let tail = Int.random(in: 0..<3, using: &rng)
        let (nose, rims, lip, aero) = (rng.float(), rng.float(), rng.float(), rng.float())
        let mean = ratings.reduce(0, +) / 4
        let (fast, strong, agile, tough) = (speed / mean, thrust / mean, agility / mean, armor / mean)
        var parts = GarageBuild()
        // Where a car is both agile and tough, the stronger trait picks its frame and nose.
        let nimble = agile > 1.1 && agile > tough
        parts.equip(nimble || tough < 0.75 ? .sprint : (tough > 1.15 ? .atlas : .vector), at: .frame)
        parts.equip(strong > 1.25 ? .reactor : (strong > 0.9 ? .twinJet : .pulse), at: .motor)
        parts.equip(strong > 1.2 ? .wideTrack : (fast > 1.05 || rims > 0.6 ? .aero : .slick), at: .wheels)
        parts.equip(nimble ? .fork : (tough > 1.2 ? .plow : (nose < 0.5 ? .needle : (nose < 0.8 ? .fork : .plow))),
                    at: .front)
        parts.equip(tail == 2 ? .twinTail : (tail == 1 || agile > 1.1 ? .flightDeck : .cutTail), at: .rear)
        // Wings and splitters only fit the parts with mounts for them; `equip` ignores the rest.
        parts.equip(agile > 1.25 ? .doubleDeck : (agile > 0.95 || aero > 0.6 ? .bridge : nil), at: .wing)
        parts.equip(fast > 1.15 ? .blade : (agile > 1.15 ? .divePlanes : (lip > 0.7 ? .blade : nil)), at: .splitter)

        primary = Self.hsv(hue, rng.float(0.72...0.92), rng.float(0.85...1))
        let accentHue = hue + (rng.float() < 0.5 ? 0.5 : 0.08) + rng.float(-0.04...0.04)
        accent = rng.float() < 0.4 ? SIMD3(0.92, 0.94, 0.98) : Self.hsv(accentHue, 0.7, 1)
        glow = Self.hsv(hue + rng.float(0.42...0.58), 0.75, 1)

        // Team colours: the body in one, the wings, rims and engine in the other.
        for slot in CarSlot.allCases {
            let body = slot == .frame || slot == .front || slot == .rear
            parts.paint(GaragePaint(rgb: body ? primary : accent), at: slot)
        }
        build = parts
        dimensions = GarageDimensions(parts)
        livery = (Int(seed % UInt64(ProceduralTextures.carLiveryStyles)), accent)

        // A maker for each character and a model from that maker's range.
        let strongest = ratings.indices.max(by: { ratings[$0] < ratings[$1] }) ?? 0
        className = ["INTERCEPTOR", "DRAGSTER", "SLIDER", "BRUISER"][strongest]
        let range = Self.models[strongest]
        maker = Self.makers[strongest]
        name = "\(maker) \(range[Int.random(in: 0..<range.count, using: &rng)])"
        number = Int.random(in: 2...99, using: &rng)
    }

    /// Who builds each class of car, in the order of `CarSpec.statNames`.
    private static let makers = ["VANTA", "KORR", "LYRA", "BRUNT"]
    private static let models = [
        ["COMET", "JAVELIN", "MERIDIAN", "ZEPHYR", "MISTRAL", "TRACER", "AURORA", "PHOTON"],
        ["SURGE", "RAMJET", "TORQUE", "FURNACE", "STAMPEDE", "DYNAMO", "HOWL", "PISTON"],
        ["KITE", "DART", "WISP", "SWALLOW", "HAIRPIN", "RIBBON", "MANTIS", "FERRET"],
        ["BULWARK", "RAMPART", "MASTIFF", "IRONSIDE", "CITADEL", "BOULDER", "RHINO", "GRANITE"],
    ]

    private static func hsv(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let hue = (h - h.rounded(.down)) * 6
        let i = Int(hue), f = hue - Float(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i % 6 {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }
}

enum CarRoster {
    /// Six cars: one specialist per stat and two wildcards, hues spread round the wheel.
    static let all: [CarDesign] = (0..<6).map { i in
        CarDesign(seed: UInt64(101 + i * 37), focus: i, hue: Float(i) * 0.618 + 0.52)
    }
}
