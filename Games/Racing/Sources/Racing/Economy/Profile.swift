import Foundation

/// A car in the player's garage.
struct OwnedCar: Codable, Identifiable, Equatable {
    var id = UUID()
    var loadout: Loadout
    /// Legacy garage provenance retained for existing saves.
    var wonFrom: String?

    var design: CarDesign { loadout.design }
}

/// Everything the player has earned, saved as one JSON blob in user defaults.
/// Notifies through `Profile.didChange` so every screen's credit counter stays current.
final class Profile {
    static let shared = Profile.load()
    static let didChange = Notification.Name("ProfileDidChange")

    private struct Stored: Codable {
        var driver = "DRIVER"
        var credits = Economy.startingCredits
        var cars: [OwnedCar] = []
        var selected: UUID?
        var parts: Set<CarPart> = []
        var wins = 0
        var races = 0
        var earnings = 0
        var won: Set<String> = []
        var streetRound = 0
        var kingBeaten = false
        var assist = true
        var haptics = true
    }

    private var stored: Stored
    private static let key = "profile.v1"

    private init(_ stored: Stored) { self.stored = stored }

    private static func load() -> Profile {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            return Profile(stored)
        }
        // First launch: the self-built car from the old garage (or a fresh one) is the starter.
        var stored = Stored()
        stored.assist = defaults.object(forKey: "menu.assist") as? Bool ?? true
        let starter = OwnedCar(loadout: .custom(GarageBuild.load(from: defaults)))
        stored.cars = [starter]
        stored.selected = starter.id
        return Profile(stored)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.key) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Wipes the career: back to the starter car and starting credits.
    func reset() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        UserDefaults.standard.removeObject(forKey: "garage.build.v1")
        let fresh = Profile.load().stored
        stored = fresh
        save()
    }

    // MARK: - Read

    var driver: String {
        get { stored.driver }
        set { stored.driver = String(newValue.uppercased().prefix(14)); save() }
    }
    var credits: Int { stored.credits }
    var cars: [OwnedCar] { stored.cars }
    var wins: Int { stored.wins }
    var races: Int { stored.races }
    var earnings: Int { stored.earnings }
    var streetRound: Int { stored.streetRound }
    var kingBeaten: Bool { stored.kingBeaten }
    var assist: Bool {
        get { stored.assist }
        set { stored.assist = newValue; save() }
    }
    var haptics: Bool {
        get { stored.haptics }
        set { stored.haptics = newValue; save() }
    }

    var selectedCar: OwnedCar {
        stored.cars.first { $0.id == stored.selected } ?? stored.cars[0]
    }

    var selectedIndex: Int { stored.cars.firstIndex { $0.id == selectedCar.id } ?? 0 }

    func select(_ id: UUID) {
        guard stored.selected != id else { return }
        stored.selected = id
        save()
    }

    func owns(_ part: CarPart) -> Bool { part.price == 0 || stored.parts.contains(part) }
    func hasWon(_ event: CircuitEvent) -> Bool { stored.won.contains(event.id) }
    func owns(_ blueprint: Blueprint) -> Bool { stored.cars.contains { $0.loadout.blueprint == blueprint } }

    // MARK: - Spend

    /// Takes the credits if there are enough.
    @discardableResult
    func spend(_ amount: Int) -> Bool {
        guard amount >= 0, amount <= stored.credits else { return false }
        stored.credits -= amount
        save()
        return true
    }

    func earn(_ amount: Int) {
        guard amount > 0 else { return }
        stored.credits += amount
        stored.earnings += amount
        save()
    }

    func buy(_ car: DealerCar) -> Bool {
        guard !owns(car.blueprint), spend(car.price) else { return false }
        let owned = OwnedCar(loadout: .generated(car.blueprint))
        stored.cars.append(owned)
        stored.selected = owned.id
        save()
        return true
    }

    /// Sells a car back to the dealer. The last car can't go: you'd be walking.
    func sell(_ id: UUID) -> Int? {
        guard stored.cars.count > 1, let i = stored.cars.firstIndex(where: { $0.id == id }) else { return nil }
        let value = stored.cars[i].loadout.resale
        stored.cars.remove(at: i)
        if stored.selected == id { stored.selected = stored.cars[0].id }
        stored.credits += value
        save()
        return value
    }

    func upgrade(_ id: UUID, _ kind: UpgradeKind) -> Bool {
        guard let i = stored.cars.firstIndex(where: { $0.id == id }) else { return false }
        let level = stored.cars[i].loadout.level(kind)
        guard level < UpgradeKind.maxLevel else { return false }
        let price = kind.price(from: level)
        guard price <= stored.credits else { return false }
        stored.credits -= price
        while stored.cars[i].loadout.upgrades.count < UpgradeKind.allCases.count { stored.cars[i].loadout.upgrades.append(0) }
        stored.cars[i].loadout.upgrades[kind.rawValue] += 1
        save()
        return true
    }

    /// Pays for any parts in `build` not owned yet, then fits it to the car.
    func apply(_ build: GarageBuild, to id: UUID) -> Bool {
        guard let i = stored.cars.firstIndex(where: { $0.id == id }) else { return false }
        let cost = Self.cost(of: build, owned: stored.parts)
        guard cost <= stored.credits else { return false }
        stored.credits -= cost
        for slot in CarSlot.allCases { if let part = build.part(at: slot) { stored.parts.insert(part) } }
        stored.cars[i].loadout.build = build
        build.save()
        save()
        return true
    }

    static func cost(of build: GarageBuild, owned: Set<CarPart>) -> Int {
        Set(CarSlot.allCases.compactMap { build.part(at: $0) }).filter { $0.price > 0 && !owned.contains($0) }
            .reduce(0) { $0 + $1.price }
    }

    func cost(of build: GarageBuild) -> Int { Self.cost(of: build, owned: stored.parts) }

    // MARK: - Results

    /// Books a finished circuit event. Returns the prize and any first-win bonus.
    func record(event: CircuitEvent, position: Int) -> (prize: Int, bonus: Int) {
        stored.races += 1
        let prize = event.payout(position: position)
        var bonus = 0
        if position == 1 {
            stored.wins += 1
            if !stored.won.contains(event.id) {
                stored.won.insert(event.id)
                bonus = Economy.round(Float(event.purse) * 0.5)
            }
        }
        stored.credits += prize + bonus
        stored.earnings += prize + bonus
        save()
        return (prize, bonus)
    }

    /// A finished challenge advances the board. A loss changes no balance or car.
    func record(challenger: Challenger, won: Bool) -> Int {
        stored.races += 1
        stored.streetRound += 1
        var prize = 0
        if won {
            stored.wins += 1
            if !challenger.isKing || !stored.kingBeaten { prize = challenger.victoryPrize }
            if challenger.isKing { stored.kingBeaten = true }
        }
        stored.credits += prize
        stored.earnings += prize
        save()
        return prize
    }

    /// LAN classifications are peer-reported. Only fixed credits are awarded;
    /// solo race records and unlocks do not depend on them.
    func recordOnline(position: Int, finished: Bool) -> Int {
        let prize = RacePrizes.lan(position: position, finished: finished)
        earn(prize)
        return prize
    }

}
