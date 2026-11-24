import UIKit

// Building blocks shared by every menu screen, so they read as one product.

extension UI {
    static let card = UIColor(red: 0.075, green: 0.09, blue: 0.14, alpha: 1)
    static let cardRaised = UIColor(red: 0.10, green: 0.12, blue: 0.19, alpha: 1)
    static let hairline = UIColor(white: 1, alpha: 0.09)
    static let faint = UIColor(white: 1, alpha: 0.38)
    static let green = UIColor(red: 0.30, green: 0.92, blue: 0.55, alpha: 1)
    static let gutter: CGFloat = 20

    /// Small tracked caps used for section labels.
    static func caps(_ text: String, _ size: CGFloat = 10, _ color: UIColor = UI.faint) -> UILabel {
        let l = label("", font(size, .bold), color)
        l.attributedText = NSAttributedString(string: text, attributes: [.kern: 1.4])
        return l
    }

    static func body(_ text: String, _ size: CGFloat = 13, _ color: UIColor = UI.dim) -> UILabel {
        let l = label(text, UIFont.systemFont(ofSize: size, weight: .medium), color)
        l.numberOfLines = 0
        l.adjustsFontSizeToFitWidth = false
        return l
    }

    static func symbol(_ name: String, _ size: CGFloat, _ weight: UIImage.SymbolWeight = .bold) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light, intensity: CGFloat? = nil) {
        guard Profile.shared.haptics else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        if let intensity { generator.impactOccurred(intensity: intensity) } else { generator.impactOccurred() }
    }

    static func stack(_ views: [UIView], axis: NSLayoutConstraint.Axis = .vertical, spacing: CGFloat = 8,
                      alignment: UIStackView.Alignment = .fill) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.axis = axis
        s.spacing = spacing
        s.alignment = alignment
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    static func scrollColumn(_ content: UIView, centered: Bool = false) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.keyboardDismissMode = .onDrag
        let column = UIView()
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        column.addSubview(content)
        let guide = scroll.contentLayoutGuide
        let fitHeight = column.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        fitHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            column.topAnchor.constraint(equalTo: guide.topAnchor),
            column.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            content.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: column.topAnchor, constant: 4),
            content.bottomAnchor.constraint(lessThanOrEqualTo: column.bottomAnchor, constant: -4),
            centered ? content.centerYAnchor.constraint(equalTo: column.centerYAnchor)
                     : content.topAnchor.constraint(equalTo: column.topAnchor, constant: 4),
            fitHeight,
        ])
        return scroll
    }

    static func columns(_ leading: UIView, _ trailing: UIView, leadingShare: CGFloat = 0.5,
                        spacing: CGFloat = 20, alignment: UIStackView.Alignment = .fill) -> UIStackView {
        let pair = stack([leading, trailing], axis: .horizontal, spacing: spacing, alignment: alignment)
        if leadingShare == 0.5 {
            pair.distribution = .fillEqually
        } else {
            leading.widthAnchor.constraint(equalTo: trailing.widthAnchor,
                                           multiplier: leadingShare / (1 - leadingShare)).isActive = true
        }
        return pair
    }
}

/// Deep blue-black wash behind every menu, with a faint glow at the top.
final class BackdropView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let g = layer as! CAGradientLayer
        g.colors = [UIColor(red: 0.07, green: 0.10, blue: 0.19, alpha: 1).cgColor,
                    UI.ink.cgColor, UIColor(red: 0.02, green: 0.025, blue: 0.05, alpha: 1).cgColor]
        g.locations = [0, 0.45, 1]
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Base for menu screens: backdrop, dark style, landscape, no status bar.
class ScreenController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UI.ink
        let backdrop = BackdropView(frame: view.bounds)
        view.addSubview(backdrop)
    }

    /// A header with a back button, title and the wallet, pinned under the safe area.
    @discardableResult
    func addHeader(_ title: String, back: Bool = true) -> HeaderBar {
        let header = HeaderBar(title: title, back: back)
        header.onBack = { [weak self] in self?.navigationController?.popViewController(animated: true) }
        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        return header
    }

    func placeBody(_ body: UIView, below header: UIView) {
        view.addSubview(body)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            body.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: UI.gutter),
            body.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -UI.gutter),
            body.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -8),
        ])
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

/// Back chevron, screen title, credits.
final class HeaderBar: UIView {
    var onBack: (() -> Void)?
    let wallet = CreditsPill()

    init(title: String, back: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = UI.label(title, UI.font(22, .black))
        titleLabel.accessibilityTraits = .header
        let backButton = CircleButton(symbol: "chevron.left")
        backButton.accessibilityLabel = "Back"
        backButton.onTap = { [weak self] in self?.onBack?() }
        backButton.isHidden = !back
        [backButton, titleLabel, wallet].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: back ? backButton.trailingAnchor : leadingAnchor,
                                                constant: back ? 12 : UI.gutter),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: wallet.leadingAnchor, constant: -10),
            wallet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -UI.gutter),
            wallet.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Round icon button: back, settings, close.
final class CircleButton: UIButton {
    var onTap: (() -> Void)?

    init(symbol: String, size: CGFloat = 40) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setImage(UI.symbol(symbol, 15, .heavy), for: .normal)
        tintColor = .white
        backgroundColor = UIColor(white: 1, alpha: 0.08)
        layer.cornerRadius = size / 2
        layer.borderWidth = 1
        layer.borderColor = UI.hairline.cgColor
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        addAction(UIAction { [weak self] _ in UI.haptic(); self?.onTap?() }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.55 : 1 } }

    // Bigger target than it looks.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -6, dy: -6).contains(point)
    }
}

/// The wallet. Counts up or down when the balance changes.
final class CreditsPill: UIView {
    private let amount = UI.label("", UI.digits(15, .bold), .white)
    private let coin = UI.label("₵", UI.font(13, .black), UI.ink, align: .center)
    private var shown = Profile.shared.credits
    private var link: CADisplayLink?
    private var from = 0, to = 0
    private var start: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor(white: 1, alpha: 0.07)
        layer.cornerRadius = 17
        layer.borderWidth = 1
        layer.borderColor = UI.amber.withAlphaComponent(0.35).cgColor
        let disc = UIView()
        disc.translatesAutoresizingMaskIntoConstraints = false
        disc.backgroundColor = UI.amber
        disc.layer.cornerRadius = 11
        disc.addSubview(coin)
        amount.adjustsFontSizeToFitWidth = false
        [disc, amount].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            disc.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            disc.centerYAnchor.constraint(equalTo: centerYAnchor),
            disc.widthAnchor.constraint(equalToConstant: 22),
            disc.heightAnchor.constraint(equalToConstant: 22),
            coin.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            coin.centerYAnchor.constraint(equalTo: disc.centerYAnchor, constant: 0.5),
            amount.leadingAnchor.constraint(equalTo: disc.trailingAnchor, constant: 8),
            amount.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            amount.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        render(shown)
        isAccessibilityElement = true
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: Profile.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func render(_ value: Int) {
        amount.text = Economy.credits(value).dropFirst().description
        accessibilityLabel = "\(value) credits"
    }

    @objc private func changed() {
        let target = Profile.shared.credits
        guard target != to || link == nil, target != shown else { return }
        from = shown
        to = target
        start = CACurrentMediaTime()
        link?.invalidate()
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
        UIView.animate(withDuration: 0.12, animations: { self.transform = CGAffineTransform(scaleX: 1.08, y: 1.08) }) { _ in
            UIView.animate(withDuration: 0.25) { self.transform = .identity }
        }
    }

    @objc private func tick() {
        let t = min(1, (CACurrentMediaTime() - start) / 0.7)
        let eased = 1 - pow(1 - t, 3)
        shown = from + Int(Double(to - from) * eased)
        render(shown)
        if t >= 1 { link?.invalidate(); link = nil }
    }
}

/// "B 575": class letter on its colour, then the performance index.
final class ClassBadge: UIView {
    private let letter = UI.label("", UI.font(12, .black), UI.ink, align: .center)
    private let number = UI.label("", UI.digits(12, .bold), .white)
    private let plate = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor(white: 1, alpha: 0.07)
        layer.cornerRadius = 6
        plate.translatesAutoresizingMaskIntoConstraints = false
        plate.layer.cornerRadius = 5
        plate.addSubview(letter)
        [plate, number].forEach(addSubview)
        // Shrink-wrap the content when it sits in a stack beside a label that should take the room.
        let wrap = widthAnchor.constraint(equalToConstant: 0)
        wrap.priority = UILayoutPriority(252)
        NSLayoutConstraint.activate([
            wrap,
            heightAnchor.constraint(equalToConstant: 24),
            plate.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            plate.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            plate.widthAnchor.constraint(equalToConstant: 22),
            letter.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            letter.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            number.leadingAnchor.constraint(equalTo: plate.trailingAnchor, constant: 7),
            number.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            number.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ spec: CarSpec) {
        let c = spec.carClass
        letter.text = c.letter
        plate.backgroundColor = UI.color(c.color)
        number.text = "\(spec.index)"
        accessibilityLabel = "Class \(c.letter), performance \(spec.index)"
        isAccessibilityElement = true
    }

    /// Just a class, no number: for event requirements.
    func set(_ c: CarClass, text: String) {
        letter.text = c.letter
        plate.backgroundColor = UI.color(c.color)
        number.text = text
    }
}

/// The four ratings as bars. A ghost segment previews the next upgrade.
final class StatBars: UIView {
    /// One bar: lays out its own fill, so it always knows its width.
    private final class Bar: UIView {
        let fill = UIView()
        let ghost = UIView()
        var value: Float = 0 { didSet { setNeedsLayout() } }
        var preview: Float = 0 { didSet { setNeedsLayout() } }

        override init(frame: CGRect) {
            super.init(frame: frame)
            translatesAutoresizingMaskIntoConstraints = false
            backgroundColor = UIColor(white: 1, alpha: 0.08)
            layer.cornerRadius = 2.5
            clipsToBounds = true
            ghost.backgroundColor = UI.green.withAlphaComponent(0.85)
            ghost.layer.cornerRadius = 2.5
            fill.layer.cornerRadius = 2.5
            addSubview(ghost)
            addSubview(fill)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            let w = bounds.width
            fill.frame = CGRect(x: 0, y: 0, width: w * CGFloat(max(0.03, min(1, value))), height: bounds.height)
            ghost.frame = CGRect(x: 0, y: 0, width: w * CGFloat(max(0.03, min(1, preview))), height: bounds.height)
        }
    }

    private var bars: [Bar] = []
    private let numbers: [UILabel]
    var tint = UI.cyan

    init(compact: Bool = false) {
        numbers = CarSpec.statNames.map { _ in UI.label("", UI.digits(11, .semibold), UI.faint, align: .right) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let rows = CarSpec.statNames.enumerated().map { i, name -> UIView in
            let row = UIView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let label = UI.caps(name, 10, UI.dim)
            let bar = Bar()
            bars.append(bar)
            [label, bar, numbers[i]].forEach(row.addSubview)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: compact ? 14 : 16),
                label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                label.widthAnchor.constraint(equalToConstant: 72),
                bar.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
                bar.trailingAnchor.constraint(equalTo: numbers[i].leadingAnchor, constant: -8),
                bar.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                bar.heightAnchor.constraint(equalToConstant: 5),
                numbers[i].trailingAnchor.constraint(equalTo: row.trailingAnchor),
                numbers[i].centerYAnchor.constraint(equalTo: row.centerYAnchor),
                numbers[i].widthAnchor.constraint(equalToConstant: 28),
            ])
            return row
        }
        let stack = UI.stack(rows, spacing: compact ? 5 : 8)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ ratings: [Float], preview: [Float]? = nil, tint: UIColor? = nil, animated: Bool) {
        if let tint { self.tint = tint }
        let previews = preview ?? ratings
        let apply = {
            for (i, bar) in self.bars.enumerated() {
                bar.value = ratings[i]
                bar.preview = previews[i]
                bar.fill.backgroundColor = self.tint
                bar.layoutIfNeeded()
            }
        }
        for (i, label) in numbers.enumerated() {
            label.text = "\(Int((ratings[i] * 100).rounded()))"
            label.textColor = previews[i] > ratings[i] + 0.001 ? UI.green : UI.faint
        }
        if animated {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, animations: apply)
        } else {
            apply()
        }
    }
}

/// Rounded panel.
class CardView: UIView {
    init(raised: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = raised ? UI.cardRaised : UI.card
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UI.hairline.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Lays `content` inside with even padding.
    func fill(with content: UIView, inset: CGFloat = 16) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
    }
}

/// Square-ish menu tile: icon, title, one line of detail.
final class TileButton: UIControl {
    var onTap: (() -> Void)?

    init(title: String, symbol: String, tint: UIColor = UI.cyan) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UI.card
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UI.hairline.cgColor
        let icon = UIImageView(image: UI.symbol(symbol, 18, .bold))
        icon.tintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        let titleLabel = UI.label(title, UI.font(12, .black, wide: false), .white, align: .center)
        let content = UI.stack([icon, titleLabel], spacing: 8, alignment: .center)
        content.isUserInteractionEnabled = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -8),
            icon.heightAnchor.constraint(equalToConstant: 22),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
        addAction(UIAction { [weak self] _ in UI.haptic(); self?.onTap?() }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
                self.backgroundColor = self.isHighlighted ? UI.cardRaised : UI.card
            }
        }
    }
}

/// Row of dots for the showroom position.
final class PageDots: UIView {
    private let stack = UI.stack([], axis: .horizontal, spacing: 6, alignment: .center)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(count: Int, current: Int) {
        if stack.arrangedSubviews.count != count {
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for _ in 0..<count {
                let dot = UIView()
                dot.layer.cornerRadius = 3
                dot.translatesAutoresizingMaskIntoConstraints = false
                dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
                let w = dot.widthAnchor.constraint(equalToConstant: 6)
                w.identifier = "w"
                w.isActive = true
                stack.addArrangedSubview(dot)
            }
        }
        for (i, dot) in stack.arrangedSubviews.enumerated() {
            let on = i == current
            dot.constraints.first { $0.identifier == "w" }?.constant = on ? 18 : 6
            dot.backgroundColor = on ? UI.cyan : UIColor(white: 1, alpha: 0.22)
        }
        UIView.animate(withDuration: 0.2) { self.layoutIfNeeded() }
    }
}

/// Two-way switch drawn in the house style: CIRCUIT | STREET.
final class SegmentSwitch: UIControl {
    private var buttons: [UIButton] = []
    private let thumb = UIView()
    private(set) var selectedIndex = 0
    var onChange: ((Int) -> Void)?

    init(_ titles: [String]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UI.card
        layer.cornerRadius = 12
        layer.borderWidth = 1
        layer.borderColor = UI.hairline.cgColor
        thumb.backgroundColor = UI.cyan
        thumb.layer.cornerRadius = 9
        addSubview(thumb)
        for (i, t) in titles.enumerated() {
            let b = UIButton(type: .custom)
            b.setTitle(t, for: .normal)
            b.titleLabel?.font = UI.font(12, .black)
            b.addAction(UIAction { [weak self] _ in self?.select(i, notify: true) }, for: .touchUpInside)
            buttons.append(b)
        }
        let row = UI.stack(buttons, axis: .horizontal, spacing: 0)
        row.distribution = .fillEqually
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        select(0, notify: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func select(_ i: Int, notify: Bool) {
        if notify, i != selectedIndex { UI.haptic() }
        selectedIndex = i
        for (k, b) in buttons.enumerated() {
            b.setTitleColor(k == i ? UI.ink : UI.dim, for: .normal)
            b.accessibilityTraits = k == i ? [.button, .selected] : .button
        }
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        if notify { onChange?(i) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !buttons.isEmpty else { return }
        let w = bounds.width / CGFloat(buttons.count)
        thumb.frame = CGRect(x: CGFloat(selectedIndex) * w + 4, y: 4, width: w - 8, height: bounds.height - 8)
    }
}

/// Centered landscape dialog for confirmations, event details, and messages.
/// Built in-house so it matches the rest of the menus.
final class SheetController: UIViewController {
    private let content: UIView
    private let card = CardView(raised: true)
    private let dim = UIView()
    var onDismiss: (() -> Void)?

    init(content: UIView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        dim.backgroundColor = UIColor(red: 0, green: 0.01, blue: 0.03, alpha: 0.7)
        dim.frame = view.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeTapped)))
        view.addSubview(dim)
        view.addSubview(card)
        let close = CircleButton(symbol: "xmark", size: 36)
        close.accessibilityLabel = "Close"
        close.onTap = { [weak self] in self?.closeTapped() }
        content.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UI.scrollColumn(content)
        card.addSubview(scroll)
        card.addSubview(close)
        let safe = view.safeAreaLayoutGuide
        let width = card.widthAnchor.constraint(equalTo: safe.widthAnchor, constant: -64)
        width.priority = .defaultHigh
        let fitHeight = scroll.heightAnchor.constraint(equalTo: content.heightAnchor, constant: 8)
        fitHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            card.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: 8),
            card.bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor, constant: -8),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            width,
            close.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            close.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: close.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            fitHeight,
        ])
    }

    @objc private func closeTapped() { close(then: nil) }

    func close(then action: (() -> Void)?) {
        dismiss(animated: true) { [onDismiss] in
            onDismiss?()
            action?()
        }
    }

    /// Title, message and buttons. The first action is the primary one.
    static func confirm(title: String, message: String, confirm: String, tint: UIColor = UI.cyan,
                        cancel: String? = "CANCEL", action: @escaping () -> Void) -> SheetController {
        let titleLabel = UI.label(title, UI.font(22, .black))
        titleLabel.numberOfLines = 2
        let body = UI.body(message, 14)
        let go = GlowButton(confirm, tint: tint, filled: true, size: 15)
        go.heightAnchor.constraint(equalToConstant: 48).isActive = true
        var buttons: [UIView] = [go]
        var cancelButton: GlowButton?
        if let cancel {
            let c = GlowButton(cancel, tint: UIColor(white: 1, alpha: 0.7), size: 13)
            c.heightAnchor.constraint(equalToConstant: 48).isActive = true
            buttons.insert(c, at: 0)
            cancelButton = c
        }
        let actions = UI.stack(buttons, axis: .horizontal, spacing: 10)
        actions.distribution = .fillEqually
        let stack = UI.stack([titleLabel, body, actions], spacing: 12)
        let sheet = SheetController(content: stack)
        go.onTap = { [weak sheet] in sheet?.close(then: action) }
        cancelButton?.onTap = { [weak sheet] in sheet?.close(then: nil) }
        return sheet
    }
}

/// Small transient message at the top of the screen.
enum Toast {
    static func show(_ text: String, in view: UIView, color: UIColor = UI.cyan) {
        let label = UI.label(text, UI.font(12, .black), UI.ink, align: .center)
        let pill = UIView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = color
        pill.layer.cornerRadius = 18
        pill.addSubview(label)
        view.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),
            pill.heightAnchor.constraint(equalToConstant: 36),
            pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        pill.alpha = 0
        pill.transform = CGAffineTransform(translationX: 0, y: -12)
        UIView.animate(withDuration: 0.25) { pill.alpha = 1; pill.transform = .identity }
        UIView.animate(withDuration: 0.3, delay: 2.0, options: []) { pill.alpha = 0 } completion: { _ in pill.removeFromSuperview() }
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
