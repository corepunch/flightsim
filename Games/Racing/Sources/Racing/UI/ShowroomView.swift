import SceneKit
import UIKit

/// A row of podiums in a dark showroom, one car on each. Dragging slides the whole row
/// under the finger (the camera tracks the drag one to one), and letting go springs to
/// the nearest podium, carrying the flick's momentum. The neighbours stay in view at the
/// edges, so it is obvious there is more to swipe to.
final class ShowroomView: SCNView, UIGestureRecognizerDelegate {
    /// Metres between podiums.
    private let spacing: Float = 5.4

    private let rig = SCNNode()
    private let cameraNode = SCNNode()
    private var stands: [SCNNode] = []
    private var turntables: [SCNNode] = []
    private var rings: [SCNMaterial] = []
    private var cars: [SCNNode?] = []

    /// Position along the row in podiums (0 = first).
    private var offset: Float = 0
    private var velocity: Float = 0
    private var target: Float = 0
    private var dragStart: Float = 0
    private var link: CADisplayLink?
    private(set) var index = 0

    /// Called as soon as a different podium is front and centre, even during a drag.
    var onIndexChange: ((Int) -> Void)?
    /// Called when the row comes to rest.
    var onSettle: ((Int) -> Void)?

    init() {
        super.init(frame: .zero, options: nil)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        let scene = SCNScene()
        // The same wash as the menus behind it, so the view has no visible edge.
        scene.background.contents = Self.wash
        // The floor fades into the wash before its horizon, so there's no seam.
        scene.fogColor = UIColor(red: 0.045, green: 0.06, blue: 0.11, alpha: 1)
        scene.fogStartDistance = 17
        scene.fogEndDistance = 34
        // The studio fills the shadows and puts reflections in the paint; the key light below
        // does the lighting, so each car has a bright side, a dark side and a shadow.
        scene.lightingEnvironment.contents = ProceduralTextures.studio
        scene.lightingEnvironment.intensity = 0.15
        self.scene = scene

        let floor = SCNFloor()
        floor.reflectivity = 0
        floor.reflectionFalloffEnd = 2.5
        floor.firstMaterial?.lightingModel = .constant
        floor.firstMaterial?.diffuse.contents = UIColor(red: 0.035, green: 0.045, blue: 0.08, alpha: 1)
        let floorNode = SCNNode(geometry: floor)
        floorNode.position.y = -0.05
        scene.rootNode.addChildNode(floorNode)

        for (color, intensity, angles) in [(UIColor.white, 1200.0, SCNVector3(-0.85, 0.55, 0)),
                                           (UIColor(red: 0.35, green: 0.7, blue: 1, alpha: 1), 420.0, SCNVector3(-0.3, 2.6, 0))] {
            let light = SCNNode()
            light.light = SCNLight()
            light.light?.type = .directional
            light.light?.color = color
            light.light?.intensity = CGFloat(intensity)
            light.eulerAngles = angles
            rig.addChildNode(light)
        }
        // The key light grounds each car on its podium.
        if let key = rig.childNodes.first?.light {
            key.castsShadow = true
            key.shadowMode = .forward
            key.shadowMapSize = CGSize(width: 2048, height: 2048)
            key.shadowSampleCount = 16
            key.shadowRadius = 4
            key.shadowColor = UIColor(white: 0, alpha: 0.6)
        }

        cameraNode.camera = SCNCamera()
        // Frame by width, so a tall showroom doesn't zoom in and hide the neighbours.
        cameraNode.camera?.projectionDirection = .horizontal
        cameraNode.camera?.fieldOfView = 30
        cameraNode.camera?.zNear = 0.5
        cameraNode.camera?.zFar = 80
        cameraNode.camera?.wantsHDR = true
        cameraNode.camera?.bloomIntensity = 0.4
        // Only real emitters (podium rings, glow strips, plumes) are bright enough to bloom.
        cameraNode.camera?.bloomThreshold = 1.6
        cameraNode.camera?.bloomBlurRadius = 8
        cameraNode.camera?.vignettingIntensity = 0.6
        cameraNode.camera?.vignettingPower = 0.8
        // A long lens from well back: the car fills the view without its near end ballooning
        // as it turns, and a sliver of each neighbour still shows.
        cameraNode.position = SCNVector3(0, 4.56, 10.42)
        cameraNode.look(at: SCNVector3(0, 0.45, 0))
        rig.addChildNode(cameraNode)
        scene.rootNode.addChildNode(rig)
        pointOfView = cameraNode

        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 60
        isPlaying = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { link?.invalidate() }

    /// Soft top and bottom edges, so the room dissolves into the screen around it.
    private let fade: CAGradientLayer = {
        let g = CAGradientLayer()
        g.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        g.locations = [0, 0.2, 0.84, 1]
        return g
    }()

    override func layoutSubviews() {
        super.layoutSubviews()
        fade.frame = bounds
        layer.mask = fade
    }

    // MARK: - Content

    /// Replaces every car. Keeps the row where it is if the count is unchanged.
    func setCars(_ designs: [CarDesign], selected: Int) {
        stands.forEach { $0.removeFromParentNode() }
        stands = []; turntables = []; rings = []; cars = []
        for (i, design) in designs.enumerated() {
            let stand = Self.podium()
            stand.simdPosition = SIMD3(Float(i) * spacing, 0, 0)
            scene?.rootNode.addChildNode(stand)
            stands.append(stand)
            rings.append(stand.childNode(withName: "ring", recursively: true)!.geometry!.firstMaterial!)
            let table = SCNNode()
            table.eulerAngles.y = 0.55
            stand.addChildNode(table)
            turntables.append(table)
            cars.append(nil)
            place(design, at: i)
        }
        index = min(max(selected, 0), max(designs.count - 1, 0))
        offset = Float(index)
        target = offset
        velocity = 0
        moveRig()
        highlight()
    }

    /// Swaps one car: after an upgrade, a paint job, a purchase.
    func update(_ design: CarDesign, at i: Int) {
        guard turntables.indices.contains(i) else { return }
        place(design, at: i)
    }

    private func place(_ design: CarDesign, at i: Int) {
        cars[i]?.removeFromParentNode()
        let car = CarMesh.build(design).node
        CarMesh.setThrust(0.12, on: car)
        // Every car is sized to its podium: big ones shrink a little, small ones grow a little.
        // The car's origin is on its axle line, so the lift scales with it to keep the tyres on the deck.
        let scale = min(1.3, 2.5 / Self.footprint(of: car))
        car.simdScale = SIMD3(repeating: scale)
        car.simdPosition = SIMD3(0, 0.265 + CarMesh.axleHeight * scale, 0)
        turntables[i].addChildNode(car)
        cars[i] = car
        accessibilityValue = design.name
    }

    /// Radius of the circle the car sweeps as it turns on its podium, exhaust plumes aside.
    private static func footprint(of car: SCNNode) -> Float {
        let flames = car.childNode(withName: "flames", recursively: false)
        flames?.removeFromParentNode()
        defer { flames.map(car.addChildNode) }
        let (low, high) = car.boundingBox
        return simd_length(SIMD2(max(-low.x, high.x), max(-low.z, high.z)))
    }

    func scroll(to i: Int, animated: Bool) {
        let clamped = min(max(i, 0), max(stands.count - 1, 0))
        target = Float(clamped)
        if animated {
            startLink()
        } else {
            offset = target
            velocity = 0
            moveRig()
            settle()
        }
    }

    // MARK: - Gestures

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: self)
        return abs(v.x) > abs(v.y)
    }

    /// Points of finger travel per podium.
    private var pointsPerStand: CGFloat { max(bounds.width * 0.78, 1) }

    @objc private func drag(_ pan: UIPanGestureRecognizer) {
        let count = Float(stands.count)
        switch pan.state {
        case .began:
            link?.invalidate(); link = nil
            dragStart = offset
        case .changed, .ended:
            var raw = dragStart - Float(pan.translation(in: self).x / pointsPerStand)
            // Rubber band past the ends.
            if raw < 0 { raw = -rubber(-raw) }
            if raw > count - 1 { raw = count - 1 + rubber(raw - (count - 1)) }
            offset = raw
            moveRig()
            liveIndex()
            guard pan.state == .ended else { break }
            velocity = -Float(pan.velocity(in: self).x / pointsPerStand)
            // Where the flick would coast to, rounded to a podium, at most two away. A quick
            // flick always moves at least one, like paging.
            var nearest = (offset + velocity * 0.18).rounded()
            if abs(velocity) > 0.6, nearest == dragStart.rounded() { nearest += velocity > 0 ? 1 : -1 }
            target = min(max(nearest, max(0, Float(index) - 2)), min(count - 1, Float(index) + 2))
            target = min(max(target, 0), count - 1)
            startLink()
        case .cancelled, .failed:
            target = offset.rounded()
            startLink()
        default: break
        }
    }

    private func rubber(_ x: Float) -> Float { 0.35 * (1 - 1 / (x * 1.6 + 1)) }

    @objc private func tap(_ g: UITapGestureRecognizer) {
        // Tapping a neighbour's half of the view brings it in.
        let x = g.location(in: self).x
        if x < bounds.width * 0.22, index > 0 { UI.haptic(); scroll(to: index - 1, animated: true) }
        if x > bounds.width * 0.78, index < stands.count - 1 { UI.haptic(); scroll(to: index + 1, animated: true) }
    }

    override func accessibilityIncrement() { scroll(to: index + 1, animated: true) }
    override func accessibilityDecrement() { scroll(to: index - 1, animated: true) }

    // MARK: - Motion

    private func startLink() {
        link?.invalidate()
        link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link?.add(to: .main, forMode: .common)
    }

    /// Critically damped spring towards the target podium.
    @objc private func step(_ l: CADisplayLink) {
        let dt = Float(min(1.0 / 30, l.targetTimestamp - l.timestamp))
        let stiffness: Float = 140
        let damping = 2 * stiffness.squareRoot() * 0.92
        let accel = stiffness * (target - offset) - damping * velocity
        velocity += accel * dt
        offset += velocity * dt
        moveRig()
        liveIndex()
        if abs(target - offset) < 0.0015 && abs(velocity) < 0.01 {
            offset = target
            velocity = 0
            moveRig()
            link?.invalidate(); link = nil
            settle()
        }
    }

    private func moveRig() {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        rig.simdPosition = SIMD3(offset * spacing, 0, 0)
        SCNTransaction.commit()
    }

    private func liveIndex() {
        let nearest = Int(min(max(offset.rounded(), 0), Float(max(stands.count - 1, 0))))
        guard nearest != index else { return }
        index = nearest
        if Profile.shared.haptics { UISelectionFeedbackGenerator().selectionChanged() }
        highlight()
        onIndexChange?(index)
    }

    private func settle() {
        liveIndex()
        onSettle?(index)
    }

    /// The front podium's ring lights up and its car turns; the rest face the camera at rest.
    private func highlight() {
        for (i, table) in turntables.enumerated() {
            table.removeAllActions()
            if i == index {
                table.runAction(.repeatForever(.rotateBy(x: 0, y: -2 * .pi, z: 0, duration: 16)))
                rings[i].emission.intensity = 2.2
            } else {
                table.runAction(.rotateTo(x: 0, y: 0.55, z: 0, duration: 0.5, usesShortestUnitArc: true))
                rings[i].emission.intensity = 0.35
            }
        }
    }

    // MARK: - Set dressing

    /// Vertical gradient matching `BackdropView` across the showroom's height.
    private static let wash: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 256)).image { ctx in
        let colors = [UIColor(red: 0.06, green: 0.085, blue: 0.16, alpha: 1).cgColor,
                      UIColor(red: 0.035, green: 0.045, blue: 0.08, alpha: 1).cgColor]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
        ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 256), options: [])
    }

    private static func podium() -> SCNNode {
        let stand = SCNNode()
        let base = SCNCylinder(radius: 2.6, height: 0.3)
        base.radialSegmentCount = 72
        let metal = SCNMaterial()
        metal.lightingModel = .physicallyBased
        metal.diffuse.contents = UIColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1)
        metal.metalness.contents = 0.85
        metal.roughness.contents = 0.3
        base.materials = [metal]
        let baseNode = SCNNode(geometry: base)
        baseNode.position.y = 0.1
        stand.addChildNode(baseNode)

        let top = SCNCylinder(radius: 2.48, height: 0.02)
        top.radialSegmentCount = 72
        let deck = SCNMaterial()
        deck.lightingModel = .physicallyBased
        deck.diffuse.contents = UIColor(red: 0.11, green: 0.13, blue: 0.19, alpha: 1)
        deck.roughness.contents = 0.55
        deck.metalness.contents = 0.4
        top.materials = [deck]
        let topNode = SCNNode(geometry: top)
        topNode.position.y = 0.255
        stand.addChildNode(topNode)

        let ring = SCNTube(innerRadius: 2.57, outerRadius: 2.64, height: 0.05)
        ring.radialSegmentCount = 72
        let glow = SCNMaterial()
        glow.lightingModel = .constant
        glow.diffuse.contents = UIColor.black
        glow.emission.contents = UI.cyan
        glow.emission.intensity = 0.35
        ring.materials = [glow]
        let ringNode = SCNNode(geometry: ring)
        ringNode.name = "ring"
        ringNode.position.y = 0.23
        stand.addChildNode(ringNode)
        return stand
    }
}
