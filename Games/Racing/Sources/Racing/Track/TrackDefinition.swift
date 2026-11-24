import UIKit
import simd

/// One distortion of the master curve. The curve starts as a flat circle of control
/// points; radial deformers (`lobes`, `pinch`) and `hills` are evaluated per point,
/// then the cartesian ones (`stretch`, `shear`, `warp`) are applied in list order.
enum CurveDeformer {
    /// Sinusoidal radius modulation: `count` bulges, `amount` as a fraction of the radius.
    case lobes(count: Int, amount: Float, phase: Float)
    /// Pulls the ring towards the centre around `angle` (radians), making a tight inward bend.
    case pinch(angle: Float, amount: Float, width: Float)
    /// Height wave in metres, `count` crests per lap.
    case hills(count: Int, height: Float, phase: Float)
    /// Random radius per control point, as a fraction of the radius: irregular corners.
    case jitter(amount: Float, seed: UInt64)
    case stretch(x: Float, z: Float)
    case shear(Float)
    /// Smooth noise displacement in metres; `scale` is the feature size.
    case warp(amount: Float, scale: Float, seed: UInt64)
}

/// The closed master curve everything is built from: the road is swept along it and
/// the city, pylons and gates are placed in its (distance, lateral, height) frame.
struct TrackCurve {
    var radius: Float = 330
    var pointCount = 48
    var altitude: Float = 0
    /// When set, the control ring is a polygon of corners joined by straights: each corner
    /// is rounded over this fraction of its shorter adjoining edge. `nil` gives a flowing spline.
    var cornerCut: Float? = nil
    /// Explicit corner polygon (flat); replaces the deformed circle when set.
    var corners: [SIMD3<Float>]? = nil
    var deformers: [CurveDeformer]

    func controlPoints() -> [SIMD3<Float>] {
        let ring = ringPoints()
        guard let cut = cornerCut else { return ring }

        // Straights between corners, each corner a quadratic arc through the polygon vertex.
        let n = ring.count
        let spacing: Float = 30
        var path: [SIMD3<Float>] = []
        func corner(_ i: Int) -> (entry: SIMD3<Float>, exit: SIMD3<Float>) {
            let p = ring[i], a = ring[(i - 1 + n) % n], b = ring[(i + 1) % n]
            let d = min(cut * min(simd_distance(a, p), simd_distance(p, b)), 170)
            return (p + simd_normalize(a - p) * d, p + simd_normalize(b - p) * d)
        }
        var longest: (start: Int, count: Int, length: Float) = (0, 0, 0)
        for i in 0..<n {
            let (entry, exit) = corner(i)
            let steps = max(4, Int((simd_distance(entry, ring[i]) + simd_distance(ring[i], exit)) / spacing))
            for k in 0..<steps {
                let t = Float(k) / Float(steps), u = 1 - t
                path.append(entry * (u * u) + ring[i] * (2 * u * t) + exit * (t * t))
            }
            let next = corner((i + 1) % n).entry
            let length = simd_distance(exit, next)
            let straight = max(1, Int(length / spacing))
            if length > longest.length { longest = (path.count, straight, length) }
            for k in 0..<straight { path.append(exit + (next - exit) * (Float(k) / Float(straight))) }
        }
        // Start a third of the way down the longest straight.
        let first = longest.start + longest.count / 3
        path = Array(path[first...] + path[..<first])

        // An explicit polygon is flat: hills follow the distance round the lap instead.
        if corners != nil {
            for (i, p) in path.enumerated() {
                let a = Float(i) / Float(path.count) * 2 * .pi
                var y = p.y
                for case let .hills(count, height, phase) in deformers { y += height * sin(Float(count) * a + phase) }
                path[i].y = y
            }
        }
        return path
    }

    /// True when no two distant parts of the lap come close enough to touch.
    func isClear(gap: Float = 75) -> Bool {
        let path = controlPoints()
        let n = path.count
        for i in 0..<n {
            for j in (i + 1)..<n where min(j - i, n - (j - i)) > 7 {
                let d = SIMD2(path[i].x - path[j].x, path[i].z - path[j].z)
                if simd_length_squared(d) < gap * gap { return false }
            }
        }
        return true
    }

    private func ringPoints() -> [SIMD3<Float>] {
        var jitters: [Int: Float] = [:]
        for case let .jitter(amount, seed) in deformers {
            var rng = SplitMix64(seed: seed)
            for i in 0..<pointCount { jitters[i, default: 0] += rng.float(-1...1) * amount }
        }
        var points = corners ?? (0..<pointCount).map { i -> SIMD3<Float> in
            let a = Float(i) / Float(pointCount) * 2 * .pi
            var r = radius * (1 + (jitters[i] ?? 0))
            var y = altitude
            for deformer in deformers {
                switch deformer {
                case let .lobes(count, amount, phase):
                    r += radius * amount * sin(Float(count) * a + phase)
                case let .pinch(angle, amount, width):
                    let d = remainder(a - angle, 2 * .pi)
                    r -= radius * amount * exp(-(d * d) / (2 * width * width))
                case let .hills(count, height, phase):
                    y += height * sin(Float(count) * a + phase)   // unused for explicit corners
                case .stretch, .shear, .warp, .jitter:
                    break
                }
            }
            return SIMD3(cos(a) * r, y, sin(a) * r)
        }
        for deformer in deformers {
            switch deformer {
            case let .stretch(x, z):
                points = points.map { SIMD3($0.x * x, $0.y, $0.z * z) }
            case let .shear(k):
                points = points.map { SIMD3($0.x + $0.z * k, $0.y, $0.z) }
            case let .warp(amount, scale, seed):
                let noise = Noise2D(seed: seed)
                points = points.map { p in
                    let dx = noise.fbm(p.x / scale, p.z / scale, octaves: 2)
                    let dz = noise.fbm(p.x / scale + 37.3, p.z / scale - 11.9, octaves: 2)
                    return SIMD3(p.x + dx * amount * 2, p.y, p.z + dz * amount * 2)
                }
            case .lobes, .pinch, .hills, .jitter:
                break
            }
        }
        return points
    }

    /// A street circuit: a few very long straights round an elongated polygon, broken up
    /// by chicane kinks, inward bays and outward hairpin lobes, over big changes of height.
    static func circuit(seed: UInt64) -> TrackCurve {
        for attempt in 0..<24 {
            let curve = makeCircuit(seed: seed &+ UInt64(attempt) &* 1009, features: true)
            if curve.isClear() { return curve }
        }
        return makeCircuit(seed: seed, features: false)
    }

    private static func makeCircuit(seed: UInt64, features: Bool) -> TrackCurve {
        var rng = SplitMix64(seed: seed &* 2654435761 &+ 17)
        let count = Int.random(in: 5...7, using: &rng)
        let axes = SIMD2<Float>(rng.float(620...820), rng.float(360...500))
        let turn = rng.float(0...(2 * .pi))
        let base = (0..<count).map { i -> SIMD2<Float> in
            let a = (Float(i) + rng.float(-0.28...0.28)) / Float(count) * 2 * .pi
            let r = rng.float(0.85...1.15)
            let p = SIMD2(cos(a) * axes.x * r, sin(a) * axes.y * r)
            return SIMD2(p.x * cos(turn) - p.y * sin(turn), p.x * sin(turn) + p.y * cos(turn))
        }
        let centre = base.reduce(SIMD2<Float>.zero, +) / Float(count)

        var corners: [SIMD2<Float>] = []
        for i in 0..<count {
            let a = base[i], b = base[(i + 1) % count]
            corners.append(a)
            let length = simd_distance(a, b)
            let along = (b - a) / length
            let mid = (a + b) / 2
            var inward = SIMD2(-along.y, along.x)
            if simd_dot(inward, centre - mid) < 0 { inward = -inward }
            let roll = rng.float()
            let at = a + along * (length * rng.float(0.4...0.6))
            guard features, length > 420, roll > 0.25 else { continue }
            if roll < 0.5 {
                // Chicane: a short sideways kink in the straight.
                let half = rng.float(75...110), offset = rng.float(35...60) * (rng.float() < 0.5 ? -1 : 1)
                corners += [at - along * half, at + inward * offset, at + along * half]
            } else {
                // Bay (inward) or lobe (outward): a detour off the straight with a hairpin feel.
                let outward = roll > 0.78
                let width = min(rng.float(190...290), length * 0.42)
                var depth = rng.float(150...250)
                if !outward { depth = min(depth, simd_distance(mid, centre) * 0.5) }
                guard depth > 120 else { continue }
                let normal = outward ? -inward : inward
                let taper = width * rng.float(0.05...0.2)
                let halfWidth: Float = width / 2
                let entrance: SIMD2<Float> = along * halfWidth
                let inner: SIMD2<Float> = along * (halfWidth - taper)
                let offset: SIMD2<Float> = normal * depth
                corners += [at - entrance, at - inner + offset, at + inner + offset, at + entrance]
            }
        }
        let hills: [CurveDeformer] = [
            .hills(count: 1, height: rng.float(24...42), phase: rng.float(0...(2 * .pi))),
            .hills(count: 2, height: rng.float(12...22), phase: rng.float(0...(2 * .pi))),
            .hills(count: 3, height: rng.float(4...10), phase: rng.float(0...(2 * .pi))),
        ]
        return TrackCurve(cornerCut: 0.42, corners: corners.map { SIMD3($0.x, 0, $0.y) }, deformers: hills)
    }

    /// A simpler loop: an irregular polygon of long straights and rounded corners,
    /// with one or two inward kinks and rolling height.
    static func random(seed: UInt64) -> TrackCurve {
        var rng = SplitMix64(seed: seed &* 7919 &+ 13)
        var deformers: [CurveDeformer] = [
            .lobes(count: Int.random(in: 2...3, using: &rng), amount: rng.float(0.12...0.22),
                   phase: rng.float(0...(2 * .pi))),
            .jitter(amount: rng.float(0.13...0.2), seed: seed &+ 7),
        ]
        for _ in 0..<Int.random(in: 1...2, using: &rng) {
            deformers.append(.pinch(angle: rng.float(0...(2 * .pi)), amount: rng.float(0.2...0.32),
                                    width: rng.float(0.25...0.4)))
        }
        deformers.append(.hills(count: 1, height: rng.float(16...28), phase: rng.float(0...(2 * .pi))))
        deformers.append(.hills(count: 2, height: rng.float(8...16), phase: rng.float(0...(2 * .pi))))
        deformers.append(.hills(count: 3, height: rng.float(3...8), phase: rng.float(0...(2 * .pi))))
        deformers.append(.stretch(x: rng.float(0.85...1.35), z: rng.float(0.85...1.2)))
        deformers.append(.shear(rng.float(-0.25...0.25)))
        return TrackCurve(radius: rng.float(480...560), pointCount: Int.random(in: 9...12, using: &rng),
                          cornerCut: rng.float(0.26...0.34), deformers: deformers)
    }
}

/// Colours that drive every generated texture, the sky and the lighting.
struct TrackTheme {
    /// How the outer strip of the deck is marked.
    enum Edge {
        /// Pale triangles pointing into the road.
        case sawtooth
        /// Long two-colour kerb blocks with a thin inner line.
        case kerb
    }
    var edge: Edge = .sawtooth
    var skyZenith: SIMD3<Float>
    var skyHorizon: SIMD3<Float>
    var skyGlow: SIMD3<Float>
    var stars: Float
    var fogStart: CGFloat = 140
    var fogEnd: CGFloat = 1100
    /// Primary and secondary emissive colours.
    var neonA: SIMD3<Float>
    var neonB: SIMD3<Float>
    /// Painted markings (arrows, edge lines, hazard stripes).
    var paint: SIMD3<Float>
    /// Asphalt of the road surface.
    var road = SIMD3<Float>(0.17, 0.17, 0.19)
    /// Barrier metal and the darker structural hull.
    var metal: SIMD3<Float>
    var hull: SIMD3<Float>
    var window: SIMD3<Float>
    /// How corroded the metalwork is, 0...1.
    var rust: Float = 0.5
    var sunColor: SIMD3<Float>
    var sunIntensity: CGFloat
    var sunAngles: SIMD2<Float>
    var ambient: CGFloat
    var environment: CGFloat

    /// Street races use the circuit's markings and scenery under a darker sky and a cooler key light.
    var streetNight: TrackTheme {
        var night = self
        night.skyZenith = SIMD3(0.052, 0.064, 0.11)
        night.skyHorizon = SIMD3(0.075, 0.104, 0.18)
        night.skyGlow = SIMD3(0.16, 0.24, 0.43)
        night.stars = 0.28
        night.fogStart = 110
        night.fogEnd = 850
        night.sunColor = SIMD3(0.77, 0.85, 1)
        night.sunIntensity = 975
        night.sunAngles.x = -.pi / 3
        night.ambient = 125
        night.environment = 0.75
        return night
    }

    static let neonNight = TrackTheme(
        edge: .kerb,
        skyZenith: SIMD3(0.015, 0.02, 0.07), skyHorizon: SIMD3(0.17, 0.07, 0.26),
        skyGlow: SIMD3(0.95, 0.25, 0.60), stars: 1,
        neonA: SIMD3(0.10, 0.90, 1.00), neonB: SIMD3(1.00, 0.15, 0.60),
        paint: SIMD3(0.78, 0.14, 0.14), metal: SIMD3(0.62, 0.66, 0.74), hull: SIMD3(0.20, 0.22, 0.28),
        window: SIMD3(1.00, 0.80, 0.50),
        sunColor: SIMD3(0.62, 0.70, 1.00), sunIntensity: 700, sunAngles: SIMD2(-.pi / 3.2, .pi / 5),
        ambient: 140, environment: 1.6)

    static let ember = TrackTheme(
        edge: .kerb,
        skyZenith: SIMD3(0.10, 0.09, 0.26), skyHorizon: SIMD3(0.78, 0.36, 0.20),
        skyGlow: SIMD3(1.00, 0.62, 0.18), stars: 0.3,
        neonA: SIMD3(1.00, 0.50, 0.08), neonB: SIMD3(0.10, 0.92, 0.78),
        paint: SIMD3(0.80, 0.16, 0.12), road: SIMD3(0.19, 0.17, 0.16),
        metal: SIMD3(0.72, 0.64, 0.57), hull: SIMD3(0.26, 0.21, 0.20),
        window: SIMD3(1.00, 0.70, 0.35), rust: 0.85,
        sunColor: SIMD3(1.00, 0.66, 0.40), sunIntensity: 1100, sunAngles: SIMD2(-.pi / 9, -.pi / 3),
        ambient: 220, environment: 1.3)

    static let cryo = TrackTheme(
        edge: .kerb,
        skyZenith: SIMD3(0.20, 0.42, 0.74), skyHorizon: SIMD3(0.74, 0.84, 0.93),
        skyGlow: SIMD3(1.00, 0.97, 0.90), stars: 0,
        fogStart: 220, fogEnd: 1300,
        neonA: SIMD3(0.15, 0.55, 1.00), neonB: SIMD3(1.00, 0.30, 0.08),
        paint: SIMD3(0.16, 0.25, 0.62), road: SIMD3(0.27, 0.28, 0.30),
        metal: SIMD3(0.82, 0.84, 0.88), hull: SIMD3(0.46, 0.50, 0.56),
        window: SIMD3(0.75, 0.90, 1.00), rust: 0.15,
        sunColor: SIMD3(1.00, 0.97, 0.92), sunIntensity: 1500, sunAngles: SIMD2(-.pi / 3.5, .pi / 6),
        ambient: 420, environment: 1.1)

    /// Yellow-green afterglow under a deep blue sky.
    static let acid = TrackTheme(
        skyZenith: SIMD3(0.03, 0.05, 0.30), skyHorizon: SIMD3(0.62, 0.66, 0.22),
        skyGlow: SIMD3(1.00, 0.95, 0.35), stars: 0.2,
        neonA: SIMD3(0.20, 0.85, 1.00), neonB: SIMD3(0.75, 0.30, 1.00),
        paint: SIMD3(0.92, 0.92, 0.92), road: SIMD3(0.16, 0.18, 0.21),
        metal: SIMD3(0.58, 0.62, 0.70), hull: SIMD3(0.16, 0.17, 0.24),
        window: SIMD3(1.00, 0.72, 0.35),
        sunColor: SIMD3(1.00, 0.95, 0.60), sunIntensity: 800, sunAngles: SIMD2(-.pi / 8, -.pi / 4),
        ambient: 240, environment: 1.4)

    static let all: [TrackTheme] = [.neonNight, .ember, .cryo, .acid]
}

/// A roofed stretch of the lap, given as lap fractions.
struct Enclosure {
    enum Kind {
        /// Tight tube just outside the barriers.
        case tunnel
        /// Tall, wide indoor hall with walkways either side of the road.
        case hall

        /// Clear space beyond the barrier, ceiling height and corner chamfer, in metres.
        var shape: (margin: Float, height: Float, chamfer: Float) {
            switch self {
            case .tunnel: return (1.2, 7.4, 2.4)
            case .hall: return (9, 15, 4.5)
            }
        }
    }

    var kind: Kind
    var start: Float
    var length: Float

    /// One tunnel and one hall, clear of the start line.
    static func random(seed: UInt64) -> [Enclosure] {
        var rng = SplitMix64(seed: seed &* 31 &+ 5)
        let tunnel = Enclosure(kind: .tunnel, start: rng.float(0.12...0.3), length: rng.float(0.07...0.11))
        let hall = Enclosure(kind: .hall, start: rng.float(0.52...0.76), length: rng.float(0.06...0.09))
        return rng.float() < 0.5 ? [tunnel, hall]
            : [Enclosure(kind: .hall, start: tunnel.start, length: hall.length),
               Enclosure(kind: .tunnel, start: hall.start, length: tunnel.length)]
    }
}

/// Everything about a circuit derives from this: the curve, the seed for textures
/// and city placement, and the theme.
struct TrackDefinition {
    var name: String
    var seed: UInt64
    var curve: TrackCurve
    var theme: TrackTheme
    /// Deck half-width in metres, and how far it swells and narrows along the lap.
    var halfWidth: Float = 10
    var widthVariation: Float = 2
    var banking: Float = 1
    /// Tunnels and halls; `nil` derives them from the seed.
    var enclosures: [Enclosure]? = nil
}

enum TrackLibrary {
    static let all: [TrackDefinition] = [
        TrackDefinition(name: "Neon Meridian", seed: 11, curve: .circuit(seed: 11), theme: .neonNight),
        TrackDefinition(name: "Ember Skyway", seed: 23, curve: .circuit(seed: 23), theme: .ember),
        TrackDefinition(name: "Cryo Loop", seed: 37, curve: .circuit(seed: 37), theme: .cryo),
        TrackDefinition(name: "Acid Spire", seed: 53, curve: .circuit(seed: 53), theme: .acid, banking: 1.3),
    ]

    /// Any seed gives a complete circuit: curve, city and textures.
    static func generated(seed: UInt64) -> TrackDefinition {
        TrackDefinition(name: "Sector \(seed)", seed: seed, curve: .circuit(seed: seed),
                        theme: TrackTheme.all[Int(seed % UInt64(TrackTheme.all.count))])
    }
}
