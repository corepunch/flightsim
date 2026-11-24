import UIKit

/// Race read-outs leave the lower corners clear for the virtual controller.
final class HUDView: UIView {
    private let position = UI.label("", UI.font(44, .black), .white)
    private let positionOf = UI.label("", UI.font(13, .bold), UI.dim)
    private let lap = UI.label("", UI.font(15, .heavy), .white, align: .right)
    private let time = UI.label("", UI.digits(15, .semibold), UI.dim, align: .right)
    private let speed = UI.label("0", UI.digits(40, .black), .white, align: .center)
    private let unit = UI.label("KM/H", UI.font(10, .bold), UI.dim, align: .center)
    private let banner = UI.label("", UI.font(64, .black), .white, align: .center)
    private let note = UI.label("", UI.font(17, .heavy), UI.cyan, align: .center)
    private let hint = UI.label("", UI.font(10, .bold, wide: false), .white, align: .center)
    private let map = TrackMapView()
    private var noteToken = 0
    private var bannerToken = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        [position, positionOf, lap, time, speed, unit, banner, note, hint, map].forEach(addSubview)
        banner.alpha = 0
        note.alpha = 0
        map.lineColor = UIColor(white: 1, alpha: 0.55)
        for l in [position, positionOf, lap, time, speed, unit, banner, note, hint] {
            l.layer.shadowColor = UIColor.black.cgColor
            l.layer.shadowOpacity = 0.9
            l.layer.shadowRadius = 4
            l.layer.shadowOffset = .zero
        }
        let safe = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            position.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            position.topAnchor.constraint(equalTo: safe.topAnchor, constant: 2),
            positionOf.leadingAnchor.constraint(equalTo: position.trailingAnchor, constant: 4),
            positionOf.lastBaselineAnchor.constraint(equalTo: position.lastBaselineAnchor),

            lap.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -64),
            lap.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            time.trailingAnchor.constraint(equalTo: lap.trailingAnchor),
            time.topAnchor.constraint(equalTo: lap.bottomAnchor, constant: 2),

            speed.centerXAnchor.constraint(equalTo: centerXAnchor),
            speed.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            unit.centerXAnchor.constraint(equalTo: centerXAnchor),
            unit.topAnchor.constraint(equalTo: speed.bottomAnchor, constant: -4),

            map.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -10),
            map.topAnchor.constraint(equalTo: time.bottomAnchor, constant: 10),
            map.widthAnchor.constraint(equalToConstant: 76),
            map.heightAnchor.constraint(equalToConstant: 76),

            banner.centerXAnchor.constraint(equalTo: centerXAnchor),
            banner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -45),
            banner.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            note.centerXAnchor.constraint(equalTo: centerXAnchor),
            note.topAnchor.constraint(equalTo: unit.bottomAnchor, constant: 18),
            note.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -18),
            hint.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setTrack(_ path: TrackPath) { map.setTrack(path) }

    func update(_ state: HUDState) {
        position.text = "\(state.position)"
        positionOf.text = "/\(state.count)"
        lap.text = "LAP \(state.lap)/\(state.laps)"
        time.text = UI.time(state.raceTime)
        speed.text = "\(Int(state.speedKMH))"
        speed.textColor = state.boosting ? UI.amber : .white
        map.setDots(state.dots)
    }

    /// Large centre text: the countdown and GO.
    func flash(_ text: String, color: UIColor = .white, hold: TimeInterval = 0.7) {
        bannerToken += 1
        let token = bannerToken
        banner.text = text
        banner.textColor = color
        banner.alpha = 1
        banner.transform = CGAffineTransform(scaleX: 1.5, y: 1.5)
        UIView.animate(withDuration: 0.18) { self.banner.transform = .identity }
        UIView.animate(withDuration: 0.3, delay: hold, options: []) {
            if token == self.bannerToken { self.banner.alpha = 0 }
        }
    }

    /// Small line under the speed: lap times, boost, final lap.
    func announce(_ text: String, color: UIColor = UI.cyan, hold: TimeInterval = 1.6) {
        noteToken += 1
        let token = noteToken
        note.text = text
        note.textColor = color
        note.alpha = 1
        UIView.animate(withDuration: 0.3, delay: hold, options: []) {
            if token == self.noteToken { self.note.alpha = 0 }
        }
    }

    func setControlHint(_ text: String) {
        if hint.text != text { hint.text = text }
    }

    func setHintVisible(_ visible: Bool) {
        UIView.animate(withDuration: 0.4) { self.hint.alpha = visible ? 1 : 0 }
    }
}

/// A line of the results panel's payout block: PRIZE  ₵1,500.
struct ResultLine {
    var title: String
    var value: String
    var color: UIColor = UI.amber
}

/// Landscape pause and results overlay with a fixed action row.
final class PanelView: UIView {
    init(title: String, titleColor: UIColor = .white, subtitle: String? = nil,
         rows: [(left: String, right: String, highlight: Bool)] = [], money: [ResultLine] = [], buttons: [GlowButton]) {
        super.init(frame: .zero)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = UIColor(red: 0.01, green: 0.02, blue: 0.05, alpha: 0.82)

        let head = UI.label(title, UI.font(32, .black), titleColor, align: .center)
        let detail = subtitle.map { UI.body($0, 13, UI.dim) }
        detail?.textAlignment = .center
        let header = UI.stack([head] + (detail.map { [$0] } ?? []), spacing: 3)
        let standings = UI.stack(rows.map { row in
            Self.line(row.left, row.right, color: row.highlight ? UI.cyan : .white)
        }, spacing: 8)
        let payouts = UI.stack(money.map { Self.line($0.title, $0.value, color: $0.color) }, spacing: 8)
        let actions = UI.stack(buttons, axis: .horizontal, spacing: 8)
        actions.distribution = .fillEqually
        actions.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let safe = safeAreaLayoutGuide
        let content: UIView
        if rows.isEmpty, money.isEmpty {
            let menu = UI.stack([header, actions], spacing: 18)
            content = UI.scrollColumn(menu, centered: true)
        } else {
            let results = rows.isEmpty ? UI.scrollColumn(payouts)
                : money.isEmpty ? UI.scrollColumn(standings)
                : UI.columns(UI.scrollColumn(standings), UI.scrollColumn(payouts))
            content = UI.stack([header, results, actions], spacing: 12)
        }
        addSubview(content)
        let width = content.widthAnchor.constraint(equalTo: safe.widthAnchor, constant: -32)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            content.topAnchor.constraint(equalTo: safe.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -16),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 740),
            width,
        ])
    }

    private static func line(_ left: String, _ right: String, color: UIColor) -> UIView {
        let label = UI.label(left, UI.font(13, .bold, wide: false), .white)
        let value = UI.label(right, UI.digits(14, .semibold), color, align: .right)
        value.numberOfLines = 2
        value.setContentHuggingPriority(.required, for: .horizontal)
        return UI.stack([label, value], axis: .horizontal, spacing: 8, alignment: .center)
    }

    required init?(coder: NSCoder) { fatalError() }
}
