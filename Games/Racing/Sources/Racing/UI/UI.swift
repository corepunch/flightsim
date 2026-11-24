import UIKit
import simd

/// Shared look: wide heavy type, cyan and magenta on near-black.
enum UI {
    static let cyan = UIColor(red: 0.10, green: 0.90, blue: 1.00, alpha: 1)
    static let magenta = UIColor(red: 1.00, green: 0.18, blue: 0.62, alpha: 1)
    static let amber = UIColor(red: 1.00, green: 0.72, blue: 0.15, alpha: 1)
    static let ink = UIColor(red: 0.03, green: 0.04, blue: 0.08, alpha: 1)
    static let panel = UIColor(red: 0.07, green: 0.09, blue: 0.15, alpha: 0.92)
    static let dim = UIColor(white: 1, alpha: 0.55)

    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .heavy, wide: Bool = true) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: weight, width: wide ? .expanded : .standard)
    }

    /// Digits that do not jiggle as they change.
    static func digits(_ size: CGFloat, _ weight: UIFont.Weight = .heavy) -> UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    static func color(_ c: SIMD3<Float>) -> UIColor {
        UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }

    static func label(_ text: String = "", _ font: UIFont, _ color: UIColor = .white,
                      align: NSTextAlignment = .left) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = font
        l.textColor = color
        l.textAlignment = align
        l.adjustsFontSizeToFitWidth = true
        l.minimumScaleFactor = 0.6
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    static func time(_ t: Float?) -> String {
        guard let t = t else { return "--:--.--" }
        let total = max(0, t)
        return String(format: "%d:%05.2f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
    }

    static func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "1ST"
        case 2: return "2ND"
        case 3: return "3RD"
        default: return "\(n)TH"
        }
    }
}

/// A big thumb-sized button: filled for the main action, outlined otherwise.
final class GlowButton: UIButton {
    private let tint: UIColor
    private let filled: Bool
    var onTap: (() -> Void)?

    init(_ title: String, tint: UIColor = UI.cyan, filled: Bool = false, size: CGFloat = 17) {
        self.tint = tint
        self.filled = filled
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setTitle(title, for: .normal)
        titleLabel?.font = UI.font(size)
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.6
        setTitleColor(filled ? UI.ink : tint, for: .normal)
        backgroundColor = filled ? tint : tint.withAlphaComponent(0.1)
        layer.cornerRadius = 10
        layer.borderWidth = filled ? 0 : 1.5
        layer.borderColor = tint.withAlphaComponent(0.8).cgColor
        layer.shadowColor = tint.cgColor
        layer.shadowRadius = filled ? 14 : 0
        layer.shadowOpacity = filled ? 0.6 : 0
        layer.shadowOffset = .zero
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setTitleText(_ title: String) { setTitle(title, for: .normal) }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.1) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
                self.alpha = self.isHighlighted ? 0.8 : (self.isEnabled ? 1 : 0.35)
            }
        }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.35 }
    }

    /// Recolours a button whose meaning changes (BUY → OWNED, READY → NOT READY).
    func restyle(tint: UIColor, filled: Bool) {
        setTitleColor(filled ? UI.ink : tint, for: .normal)
        backgroundColor = filled ? tint : tint.withAlphaComponent(0.1)
        layer.borderWidth = filled ? 0 : 1.5
        layer.borderColor = tint.withAlphaComponent(0.8).cgColor
        layer.shadowColor = tint.cgColor
        layer.shadowRadius = filled ? 14 : 0
        layer.shadowOpacity = filled ? 0.5 : 0
    }

    @objc private func tapped() {
        UI.haptic()
        onTap?()
    }
}

/// Outline of a circuit, fitted to the view. Dots can be laid over it in 0...1 map space.
final class TrackMapView: UIView {
    private let line = CAShapeLayer()
    private var normalized: [CGPoint] = []
    private var dots: [CALayer] = []
    var lineColor = UIColor.white { didSet { line.strokeColor = lineColor.cgColor } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        line.fillColor = nil
        line.strokeColor = lineColor.cgColor
        line.lineWidth = 2.5
        line.lineJoin = .round
        layer.addSublayer(line)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Points in the track's minimap space (0...1 on both axes).
    func setTrack(_ path: TrackPath, every stride: Int = 6) {
        normalized = Swift.stride(from: 0, to: path.stepCount, by: stride).map {
            let p = path.minimapPosition(for: path.samples[$0].position)
            return CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        }
        aspect = CGFloat((path.boundsMax.x - path.boundsMin.x) / max(1, path.boundsMax.y - path.boundsMin.y))
        setNeedsLayout()
    }

    private var aspect: CGFloat = 1

    /// Where a 0...1 map position lands in the view, keeping the circuit's proportions.
    private func place(_ p: CGPoint) -> CGPoint {
        let inset = bounds.insetBy(dx: 6, dy: 6)
        var size = inset.size
        if size.width / max(size.height, 1) > aspect { size.width = size.height * aspect } else { size.height = size.width / aspect }
        let origin = CGPoint(x: inset.midX - size.width / 2, y: inset.midY - size.height / 2)
        return CGPoint(x: origin.x + p.x * size.width, y: origin.y + p.y * size.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = bounds
        guard let first = normalized.first else { line.path = nil; return }
        let path = CGMutablePath()
        path.move(to: place(first))
        for p in normalized.dropFirst() { path.addLine(to: place(p)) }
        path.closeSubpath()
        line.path = path
    }

    func setDots(_ items: [(position: SIMD2<Float>, color: SIMD3<Float>, isPlayer: Bool)]) {
        while dots.count < items.count {
            let dot = CALayer()
            layer.addSublayer(dot)
            dots.append(dot)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, dot) in dots.enumerated() {
            guard i < items.count else { dot.isHidden = true; continue }
            let item = items[i]
            let r: CGFloat = item.isPlayer ? 5 : 3.5
            let c = place(CGPoint(x: CGFloat(item.position.x), y: CGFloat(item.position.y)))
            dot.isHidden = false
            dot.frame = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            dot.cornerRadius = r
            dot.backgroundColor = (item.isPlayer ? UIColor.white : UI.color(item.color)).cgColor
            dot.borderWidth = item.isPlayer ? 1.5 : 0
            dot.borderColor = UI.cyan.cgColor
        }
        CATransaction.commit()
    }
}
