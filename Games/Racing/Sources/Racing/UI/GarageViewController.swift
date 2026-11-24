import Metal
import SceneKit
import UIKit
import simd

final class GarageViewController: UIViewController {
    private var build: GarageBuild
    private let onApply: (GarageBuild) -> Void
    private var category: CarSlot = .frame
    private var slot: CarSlot = .frame
    private var wheelPosition: WheelPosition?

    private let studio = GarageStudio()
    private let dimensions = UI.label("", UI.digits(11, .medium), UIColor(white: 1, alpha: 0.78))
    private let options = UIStackView()
    private let context = UIView()
    private let mountMessage = UI.label("", UI.font(11, .semibold, wide: false), UI.dim)
    private let mountButton = GlowButton("", size: 11)
    private let wheelControl = UISegmentedControl(items: ["ALL"] + WheelPosition.allCases.map(\.rawValue))
    private let paintLabel = UI.label("PAINT", UI.font(10, .bold), UI.dim)
    private let paintCode = UI.label("", UI.digits(11, .medium), UI.dim, align: .right)
    private let swatchRow = UIStackView()
    private var tabs: [CarSlot: UIButton] = [:]
    private var cards: [GaragePartCard] = []
    private var swatches: [GarageSwatch] = []
    private let apply = GlowButton("APPLY BUILD", filled: true, size: 16)

    private static let palette: [GaragePaint] = [
        GaragePaint(0xCEE1EF), GaragePaint(0x35D2DD), GaragePaint(0xEA548B),
        GaragePaint(0xF7B85E), GaragePaint(0x9D86E9),
    ]

    init(build: GarageBuild, onApply: @escaping (GarageBuild) -> Void) {
        self.build = build
        self.onApply = onApply
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UI.ink
        buildLayout()
        showCategory()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        studio.isPlaying = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        studio.isPlaying = false
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    private func buildLayout() {
        let title = UI.label("GARAGE", UI.font(26, .black))
        title.accessibilityTraits = .header
        let back = GlowButton("BACK", size: 11)
        back.onTap = { [weak self] in self?.dismiss(animated: true) }
        back.accessibilityHint = "Discards changes made during this visit"
        back.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let header = UIStackView(arrangedSubviews: [title, back])
        header.alignment = .center
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false

        let tabsRow = UIStackView()
        tabsRow.distribution = .fillEqually
        tabsRow.spacing = 4
        for item in CarSlot.primary {
            let tab = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in
                self?.changeCategory(to: item)
            })
            tab.setTitle(item.title, for: .normal)
            tab.titleLabel?.font = UI.font(10, .black)
            tab.titleLabel?.adjustsFontSizeToFitWidth = true
            tab.titleLabel?.minimumScaleFactor = 0.75
            tab.layer.cornerRadius = 7
            tab.layer.borderWidth = 1
            tabs[item] = tab
            tabsRow.addArrangedSubview(tab)
        }
        tabsRow.heightAnchor.constraint(equalToConstant: 44).isActive = true

        options.distribution = .fillEqually
        options.spacing = 6
        options.heightAnchor.constraint(equalToConstant: 78).isActive = true

        let paintHeader = UIStackView(arrangedSubviews: [paintLabel, paintCode])
        paintHeader.alignment = .center
        paintHeader.heightAnchor.constraint(equalToConstant: 15).isActive = true
        swatchRow.distribution = .fillEqually
        swatchRow.spacing = 4
        for color in Self.palette {
            let swatch = GarageSwatch(color: color) { [weak self] in self?.setPaint(color) }
            swatches.append(swatch)
            swatchRow.addArrangedSubview(swatch)
        }
        let custom = GlowButton("CUSTOM", size: 9)
        custom.onTap = { [weak self] in self?.openColorPicker() }
        custom.accessibilityLabel = "Choose a custom paint color"
        swatchRow.addArrangedSubview(custom)
        swatchRow.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let panel = UIStackView(arrangedSubviews: [tabsRow, context, options, paintHeader, swatchRow])
        panel.axis = .vertical
        panel.spacing = 6
        panel.setCustomSpacing(12, after: options)
        panel.setCustomSpacing(3, after: paintHeader)
        panel.translatesAutoresizingMaskIntoConstraints = false

        apply.onTap = { [weak self] in
            guard let self else { return }
            self.onApply(self.build)
            self.dismiss(animated: true)
        }

        context.heightAnchor.constraint(equalToConstant: 44).isActive = true
        context.layer.cornerRadius = 8
        context.backgroundColor = UI.panel
        wheelControl.translatesAutoresizingMaskIntoConstraints = false
        wheelControl.selectedSegmentTintColor = UI.cyan
        wheelControl.setTitleTextAttributes([.font: UI.font(10, .bold), .foregroundColor: UIColor.white], for: .normal)
        wheelControl.setTitleTextAttributes([.font: UI.font(10, .bold), .foregroundColor: UI.ink], for: .selected)
        wheelControl.accessibilityLabel = "Wheel paint position"
        wheelControl.addTarget(self, action: #selector(selectWheel), for: .valueChanged)
        mountButton.onTap = { [weak self] in
            guard let self, let child = self.build.part(at: self.category)?.attachment else { return }
            self.slot = self.slot == self.category ? child : self.category
            self.showCategory()
        }
        [mountMessage, mountButton, wheelControl].forEach(context.addSubview)

        studio.translatesAutoresizingMaskIntoConstraints = false
        dimensions.accessibilityLabel = "Car length and width"
        let controls = UI.stack([UI.scrollColumn(panel), apply], spacing: 8)
        let columns = UI.columns(studio, controls, leadingShare: 0.44, spacing: 16)
        [header, columns, dimensions].forEach(view.addSubview)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            header.heightAnchor.constraint(equalToConstant: 44),
            back.heightAnchor.constraint(equalToConstant: 44),

            columns.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            columns.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            columns.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -8),
            dimensions.leadingAnchor.constraint(equalTo: studio.leadingAnchor, constant: 12),
            dimensions.bottomAnchor.constraint(equalTo: studio.bottomAnchor, constant: -8),

            mountMessage.leadingAnchor.constraint(equalTo: context.leadingAnchor, constant: 10),
            mountMessage.centerYAnchor.constraint(equalTo: context.centerYAnchor),
            mountMessage.trailingAnchor.constraint(lessThanOrEqualTo: mountButton.leadingAnchor, constant: -6),
            mountButton.trailingAnchor.constraint(equalTo: context.trailingAnchor, constant: -4),
            mountButton.centerYAnchor.constraint(equalTo: context.centerYAnchor),
            mountButton.widthAnchor.constraint(equalToConstant: 106),
            mountButton.heightAnchor.constraint(equalToConstant: 44),
            wheelControl.leadingAnchor.constraint(equalTo: context.leadingAnchor, constant: 4),
            wheelControl.trailingAnchor.constraint(equalTo: context.trailingAnchor, constant: -4),
            wheelControl.topAnchor.constraint(equalTo: context.topAnchor, constant: 4),
            wheelControl.bottomAnchor.constraint(equalTo: context.bottomAnchor, constant: -4),

            apply.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func changeCategory(to item: CarSlot) {
        guard category != item else { return }
        category = item
        slot = item
        showCategory()
        studio.focus(on: item)
    }

    private func showCategory() {
        for (item, button) in tabs {
            let active = item == category
            button.setTitleColor(active ? UI.ink : UIColor.white, for: .normal)
            button.backgroundColor = active ? UI.cyan : UI.panel
            button.layer.borderColor = (active ? UI.cyan : UIColor(white: 1, alpha: 0.12)).cgColor
            button.accessibilityTraits = active ? [.button, .selected] : .button
        }
        for view in options.arrangedSubviews {
            options.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let catalog = CarPart.allCases.filter { $0.slot == slot }.map(Optional.some)
        let choices: [CarPart?] = slot.parent == nil ? catalog : [nil] + catalog
        cards = choices.map { part in
            let card = GaragePartCard(part: part) { [weak self] in self?.equip(part) }
            options.addArrangedSubview(card)
            return card
        }
        updateBuild()
    }

    private func equip(_ part: CarPart?) {
        build.equip(part, at: slot)
        updateBuild()
    }

    private func updateBuild() {
        let current = build.part(at: slot)
        cards.forEach { $0.active = $0.part == current }
        // Parts not owned yet are paid for when the build is applied.
        let cost = Profile.shared.cost(of: build)
        apply.setTitleText(cost > 0 ? "BUY PARTS & APPLY  ·  \(Economy.credits(cost))" : "APPLY BUILD")
        apply.isEnabled = cost <= Profile.shared.credits
        updateContext()
        updatePaint()
        showCar()
    }

    private func updateContext() {
        let part = build.part(at: category)
        let child = part?.attachment
        wheelControl.isHidden = category != .wheels
        wheelControl.selectedSegmentIndex = wheelPosition.flatMap { WheelPosition.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        mountMessage.isHidden = category == .wheels
        mountButton.isHidden = child == nil
        if let child {
            let addition = build.part(at: child)?.title ?? "Empty"
            mountMessage.text = "\(part?.title ?? "")  /  \(addition)"
            mountButton.setTitleText(slot == child ? "BACK TO \(category.title)" : child.title + "  ›")
        } else if category == .front || category == .rear {
            mountMessage.text = "\(part?.title ?? "")  /  No add-on mount"
        } else if category == .frame {
            mountMessage.text = "Frame sets the wheelbase and track width."
        } else {
            mountMessage.text = "Motor changes speed and thrust."
        }
    }

    private func showCar() {
        let design = CarDesign(garage: build)
        studio.display(design)
        dimensions.text = String(format: "%.2f × %.2f M", design.length, design.halfWidth * 2)
        dimensions.accessibilityValue = String(format: "%.2f by %.2f metres", design.length, design.halfWidth * 2)
    }

    private func updatePaint() {
        let canPaint = build.part(at: slot) != nil
        swatchRow.isUserInteractionEnabled = canPaint
        swatchRow.accessibilityElementsHidden = !canPaint
        swatchRow.alpha = canPaint ? 1 : 0.26
        paintLabel.text = slot == .wheels ? "\(wheelPosition?.rawValue ?? "WHEEL") PAINT" : "\(slot.title) PAINT"
        let color = build.paint(for: slot, wheel: wheelPosition)
        let mixedWheels = slot == .wheels && wheelPosition == nil
            && WheelPosition.allCases.contains { build.paint(for: .wheels, wheel: $0) != color }
        paintCode.text = canPaint ? (mixedWheels ? "MIXED" : String(format: "#%06X", color.hex)) : nil
        swatches.forEach { $0.active = canPaint && !mixedWheels && $0.color == color }
    }

    @objc private func selectWheel() {
        let index = wheelControl.selectedSegmentIndex - 1
        wheelPosition = WheelPosition.allCases.indices.contains(index) ? WheelPosition.allCases[index] : nil
        updatePaint()
    }

    private func setPaint(_ color: GaragePaint) {
        guard build.part(at: slot) != nil else { return }
        build.paint(color, at: slot, wheel: wheelPosition)
        updatePaint()
        showCar()
    }

    private func openColorPicker() {
        let color = build.paint(for: slot, wheel: wheelPosition)
        let picker = GaragePaintPicker(title: paintLabel.text ?? "PAINT", color: color) { [weak self] color in
            self?.setPaint(color)
        }
        present(picker, animated: true)
    }
}

private final class GaragePaintPicker: UIViewController {
    private let heading: String
    private let initial: GaragePaint
    private let onChoose: (GaragePaint) -> Void
    private let sample = UIView()
    private let code = UI.label("", UI.digits(13, .semibold), UI.dim, align: .right)
    private var sliders: [UISlider] = []

    init(title: String, color: GaragePaint, onChoose: @escaping (GaragePaint) -> Void) {
        heading = title
        initial = color
        self.onChoose = onChoose
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UI.ink

        let title = UI.label(heading, UI.font(18, .black))
        title.accessibilityTraits = .header
        sample.layer.cornerRadius = 7
        sample.widthAnchor.constraint(equalToConstant: 46).isActive = true
        sample.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let header = UIStackView(arrangedSubviews: [title, code, sample])
        header.spacing = 10
        header.alignment = .center

        let rgb = initial.rgb
        let channels: [(String, UIColor, Float)] = [
            ("RED", UIColor(red: 1, green: 0.33, blue: 0.42, alpha: 1), rgb.x),
            ("GREEN", UIColor(red: 0.41, green: 0.85, blue: 0.53, alpha: 1), rgb.y),
            ("BLUE", UIColor(red: 0.35, green: 0.65, blue: 1, alpha: 1), rgb.z),
        ]
        let rows = channels.map { name, tint, value in
            let label = UI.label(name, UI.font(10, .bold), UI.dim)
            label.widthAnchor.constraint(equalToConstant: 54).isActive = true
            let slider = UISlider()
            slider.maximumValue = 255
            slider.value = value * 255
            slider.minimumTrackTintColor = tint
            slider.accessibilityLabel = name
            slider.addTarget(self, action: #selector(updateSample), for: .valueChanged)
            sliders.append(slider)
            let row = UIStackView(arrangedSubviews: [label, slider])
            row.alignment = .center
            row.spacing = 8
            row.heightAnchor.constraint(equalToConstant: 44).isActive = true
            return row
        }

        let cancel = GlowButton("CANCEL", size: 12)
        cancel.onTap = { [weak self] in self?.dismiss(animated: true) }
        let use = GlowButton("USE COLOR", filled: true, size: 12)
        use.onTap = { [weak self] in
            guard let self else { return }
            self.onChoose(self.color)
            self.dismiss(animated: true)
        }
        let actions = UIStackView(arrangedSubviews: [cancel, use])
        actions.distribution = .fillEqually
        actions.spacing = 8
        actions.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let preview = UI.scrollColumn(UI.stack([header, actions], spacing: 22), centered: true)
        let content = UI.columns(preview, UI.scrollColumn(UI.stack(rows, spacing: 6), centered: true))
        view.addSubview(content)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: UI.gutter),
            content.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -UI.gutter),
            content.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
        ])
        updateSample()
    }

    private var color: GaragePaint {
        GaragePaint(sliders.reduce(0) { ($0 << 8) | UInt32($1.value.rounded()) })
    }

    @objc private func updateSample() {
        sample.backgroundColor = UI.color(color.rgb)
        code.text = String(format: "#%06X", color.hex)
        sliders.forEach { $0.accessibilityValue = "\(Int($0.value.rounded())) / 255" }
    }
}


private final class GaragePartCard: UIButton {
    let part: CarPart?
    private let titleText = UI.label("", UI.font(10, .bold, wide: false), .white, align: .center)
    private let picture = UIImageView()
    var active = false { didSet { updateAppearance() } }

    init(part: CarPart?, action: @escaping () -> Void) {
        self.part = part
        super.init(frame: .zero)
        layer.cornerRadius = 8
        layer.borderWidth = 1
        var title = part?.title ?? "None"
        if let part, !Profile.shared.owns(part) { title += " · " + Economy.credits(part.price) }
        titleText.text = title
        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.contentMode = .scaleAspectFit
        if let part { picture.image = GarageStudio.thumbnail(for: part) }
        accessibilityLabel = title
        addAction(UIAction { _ in action() }, for: .touchUpInside)
        [picture, titleText].forEach(addSubview)
        let titleCenter = part == nil ? titleText.centerYAnchor.constraint(equalTo: centerYAnchor)
            : titleText.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            picture.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            picture.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            picture.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            titleText.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleText.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleCenter,
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.7 : 1 } }

    private func updateAppearance() {
        backgroundColor = active ? UIColor(red: 0.08, green: 0.18, blue: 0.23, alpha: 1) : UI.panel
        layer.borderColor = (active ? UI.cyan : UIColor(white: 1, alpha: 0.13)).cgColor
        titleText.textColor = active ? UI.cyan : .white
        accessibilityTraits = active ? [.button, .selected] : .button
    }
}

private final class GarageSwatch: UIButton {
    let color: GaragePaint
    var active = false {
        didSet {
            layer.borderColor = (active ? UIColor.white : UIColor(white: 1, alpha: 0.14)).cgColor
            accessibilityTraits = active ? [.button, .selected] : .button
        }
    }

    init(color: GaragePaint, action: @escaping () -> Void) {
        self.color = color
        super.init(frame: .zero)
        layer.cornerRadius = 8
        layer.borderWidth = 1.5
        backgroundColor = UI.color(color.rgb)
        accessibilityLabel = String(format: "Paint #%06X", color.hex)
        addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.7 : 1 } }
}

private final class GarageStudio: SCNView {
    private let cameraNode = SCNNode()
    private var model: SCNNode?
    private var angle: Float = .pi + 0.73
    private var span: Float = 2.22

    init() {
        super.init(frame: .zero, options: nil)
        let scene = Self.makeScene()
        scene.background.contents = UIColor(red: 0.046, green: 0.072, blue: 0.115, alpha: 1)
        scene.rootNode.addChildNode(Self.platform())
        self.scene = scene
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.usesOrthographicProjection = true
        cameraNode.camera?.zNear = 0.1
        cameraNode.camera?.zFar = 36
        scene.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode
        layer.cornerRadius = 14
        layer.borderColor = UIColor(red: 0.14, green: 0.24, blue: 0.33, alpha: 1).cgColor
        layer.borderWidth = 1
        clipsToBounds = true
        preferredFramesPerSecond = 30
        antialiasingMode = .multisampling4X
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(rotate(_:))))
        accessibilityLabel = "3D car preview"
    }

    required init?(coder: NSCoder) { fatalError() }

    func display(_ design: CarDesign) {
        model?.removeFromParentNode()
        let car = CarMesh.build(design).node
        CarMesh.setThrust(0, on: car)
        car.position.y = CarMesh.axleHeight
        scene?.rootNode.addChildNode(car)
        model = car
        span = max(2.22, design.frontCollisionExtent, design.rearCollisionExtent, design.halfWidth)
        placeCamera()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeCamera()
    }

    func focus(on slot: CarSlot) {
        switch slot {
        case .rear, .motor: angle = -0.60
        case .wheels: angle = -.pi / 2
        default: angle = .pi + 0.73
        }
        placeCamera()
    }

    @objc private func rotate(_ drag: UIPanGestureRecognizer) {
        angle -= Float(drag.translation(in: self).x) * 0.012
        drag.setTranslation(.zero, in: self)
        placeCamera()
    }

    private func placeCamera() {
        let aspect = Float(bounds.width / max(bounds.height, 1))
        // The car is as wide as the view when it sits side-on, with room to stand end-on.
        cameraNode.camera?.orthographicScale = Double(span * max(0.8, 1 / max(0.15, aspect)))
        cameraNode.simdPosition = SIMD3(sin(angle) * 9, 5.5, cos(angle) * 9)
        cameraNode.simdLook(at: SIMD3(0, 0.55, 0))
    }

    private static func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.lightingEnvironment.contents = ProceduralTextures.studio
        scene.lightingEnvironment.intensity = 0.33
        let fixtures: [(UIColor, CGFloat, SCNVector3)] = [
            (.white, 1500, SCNVector3(-0.94, -0.55, 0)),
            (UIColor(red: 0.29, green: 0.71, blue: 1, alpha: 1), 550, SCNVector3(-0.41, 2.28, 0)),
        ]
        for (color, intensity, rotation) in fixtures {
            let fixture = SCNNode()
            let light = SCNLight()
            light.type = .directional
            light.color = color
            light.intensity = intensity
            // The key light grounds the car on the platform.
            if intensity > 1000 {
                light.castsShadow = true
                light.shadowMode = .forward
                light.shadowMapSize = CGSize(width: 2048, height: 2048)
                light.shadowSampleCount = 16
                light.shadowRadius = 4
                light.shadowColor = UIColor(white: 0, alpha: 0.6)
            }
            fixture.light = light
            fixture.eulerAngles = rotation
            scene.rootNode.addChildNode(fixture)
        }
        return scene
    }

    private static func platform() -> SCNNode {
        let stage = SCNNode()
        let pad = SCNCylinder(radius: 3.21, height: 0.065)
        pad.radialSegmentCount = 64
        pad.firstMaterial?.lightingModel = .physicallyBased
        pad.firstMaterial?.diffuse.contents = UIColor(red: 0.08, green: 0.14, blue: 0.20, alpha: 1)
        pad.firstMaterial?.roughness.contents = 0.71
        let base = SCNNode(geometry: pad)
        base.position.y = -0.036
        stage.addChildNode(base)

        for (radius, width, tint) in [(3.08, 0.028, UIColor(red: 0.18, green: 0.52, blue: 0.67, alpha: 1)),
                                      (2.38, 0.016, UIColor(red: 0.14, green: 0.29, blue: 0.40, alpha: 1))] {
            let ring = SCNTube(innerRadius: CGFloat(radius - width), outerRadius: CGFloat(radius), height: 0.005)
            ring.radialSegmentCount = 64
            ring.firstMaterial?.lightingModel = .constant
            ring.firstMaterial?.diffuse.contents = tint
            let node = SCNNode(geometry: ring)
            node.position.y = 0.004
            stage.addChildNode(node)
        }
        return stage
    }

    private static var thumbnails: [CarPart: UIImage] = [:]
    private static let thumbnailRenderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)

    static func thumbnail(for part: CarPart) -> UIImage {
        if let image = thumbnails[part] { return image }
        let scene = makeScene()
        scene.background.contents = UIColor.clear
        let object = GarageMesh.preview(part)
        scene.rootNode.addChildNode(object)
        let (lower, upper) = object.boundingBox
        let minPoint = SIMD3(lower.x, lower.y, lower.z)
        let maxPoint = SIMD3(upper.x, upper.y, upper.z)
        let center = (minPoint + maxPoint) / 2
        let dimensions = maxPoint - minPoint
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        let rear: Float = part.slot == .rear || part.slot == .motor || part.slot == .wing ? 1 : -1
        let direction: SIMD3<Float> = part.slot == .wheels ? SIMD3(1, 0.47, 0.64) : SIMD3(-0.68, 0.66, rear)
        let normal = simd_normalize(direction)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), normal))
        let up = simd_cross(normal, right)
        let half = dimensions / 2
        let width = simd_dot(abs(right), half)
        let height = simd_dot(abs(up), half)
        // The thumbnail is rendered at 2:1, so its horizontal half-span is twice the camera scale.
        camera.camera?.orthographicScale = Double(max(width / 2, height, 0.13) * 1.10)
        camera.simdPosition = center + direction * 6
        camera.simdLook(at: center)
        scene.rootNode.addChildNode(camera)
        thumbnailRenderer.scene = scene
        thumbnailRenderer.pointOfView = camera
        let image = thumbnailRenderer.snapshot(atTime: 0, with: CGSize(width: 224, height: 112),
                                                antialiasingMode: .multisampling4X)
        thumbnailRenderer.scene = nil
        thumbnailRenderer.pointOfView = nil
        thumbnails[part] = image
        return image
    }
}
