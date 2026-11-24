import Foundation
import simd

// Earn fixed race prizes and spend credits on cars, custom parts, and tuning.

enum RacePrizes {
    static func lan(position: Int, finished: Bool) -> Int {
        guard finished else { return 0 }
        switch position {
        case 1: return 900
        case 2: return 500
        case 3: return 300
        case 4...: return 150
        default: return 0
        }
    }
}

/// Performance index: the mean of a car's four ratings, ×1000. Classes cap it, so a
/// race is between comparable cars however much has been spent on them.
enum CarClass: Int, CaseIterable, Codable, Comparable {
    case d, c, b, a, s

    static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }

    /// Highest performance index allowed in this class.
    var cap: Int { [449, 529, 609, 689, 999][rawValue] }
    var letter: String { ["D", "C", "B", "A", "S"][rawValue] }
    var color: SIMD3<Float> {
        [SIMD3(0.62, 0.66, 0.74), SIMD3(0.35, 0.86, 0.52), SIMD3(0.18, 0.78, 1.0),
         SIMD3(0.70, 0.45, 1.0), SIMD3(1.0, 0.70, 0.18)][rawValue]
    }

    init(index: Int) { self = Self.allCases.first { index <= $0.cap } ?? .s }

    /// Stat budget (sum of the four ratings) that puts a generated car near the top of the class.
    var budget: Float { Float(cap - 25) * 4 / 1000 }
}

extension CarSpec {
    var index: Int { Int((ratings.reduce(0, +) / 4 * 1000).rounded()) }
    var carClass: CarClass { CarClass(index: index) }
}

/// The four performance upgrades, one per rating, five levels each.
enum UpgradeKind: Int, CaseIterable, Codable {
    case drive, core, grip, plating

    static let maxLevel = 5
    /// Rating added per level.
    static let step: Float = 0.04

    var title: String { ["MAG DRIVE", "ION CORE", "GRIP KIT", "PLATING"][rawValue] }
    var detail: String {
        ["Raises top speed", "Harder acceleration out of corners",
         "More cornering grip and steering lock", "Glances off barriers without losing speed"][rawValue]
    }
    var symbol: String { ["gauge.with.dots.needle.67percent", "bolt.fill", "circle.circle", "shield.lefthalf.filled"][rawValue] }
    /// Rating it improves, in `CarSpec.statNames` order (speed, thrust, agility, armor).
    var stat: Int { rawValue }

    /// Price of going from `level` to `level + 1`.
    func price(from level: Int) -> Int {
        let base = [1000, 900, 850, 700][rawValue]
        let curve: [Float] = [1, 1.8, 3, 4.8, 7.5]
        return Economy.round(Float(base) * curve[min(max(level, 0), curve.count - 1)])
    }
}

/// A generated car: everything `CarDesign(seed:focus:hue:budget:)` needs.
struct Blueprint: Codable, Equatable, Hashable {
    var seed: UInt64
    var focus: Int
    var hue: Float
    var budget: Float

    var design: CarDesign { CarDesign(seed: seed, focus: focus, hue: hue, budget: budget) }
}

/// What a car is made of: a generated model or the player's own build, plus upgrades.
/// This is also what goes over the network so other players see the same car.
struct Loadout: Codable, Equatable {
    var blueprint: Blueprint?
    var build: GarageBuild?
    var upgrades: [Int] = [0, 0, 0, 0]

    static func generated(_ blueprint: Blueprint) -> Self { Loadout(blueprint: blueprint) }
    static func custom(_ build: GarageBuild) -> Self { Loadout(build: build) }

    var baseDesign: CarDesign {
        if let build { return CarDesign(garage: build) }
        return (blueprint ?? Dealer.catalog[0].blueprint).design
    }

    /// The car as it races: upgrades on top of the base ratings.
    var design: CarDesign {
        var design = baseDesign
        var ratings = design.spec.ratings
        for kind in UpgradeKind.allCases {
            let level = upgrades.indices.contains(kind.rawValue) ? upgrades[kind.rawValue] : 0
            ratings[kind.stat] = min(1, ratings[kind.stat] + Float(level) * UpgradeKind.step)
        }
        design.spec = CarSpec(ratings: ratings)
        return design
    }

    func level(_ kind: UpgradeKind) -> Int { upgrades.indices.contains(kind.rawValue) ? upgrades[kind.rawValue] : 0 }

    /// Credits put into upgrades so far.
    var upgradeSpend: Int {
        UpgradeKind.allCases.reduce(0) { sum, kind in sum + (0..<level(kind)).reduce(0) { $0 + kind.price(from: $1) } }
    }

    /// What a dealer pays for it.
    var resale: Int {
        let base = build.map { Economy.buildValue($0) } ?? Economy.price(index: baseDesign.spec.index)
        return Economy.round(Float(base) * 0.55 + Float(upgradeSpend) * 0.4)
    }

    /// Deflated JSON: a fully painted custom build fits the 400 bytes a network loadout may use.
    func encoded() -> Data {
        guard let json = try? JSONEncoder().encode(self) else { return Data() }
        return (try? (json as NSData).compressed(using: .zlib) as Data) ?? json
    }

    static func decode(_ data: Data) -> Loadout? {
        let json = (try? (data as NSData).decompressed(using: .zlib) as Data) ?? data
        return try? JSONDecoder().decode(Self.self, from: json)
    }
}

enum Economy {
    static let startingCredits = 2_500

    /// Rounds a price to something a shop would ask.
    static func round(_ value: Float) -> Int {
        let step: Float = value < 2_000 ? 50 : (value < 20_000 ? 250 : 1_000)
        return max(Int(step), Int((value / step).rounded() * step))
    }

    /// Asking price for a generated car of this performance index: doubles every ~70 points.
    static func price(index: Int) -> Int {
        round(6_000 * exp(Float(index - 487) / 100))
    }

    /// Parts are what a self-built car is worth.
    static func buildValue(_ build: GarageBuild) -> Int {
        3_000 + CarSlot.allCases.compactMap { build.part(at: $0) }.reduce(0) { $0 + $1.price }
    }

    static func credits(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return "₵" + (f.string(from: NSNumber(value: n)) ?? "\(n)")
    }
}

extension CarPart {
    /// Starter parts come with the car.
    var price: Int {
        switch self {
        case .sprint, .needle, .cutTail, .pulse, .slick: return 0
        case .vector: return 2_500
        case .atlas: return 4_500
        case .plow: return 900
        case .fork: return 1_400
        case .flightDeck: return 1_000
        case .twinTail: return 1_600
        case .twinJet: return 2_200
        case .reactor: return 4_000
        case .aero: return 1_500
        case .wideTrack: return 2_000
        case .blade: return 600
        case .divePlanes: return 900
        case .bridge: return 700
        case .doubleDeck: return 1_200
        }
    }
}

// MARK: - Dealer

struct DealerCar {
    let blueprint: Blueprint
    var design: CarDesign { blueprint.design }
    var price: Int { Economy.price(index: design.spec.index) }
}

enum Dealer {
    /// Nine cars across classes C to S, every style represented in each tier.
    static let catalog: [DealerCar] = {
        let tiers: [(CarClass, Int)] = [(.c, 3), (.b, 3), (.a, 2), (.s, 1)]
        var cars: [DealerCar] = []
        var k = 0
        for (carClass, count) in tiers {
            for i in 0..<count {
                let blueprint = Blueprint(seed: UInt64(5_000 + k * 113), focus: (k + i) % 4,
                                          hue: Float(k) * 0.381 + 0.07, budget: carClass.budget)
                cars.append(DealerCar(blueprint: blueprint))
                k += 1
            }
        }
        return cars.sorted { $0.price < $1.price }
    }()
}

// MARK: - Circuit events

/// A sanctioned race: free entry, with fixed prizes for the podium.
struct CircuitEvent: Identifiable {
    let id: String
    let name: String
    let track: Int
    let carClass: CarClass
    let laps: Int
    let purse: Int
    /// Wins needed (any race) before the event opens.
    let winsToUnlock: Int
    let difficulty: Int

    /// Payout by finishing position (1-based).
    func payout(position: Int) -> Int {
        switch position {
        case 1: return purse
        case 2: return Economy.round(Float(purse) * 0.5)
        case 3: return Economy.round(Float(purse) * 0.25)
        default: return 0
        }
    }

    /// Rival cars, generated near the class cap so the event is a fair fight.
    var rivals: [(driver: String, design: CarDesign)] {
        (0..<5).map { i in
            let blueprint = Blueprint(seed: UInt64(abs(id.hashValueStable) % 10_000 + i * 97 + 1),
                                      focus: i % 4, hue: Float(i) * 0.618 + Float(track) * 0.2,
                                      budget: carClass.budget - 0.03 * Float(i))
            return (Drivers.name(Int(abs(id.hashValueStable) % 97) + i), blueprint.design)
        }
    }
}

enum Events {
    static let all: [CircuitEvent] = {
        let tiers: [(CarClass, laps: Int, purse: Int, wins: Int, difficulty: Int, names: [String])] = [
            (.c, 2, 1_500, 0, 0, ["NIGHT SHIFT", "FIRST LIGHT", "COLD START", "STREET LEGAL"]),
            (.b, 3, 4_500, 2, 1, ["NEON CUP", "SPARK SERIES", "HALO TROPHY", "RIDGE OPEN"]),
            (.a, 3, 10_000, 5, 2, ["VOLT GRAND PRIX", "AURORA CLASSIC", "IRON CROWN", "PULSE MASTERS"]),
            (.s, 4, 25_000, 9, 2, ["ARCLINE INVITATIONAL", "OMEGA RUN", "SUPERNOVA", "THE LONG NIGHT"]),
        ]
        var events: [CircuitEvent] = []
        for tier in tiers {
            for track in 0..<4 {
                events.append(CircuitEvent(id: "\(tier.0.letter)\(track)", name: tier.names[track], track: track,
                                        carClass: tier.0, laps: tier.laps,
                                        purse: tier.purse + track * tier.purse / 6,
                                        winsToUnlock: tier.wins + (track > 1 ? 1 : 0), difficulty: tier.difficulty))
            }
        }
        return events
    }()
}

// MARK: - Street challenges

/// A free head-to-head challenge on the street board.
struct Challenger {
    let driver: String
    let blueprint: Blueprint
    let track: Int
    let isKing: Bool
    var design: CarDesign { blueprint.design }

    /// Fixed event prize, not deducted from the rival or from the player.
    var victoryPrize: Int {
        isKing ? 50_000 : [500, 1_000, 2_000, 4_800, 12_000][design.spec.carClass.rawValue]
    }

}

enum Street {
    /// Wins before the King takes your call.
    static let winsForKing = 12

    /// Three challengers near the player's car, refreshed after every street race.
    static func board(round: Int, playerIndex: Int) -> [Challenger] {
        (0..<3).map { i in
            var rng = SplitMix64(seed: UInt64(round * 31 + i * 7 + 11))
            // One a little slower, one even, one a little quicker than the player's car.
            let index = Float(playerIndex) + Float(i - 1) * 22 + rng.float(-8...8)
            let budget = max(1.5, min(3.6, index * 4 / 1000))
            let blueprint = Blueprint(seed: rng.next() % 100_000, focus: Int(rng.next() % 4),
                                      hue: rng.float(), budget: budget)
            return Challenger(driver: Drivers.name(round * 3 + i + 40), blueprint: blueprint,
                              track: Int(rng.next() % 4), isKing: false)
        }
    }

    static let king = Challenger(driver: "THE KING", blueprint: Blueprint(seed: 1963, focus: 0, hue: 0.12, budget: 3.55),
                                 track: 1, isKing: true)
}

enum Drivers {
    private static let first = ["VEX", "NYLA", "KAI", "ROOK", "SABLE", "JUNO", "DASH", "ORIN", "MIRA", "TACE",
                                "LUX", "BRANDT", "ZERO", "IVY", "HOLT", "REX", "NOVA", "CASS", "FINCH", "YURI"]
    private static let last = ["KADE", "VOSS", "MERCER", "OKAFOR", "LINDQVIST", "SATO", "REYES", "HALE", "IBARRA",
                               "DRAKE", "MORROW", "QUILL", "STROM", "VANCE", "ACHE", "WOLFE", "PIKE"]

    static func name(_ i: Int) -> String {
        let n = abs(i)
        return first[n % first.count] + " " + last[(n * 7 + 3) % last.count]
    }
}

extension String {
    /// FNV-1a: stable across launches, unlike `hashValue`.
    var hashValueStable: Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(truncatingIfNeeded: h >> 1)
    }
}
