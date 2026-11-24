import UIKit

/// Shared maps of the circuits, built once: a TrackPath is not free.
enum TrackMaps {
    private static var paths: [UInt64: TrackPath] = [:]

    static func path(_ definition: TrackDefinition) -> TrackPath {
        if let p = paths[definition.seed] { return p }
        let p = TrackPath(definition: definition, spacing: 8)
        paths[definition.seed] = p
        return p
    }

    static func definition(_ track: Int) -> TrackDefinition { TrackLibrary.all[track % TrackLibrary.all.count] }

    static func map(_ track: Int, size: CGFloat) -> TrackMapView {
        let definition = definition(track)
        let map = TrackMapView()
        map.lineColor = UI.color(definition.theme.neonA)
        map.setTrack(path(definition), every: 2)
        map.widthAnchor.constraint(equalToConstant: size).isActive = true
        map.heightAnchor.constraint(equalToConstant: size).isActive = true
        return map
    }
}

/// Starts races and books what happens in them.
enum RaceLauncher {
    static func circuit(_ event: CircuitEvent, from vc: UIViewController) {
        guard let window = vc.viewIfLoaded?.window else { return }
        let profile = Profile.shared
        let car = profile.selectedCar
        var config = RaceConfig(definition: TrackMaps.definition(event.track), player: car.design,
                                rivals: event.rivals.map { Entrant(name: $0.driver, design: $0.design) })
        config.laps = event.laps
        config.difficulty = event.difficulty
        config.assist = profile.assist
        config.playerName = profile.driver
        let game = GameViewController(config: config)
        game.onFinish = { result in
            let (prize, bonus) = profile.record(event: event, position: result.position)
            var lines: [ResultLine] = []
            lines.append(ResultLine(title: result.position <= 3 ? "\(UI.ordinal(result.position)) PLACE PRIZE" : "PRIZE",
                                    value: Economy.credits(prize), color: prize > 0 ? UI.amber : UI.dim))
            if bonus > 0 { lines.append(ResultLine(title: "FIRST WIN BONUS", value: Economy.credits(bonus), color: UI.green)) }
            lines.append(ResultLine(title: "BALANCE", value: Economy.credits(profile.credits), color: .white))
            return lines
        }
        game.allowsRetry = true
        game.start(in: window)
    }

    static func street(_ challenger: Challenger, from vc: UIViewController) {
        guard let window = vc.viewIfLoaded?.window else { return }
        let profile = Profile.shared
        let car = profile.selectedCar
        var config = RaceConfig(definition: TrackMaps.definition(challenger.track), player: car.design,
                                rivals: [Entrant(name: challenger.driver, design: challenger.design)])
        config.isStreetRace = true
        config.laps = 2
        config.difficulty = challenger.isKing ? 2 : 1
        config.assist = profile.assist
        config.playerName = profile.driver
        let game = GameViewController(config: config)
        game.onFinish = { result in
            let won = result.position == 1
            let prize = profile.record(challenger: challenger, won: won)
            var lines = [ResultLine(title: "PRIZE", value: Economy.credits(prize), color: prize > 0 ? UI.amber : UI.dim)]
            lines.append(ResultLine(title: "BALANCE", value: Economy.credits(profile.credits), color: .white))
            return lines
        }
        game.start(in: window)
    }
}

/// Free circuit events and head-to-head street challenges.
final class EventsViewController: ScreenController {
    private let profile = Profile.shared
    private let switcher = SegmentSwitch(["STREET", "CIRCUIT"])
    private var scroll: UIScrollView!
    private let content = UI.stack([], spacing: 12)
    private let carName = UI.label("", UI.font(14, .black))
    private let carBadge = ClassBadge()

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout(below: addHeader("RACE"))
        switcher.onChange = { [weak self] _ in self?.reload(animated: true) }
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: Profile.didChange, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload(animated: false)
    }

    @objc private func changed() {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        reload(animated: false)
    }

    private func buildLayout(below header: UIView) {
        // The car you'd be racing, so the class rules make sense at a glance.
        let strip = CardView()
        let label = UI.caps("RACING IN", 9)
        let text = UI.stack([label, carName], spacing: 1)
        let change = UIButton(type: .system)
        change.setTitle("CHANGE", for: .normal)
        change.titleLabel?.font = UI.font(11, .black)
        change.tintColor = UI.cyan
        change.addAction(UIAction { [weak self] _ in self?.navigationController?.popViewController(animated: true) }, for: .touchUpInside)
        let row = UI.stack([text, carBadge, change], axis: .horizontal, spacing: 10, alignment: .center)
        carBadge.setContentHuggingPriority(.required, for: .horizontal)
        change.setContentHuggingPriority(.required, for: .horizontal)
        strip.fill(with: row, inset: 12)

        scroll = UI.scrollColumn(content)
        let selection = UI.scrollColumn(UI.stack([switcher, strip], spacing: 10))
        placeBody(UI.columns(selection, scroll, leadingShare: 0.34), below: header)
    }

    private func reload(animated: Bool) {
        let car = profile.selectedCar.design
        carName.text = car.name
        carBadge.set(car.spec)
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if switcher.selectedIndex == 0 { buildStreet() } else { buildCircuit() }
        if animated {
            content.alpha = 0
            content.transform = CGAffineTransform(translationX: switcher.selectedIndex == 0 ? -24 : 24, y: 0)
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
                self.content.alpha = 1
                self.content.transform = .identity
            }
            scroll.setContentOffset(.zero, animated: false)
        }
    }

    // MARK: - Circuit

    private func buildCircuit() {
        let carClass = profile.selectedCar.design.spec.carClass
        for tier in [CarClass.c, .b, .a, .s] {
            let events = Events.all.filter { $0.carClass == tier }
            let header = UI.stack([], axis: .horizontal, spacing: 8, alignment: .center)
            let badge = ClassBadge()
            badge.set(tier, text: "CLASS")
            header.addArrangedSubview(badge)
            let note = UI.caps(tier == .s ? "ANY CAR" : "PERFORMANCE \(tier.cap) OR LESS", 9)
            header.addArrangedSubview(note)
            header.addArrangedSubview(UIView())
            content.addArrangedSubview(header)
            content.setCustomSpacing(8, after: header)
            for event in events {
                let card = EventCard(event: event, carClass: carClass)
                card.onTap = { [weak self] in self?.openEvent(event) }
                content.addArrangedSubview(card)
            }
            content.setCustomSpacing(26, after: content.arrangedSubviews.last!)
        }
    }

    private func openEvent(_ event: CircuitEvent) {
        let car = profile.selectedCar.design
        let path = TrackMaps.path(TrackMaps.definition(event.track))
        let title = UI.label(event.name, UI.font(24, .black))
        let place = UI.caps("\(TrackMaps.definition(event.track).name.uppercased())  ·  \(event.laps) LAPS  ·  "
                            + String(format: "%.1f KM", path.totalLength / 1000), 10, UI.cyan)
        let map = TrackMaps.map(event.track, size: 120)
        let mapRow = UI.stack([UIView(), map, UIView()], axis: .horizontal, alignment: .center)
        mapRow.distribution = .equalCentering

        let payouts = UI.stack((1...3).map { p -> UIView in
            let card = CardView()
            let label = UI.caps(UI.ordinal(p), 10, p == 1 ? UI.amber : UI.dim)
            label.textAlignment = .center
            let value = UI.label(Economy.credits(event.payout(position: p)), UI.digits(15, .heavy),
                                 p == 1 ? UI.amber : .white, align: .center)
            card.fill(with: UI.stack([label, value], spacing: 4), inset: 10)
            return card
        }, axis: .horizontal, spacing: 8)
        payouts.distribution = .fillEqually

        var notes: [String] = []
        if !profile.hasWon(event) { notes.append("First win pays a bonus of \(Economy.credits(Economy.round(Float(event.purse) * 0.5))).") }
        notes.append("Five rivals in class \(event.carClass.letter) cars. Best lap and podium shown at the finish.")
        let body = UI.body(notes.joined(separator: " "), 13)

        let start = GlowButton("START  ·  FREE ENTRY",
                               filled: true, size: 16)
        start.heightAnchor.constraint(equalToConstant: 58).isActive = true
        var problem: String?
        if profile.wins < event.winsToUnlock { problem = event.winsToUnlock - profile.wins == 1 ? "WIN 1 MORE RACE TO ENTER" : "WIN \(event.winsToUnlock - profile.wins) MORE RACES TO ENTER" }
        else if car.spec.index > event.carClass.cap { problem = "\(car.name) IS OVER CLASS \(event.carClass.letter) (\(car.spec.index) > \(event.carClass.cap))" }
        let warning = UI.caps(problem ?? "", 10, UI.magenta)
        warning.numberOfLines = 2
        warning.isHidden = problem == nil
        start.isEnabled = problem == nil

        title.numberOfLines = 0
        place.numberOfLines = 0
        let track = UI.stack([title, place, mapRow], spacing: 8)
        let details = UI.stack([payouts, body, warning, start], spacing: 12)
        let stack = UI.columns(track, details, leadingShare: 0.38, alignment: .center)
        let sheet = SheetController(content: stack)
        start.onTap = { [weak self, weak sheet] in
            sheet?.close { if let self { RaceLauncher.circuit(event, from: self) } }
        }
        present(sheet, animated: true)
    }

    // MARK: - Street

    private func buildStreet() {
        let intro = UI.body("Night rivals. One on one, two laps, free entry. "
                            + "The board changes after every street race.", 13)
        content.addArrangedSubview(intro)
        content.setCustomSpacing(16, after: intro)
        for challenger in Street.board(round: profile.streetRound, playerIndex: profile.selectedCar.design.spec.index) {
            let card = ChallengeCard(challenger: challenger, profile: profile)
            card.onRace = { [weak self] in self?.confirmStreet(challenger) }
            content.addArrangedSubview(card)
        }
        let kingHeader = UI.caps("THE KING", 10, UI.amber)
        content.setCustomSpacing(26, after: content.arrangedSubviews.last!)
        content.addArrangedSubview(kingHeader)
        if profile.kingBeaten {
            content.addArrangedSubview(UI.body("You beat the King. The crown is yours.", 13))
        } else if profile.wins < Street.winsForKing {
            let card = CardView()
            let lock = UIImageView(image: UI.symbol("lock.fill", 16))
            lock.tintColor = UI.amber
            let text = UI.body("The King only races drivers with \(Street.winsForKing) wins. "
                               + "You have \(profile.wins).", 13)
            card.fill(with: UI.stack([lock, text], axis: .horizontal, spacing: 12, alignment: .center), inset: 16)
            content.addArrangedSubview(card)
        } else {
            let card = ChallengeCard(challenger: Street.king, profile: profile)
            card.onRace = { [weak self] in self?.confirmStreet(Street.king) }
            content.addArrangedSubview(card)
        }
    }

    private func confirmStreet(_ challenger: Challenger) {
        let car = profile.selectedCar.design
        let message = "\(car.name) against \(challenger.driver)'s \(challenger.design.name). Free entry. Win \(Economy.credits(challenger.victoryPrize))."
        let sheet = SheetController.confirm(title: challenger.isKing ? "CHALLENGE THE KING?" : "CHALLENGE THIS RIVAL?",
                                            message: message, confirm: "RACE",
                                            tint: challenger.isKing ? UI.amber : UI.cyan) { [weak self] in
            guard let self else { return }
            RaceLauncher.street(challenger, from: self)
        }
        present(sheet, animated: true)
    }

}

/// One circuit event in the list.
private final class EventCard: UIControl {
    var onTap: (() -> Void)?

    init(event: CircuitEvent, carClass: CarClass) {
        super.init(frame: .zero)
        let profile = Profile.shared
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UI.card
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UI.hairline.cgColor

        let map = TrackMaps.map(event.track, size: 62)
        let name = UI.label(event.name, UI.font(15, .black))
        let place = UI.caps("\(TrackMaps.definition(event.track).name.uppercased())  ·  \(event.laps) LAPS", 9)
        let entry = UI.caps("FREE ENTRY", 9, UI.dim)
        let text = UI.stack([name, place, entry], spacing: 3)
        let prizeLabel = UI.caps("1ST", 9, UI.faint)
        prizeLabel.textAlignment = .right
        let prize = UI.label(Economy.credits(event.purse), UI.digits(15, .heavy), UI.amber, align: .right)
        let right = UI.stack([prizeLabel, prize], spacing: 2, alignment: .trailing)
        right.setContentHuggingPriority(.required, for: .horizontal)
        prize.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UI.stack([map, text, right], axis: .horizontal, spacing: 12, alignment: .center)
        row.isUserInteractionEnabled = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])

        var status: (String, String, UIColor)?
        if profile.wins < event.winsToUnlock {
            status = ("lock.fill", event.winsToUnlock == 1 ? "1 WIN" : "\(event.winsToUnlock) WINS", UI.faint)
            alpha = 0.55
        } else if carClass > event.carClass {
            status = ("exclamationmark.triangle.fill", "OVER CLASS", UI.magenta)
        } else if profile.hasWon(event) {
            status = ("checkmark.seal.fill", "WON", UI.green)
        }
        if let (symbol, text, color) = status {
            let icon = UIImageView(image: UI.symbol(symbol, 10))
            icon.tintColor = color
            let label = UI.caps(text, 8, color)
            let chip = UI.stack([icon, label], axis: .horizontal, spacing: 4, alignment: .center)
            chip.isUserInteractionEnabled = false
            addSubview(chip)
            NSLayoutConstraint.activate([
                chip.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                chip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ])
            prizeLabel.isHidden = true
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(event.name), \(TrackMaps.definition(event.track).name), first prize \(event.purse) credits"
        accessibilityValue = status?.1
        addAction(UIAction { [weak self] _ in UI.haptic(); self?.onTap?() }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
            }
        }
    }
}

/// A challenger on the street board: who, in what, where, and for how much.
private final class ChallengeCard: CardView {
    var onRace: (() -> Void)?
    private let race = GlowButton("RACE", filled: true, size: 14)

    init(challenger: Challenger, profile: Profile) {
        super.init(raised: false)
        if challenger.isKing { layer.borderColor = UI.amber.withAlphaComponent(0.6).cgColor }
        let design = challenger.design
        let driver = UI.label(challenger.driver, UI.font(18, .black), challenger.isKing ? UI.amber : .white)
        let badge = ClassBadge()
        badge.set(design.spec)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        let head = UI.stack([driver, badge], axis: .horizontal, spacing: 8, alignment: .center)
        let car = UI.caps("\(design.name)  ·  \(design.className)  ·  \(TrackMaps.definition(challenger.track).name.uppercased())",
                          9, UI.color(design.glow))

        // Their numbers against yours.
        let mine = profile.selectedCar.design.spec.ratings
        let compare = UI.stack(CarSpec.statNames.enumerated().map { i, name in
            let theirs = design.spec.ratings[i]
            let diff = Int(((theirs - mine[i]) * 100).rounded())
            let label = UI.caps(String(name.prefix(5)), 8)
            label.textAlignment = .center
            let value = UI.label(diff == 0 ? "=" : (diff > 0 ? "+\(diff)" : "\(diff)"), UI.digits(13, .bold),
                                 diff > 0 ? UI.magenta : (diff < 0 ? UI.green : UI.dim), align: .center)
            return UI.stack([value, label], spacing: 1)
        }, axis: .horizontal, spacing: 4)
        compare.distribution = .fillEqually
        let compareTitle = UI.caps("THEIR CAR VS YOURS", 8)

        let prize = UI.caps("WIN \(Economy.credits(challenger.victoryPrize))  ·  FREE ENTRY", 10, UI.amber)
        race.heightAnchor.constraint(equalToConstant: 46).isActive = true
        race.onTap = { [weak self] in self?.onRace?() }
        let stack = UI.stack([head, car, compareTitle, compare, prize, race], spacing: 8)
        stack.setCustomSpacing(2, after: head)
        stack.setCustomSpacing(14, after: car)
        stack.setCustomSpacing(4, after: compareTitle)
        stack.setCustomSpacing(14, after: compare)
        fill(with: stack, inset: 16)
    }

    required init?(coder: NSCoder) { fatalError() }

}

