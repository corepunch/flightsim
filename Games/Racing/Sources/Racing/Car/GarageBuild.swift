import Foundation
import simd

enum CarSlot: String, Codable, CaseIterable {
    case frame, front, rear, motor, wheels, splitter, wing

    static let primary: [Self] = [.frame, .front, .rear, .motor, .wheels]

    var title: String { rawValue.uppercased() }

    var parent: Self? {
        switch self {
        case .splitter: return .front
        case .wing: return .rear
        default: return nil
        }
    }

    var factoryPaint: GaragePaint {
        switch self {
        case .frame: return GaragePaint(0x42BBD5)
        case .front: return GaragePaint(0xC6DAE9)
        case .rear: return GaragePaint(0x777FBA)
        case .motor: return GaragePaint(0xE59253)
        case .wheels: return GaragePaint(0xC8CEDC)
        case .splitter: return GaragePaint(0x9C9CE9)
        case .wing: return GaragePaint(0xEC4B91)
        }
    }
}

enum WheelPosition: String, Codable, CaseIterable {
    case frontLeft = "FL", frontRight = "FR", rearLeft = "RL", rearRight = "RR"

    var isFront: Bool { self == .frontLeft || self == .frontRight }
    var side: Float { self == .frontLeft || self == .rearLeft ? -1 : 1 }
}

struct GaragePaint: Codable, Equatable {
    let hex: UInt32

    init(_ hex: UInt32) { self.hex = hex }

    init(rgb: SIMD3<Float>) {
        let c = simd_clamp(rgb, .zero, SIMD3(repeating: 1)) * 255
        hex = UInt32(c.x.rounded()) << 16 | UInt32(c.y.rounded()) << 8 | UInt32(c.z.rounded())
    }

    var rgb: SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 255), Float((hex >> 8) & 255), Float(hex & 255)) / 255
    }
}

/// Stable identifiers keep saved builds independent of the order of the catalog.
enum CarPart: String, Codable, CaseIterable {
    case sprint, vector, atlas
    case needle, plow, fork
    case cutTail, flightDeck, twinTail
    case pulse, twinJet, reactor
    case slick, aero, wideTrack
    case blade, divePlanes
    case bridge, doubleDeck

    var slot: CarSlot {
        switch self {
        case .sprint, .vector, .atlas: return .frame
        case .needle, .plow, .fork: return .front
        case .cutTail, .flightDeck, .twinTail: return .rear
        case .pulse, .twinJet, .reactor: return .motor
        case .slick, .aero, .wideTrack: return .wheels
        case .blade, .divePlanes: return .splitter
        case .bridge, .doubleDeck: return .wing
        }
    }

    var title: String {
        switch self {
        case .sprint: return "Sprint"
        case .vector: return "Vector"
        case .atlas: return "Atlas"
        case .needle: return "Needle"
        case .plow: return "Plow"
        case .fork: return "Fork"
        case .cutTail: return "Cut Tail"
        case .flightDeck: return "Flight Deck"
        case .twinTail: return "Twin Tail"
        case .pulse: return "Pulse"
        case .twinJet: return "Twin Jet"
        case .reactor: return "Reactor"
        case .slick: return "Slick"
        case .aero: return "Aero"
        case .wideTrack: return "Wide Track"
        case .blade: return "Blade"
        case .divePlanes: return "Dive Planes"
        case .bridge: return "Bridge"
        case .doubleDeck: return "Double Deck"
        }
    }

    var attachment: CarSlot? {
        switch self {
        case .plow, .fork: return .splitter
        case .flightDeck, .twinTail: return .wing
        default: return nil
        }
    }
}

struct GarageBuild: Codable, Equatable {
    private static let defaultsKey = "garage.build.v1"
    private static let starter: [CarSlot: CarPart] = [
        .frame: .sprint, .front: .needle, .rear: .cutTail, .motor: .pulse, .wheels: .slick,
    ]

    private var parts: [CarSlot: CarPart] = [:]
    private var paints: [CarSlot: GaragePaint] = [:]
    private var wheelPaints: [WheelPosition: GaragePaint] = [:]

    func part(at slot: CarSlot) -> CarPart? {
        if let parent = slot.parent, part(at: parent)?.attachment != slot { return nil }
        guard let part = parts[slot], part.slot == slot else { return Self.starter[slot] }
        return part
    }

    mutating func equip(_ part: CarPart?, at slot: CarSlot) {
        if let part {
            guard part.slot == slot else { return }
            if let parent = slot.parent, self.part(at: parent)?.attachment != slot { return }
        }
        parts[slot] = part
        for child in CarSlot.allCases where child.parent == slot && self.part(at: slot)?.attachment != child {
            parts[child] = nil
        }
    }

    func paint(for slot: CarSlot, wheel: WheelPosition? = nil) -> GaragePaint {
        if slot == .wheels, let wheel, let paint = wheelPaints[wheel] { return paint }
        return paints[slot] ?? slot.factoryPaint
    }

    mutating func paint(_ color: GaragePaint, at slot: CarSlot, wheel: WheelPosition? = nil) {
        if slot == .wheels {
            if let wheel {
                wheelPaints[wheel] = color
                return
            }
            wheelPaints.removeAll()
        }
        paints[slot] = color
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let setup = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return setup
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// The same dimensions drive the visible parts, wheel placement and collisions.
struct GarageDimensions {
    let axle: Float
    let bodyWidth: Float
    let deckHeight: Float
    let track: Float
    let frontRadius: Float
    let rearRadius: Float
    let tyreWidth: Float
    let frontExtent: Float
    let rearExtent: Float
    let bodyHalfWidth: Float
    let spec: CarSpec

    var end: Float { axle + 0.23 }

    init(_ build: GarageBuild) {
        let frame: (axle: Float, width: Float, deck: Float, track: Float, ratings: SIMD4<Float>)
        switch build.part(at: .frame) {
        case .atlas: frame = (1.77, 0.86, 0.67, 1.39, SIMD4(0.48, 0.47, 0.38, 0.79))
        case .vector: frame = (1.41, 0.72, 0.59, 1.17, SIMD4(0.51, 0.51, 0.52, 0.61))
        default: frame = (1.02, 0.54, 0.51, 0.94, SIMD4(0.48, 0.52, 0.68, 0.35))
        }
        let wheels: (front: Float, rear: Float, width: Float, offset: Float, ratings: SIMD4<Float>)
        switch build.part(at: .wheels) {
        case .wideTrack: wheels = (0.49, 0.55, 0.52, 0.17, SIMD4(-0.04, -0.03, 0.12, 0.04))
        case .aero: wheels = (0.39, 0.43, 0.33, 0.04, SIMD4(0.05, 0, -0.03, 0))
        default: wheels = (0.34, 0.37, 0.30, 0, .zero)
        }
        let front: (depth: Float, halfWidth: Float, armor: Float)
        switch build.part(at: .front) {
        case .plow: front = (0.72, 0.99, 0.11)
        case .fork: front = (0.87, 1.16, 0.07)
        default: front = (0.40, 0.54, 0)
        }
        let rear: (depth: Float, halfWidth: Float)
        switch build.part(at: .rear) {
        case .flightDeck: rear = (0.76, 1.04)
        case .twinTail: rear = (0.86, 1.14)
        default: rear = (0.39, 0.49)
        }
        let motor: SIMD4<Float>
        switch build.part(at: .motor) {
        case .reactor: motor = SIMD4(0.23, 0.11, -0.06, 0)
        case .twinJet: motor = SIMD4(0.11, 0.18, 0, 0)
        default: motor = .zero
        }
        let splitter = build.part(at: .splitter)
        let wing = build.part(at: .wing)
        axle = frame.axle
        bodyWidth = frame.width
        deckHeight = frame.deck
        track = frame.track + wheels.offset
        frontRadius = wheels.front
        rearRadius = wheels.rear
        tyreWidth = wheels.width
        frontExtent = frame.axle + 0.23 + front.depth + (splitter == nil ? 0 : 0.27)
        rearExtent = frame.axle + 0.23 + rear.depth + (wing == .doubleDeck ? 0.09 : 0)
        bodyHalfWidth = max(front.halfWidth, rear.halfWidth,
                            splitter == .divePlanes ? 1.27 : 0,
                            wing == .doubleDeck ? 1.31 : 0)
        let aero = SIMD4<Float>(wing == .doubleDeck ? -0.025 : 0, 0,
                                (splitter == nil ? 0 : 0.045) + (wing == nil ? 0 : 0.065), front.armor)
        let ratings = frame.ratings + wheels.ratings + motor + aero
        spec = CarSpec(ratings: (0..<4).map { min(1, max(0, ratings[$0])) })
    }
}
