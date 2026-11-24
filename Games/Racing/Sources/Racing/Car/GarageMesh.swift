import SceneKit
import simd

/// Procedural meshes share the rounded body profiles and emissive materials of the race roster.
enum GarageMesh {
    private typealias Shell = CarMesh.Shell
    private typealias Slot = CarMesh.Slot
    private typealias Station = (z: Float, width: Float, bottom: Float, top: Float)
    private typealias Nozzle = (position: SIMD3<Float>, radius: Float)

    /// What a build wears beyond its parts and paint: lettering, a maker's own racing graphics
    /// in place of the frame's, and the colour of its light strips.
    private struct Dress {
        var markings: CarMesh.Markings?
        var livery: (style: Int, color: SIMD3<Float>)?
        var light = SIMD3<Float>(0.27, 0.87, 1)
    }

    static func build(_ build: GarageBuild, glow: SIMD3<Float>, markings: CarMesh.Markings? = nil,
                      livery: (style: Int, color: SIMD3<Float>)? = nil) -> CarModel {
        let dress = Dress(markings: markings, livery: livery, light: glow)
        let size = GarageDimensions(build)
        let car = SCNNode()
        let ground = SCNNode()
        ground.position.y = -CarMesh.axleHeight
        car.addChildNode(ground)

        let chassis = build.part(at: .frame) ?? .sprint
        let frame = makePart(chassis, size: size, paint: build.paint(for: .frame), on: chassis, dress: dress)
        ground.addChildNode(frame)
        for slot in [CarSlot.front, .rear, .motor] {
            guard let part = build.part(at: slot) else { continue }
            let node = makePart(part, size: size, paint: build.paint(for: slot), on: chassis, dress: dress)
            switch slot {
            case .front: node.position.z = -size.end
            case .rear: node.position.z = size.end
            default: node.simdPosition = motorMount(size)
            }
            frame.addChildNode(node)

            if let socket = part.attachment {
                let mount = SCNNode()
                mount.name = "\(socket.rawValue)-mount"
                mount.simdPosition = addonMount(for: part)
                node.addChildNode(mount)
                if let addon = build.part(at: socket) {
                    mount.addChildNode(makePart(addon, size: size, paint: build.paint(for: socket), on: chassis,
                                                dress: dress))
                }
            }
        }

        let motor = build.part(at: .motor) ?? .pulse
        let exhausts = nozzles(for: motor).map { ($0.position + motorMount(size) + ground.simdPosition, $0.radius) }
        car.addChildNode(CarMesh.makeFlames(exhausts, glow: glow))

        // Tail lights on the rear part, and along the wing's trailing edge when one is fitted.
        let rear = build.part(at: .rear) ?? .cutTail
        let tailEnd = SIMD3<Float>(0, -CarMesh.axleHeight, size.end)
        var lamps = tailLamps(rear).map { (centre: $0.centre + tailEnd, size: $0.size) }
        if let wing = build.part(at: .wing) {
            let (high, span) = wingSize(wing)
            lamps.append((SIMD3(0, high + 0.055, 0.412) + tailEnd + addonMount(for: rear),
                          SIMD3(span * 1.56, 0.026, 0.024)))
        }
        car.addChildNode(CarMesh.makeTailLights(lamps))

        let suspension = suspensionMesh(size)
        ground.addChildNode(suspension)
        let radii = WheelPosition.allCases.map { $0.isFront ? size.frontRadius : size.rearRadius }
        let wheels = zip(WheelPosition.allCases, radii).map { position, radius in
            let node = wheel(build.part(at: .wheels) ?? .slick, radius: radius, width: size.tyreWidth,
                             paint: build.paint(for: .wheels, wheel: position), inboard: -position.side)
            node.name = position.rawValue
            node.simdPosition = SIMD3(position.side * size.track, radius - CarMesh.axleHeight,
                                      position.isFront ? -size.axle : size.axle)
            car.addChildNode(node)
            return node
        }
        let frontOffset = SIMD3<Float>(0, -CarMesh.axleHeight, -size.end)
        let mounts = frontLights(build.part(at: .front) ?? .needle).map {
            CarMesh.HeadlightMount(centre: $0.centre + frontOffset, size: $0.size)
        }
        return CarModel(node: car, wheels: wheels, radii: radii, headlightMounts: mounts)
    }

    static func preview(_ part: CarPart) -> SCNNode {
        var build = GarageBuild()
        build.equip(part, at: part.slot)
        let size = GarageDimensions(build)
        if part.slot == .wheels {
            return wheel(part, radius: size.rearRadius, width: size.tyreWidth, paint: part.slot.factoryPaint,
                         inboard: 1)
        }
        let node = makePart(part, size: size, paint: part.slot.factoryPaint, on: build.part(at: .frame) ?? .sprint)
        if part.slot == .rear { node.addChildNode(CarMesh.makeTailLights(tailLamps(part))) }
        return node
    }

    /// `chassis` is the frame the part goes on: it sets the livery the bodywork shares.
    private static func makePart(_ part: CarPart, size: GarageDimensions, paint: GaragePaint,
                                 on chassis: CarPart, dress: Dress = Dress()) -> SCNNode {
        var shell = Shell()
        // The bodywork wears the racing graphics. The nose and tail hang off the ends of the
        // frame, so theirs carry on from it.
        let ink = dress.livery?.color ?? graphics(on: paint)
        var livery: (SIMD3<Float>, Int)?
        if part.slot == .frame || part.slot == .front || part.slot == .rear {
            livery = (ink, dress.livery?.style ?? liveryStyle(chassis))
            shell.origin.z = part.slot == .front ? -size.end : (part.slot == .rear ? size.end : 0)
        }
        let markings = dress.markings
        switch part.slot {
        case .frame:
            frame(part, size: size, shell: &shell,
                  number: markings.map { ($0.number, ink, CarMesh.legible(paint.rgb, on: ink)) })
        case .front: front(part, shell: &shell)
        case .rear: rear(part, shell: &shell)
        case .motor: motor(part, shell: &shell)
        case .splitter: splitter(part, shell: &shell)
        case .wing: wing(part, shell: &shell, name: markings.map { ($0.maker, graphics(on: paint)) })
        case .wheels: preconditionFailure("Wheel parts use their own rotating carrier")
        }
        return node(named: part.rawValue, shell: shell, paint: paint, livery: livery, light: dress.light)
    }

    private static func liveryStyle(_ frame: CarPart) -> Int {
        switch frame {
        case .vector: return 1
        case .atlas: return 2
        default: return 0
        }
    }

    /// Graphics have to read on any paint: a deep shade of it when it is bright, white when it is dark.
    private static func graphics(on paint: GaragePaint) -> SIMD3<Float> {
        let color = paint.rgb
        let bright = simd_dot(color, SIMD3<Float>(0.299, 0.587, 0.114)) > 0.45
        return bright ? color * 0.16 + SIMD3<Float>(0.02, 0.03, 0.05) : SIMD3<Float>(0.93, 0.95, 0.98)
    }

    private static func node(named name: String, shell: Shell, paint: GaragePaint, detailed: Bool = true,
                             livery: (SIMD3<Float>, Int)? = nil, light: SIMD3<Float> = Dress().light) -> SCNNode {
        let color = paint.rgb
        let trim = color * 0.67 + SIMD3<Float>(0.22, 0.25, 0.28)
        let materials = CarMesh.materials(paint: color, accent: trim, light: light, detailed: detailed,
                                          livery: livery)
        let result = shell.node(materials: materials)
        result.name = name
        return result
    }

    /// Lofts a body through `stations` and hands back its rings, for anything laid on its faces.
    @discardableResult
    private static func panel(_ shell: inout Shell, _ slot: Slot, x: Float = 0,
                              roof: Float = 0.74, _ stations: [Station]) -> [[SIMD3<Float>]] {
        let rings = stations.map {
            CarMesh.section(x: x, z: $0.z, halfWidth: $0.width, top: $0.top, bottom: $0.bottom,
                            chine: 0.43, roof: roof)
        }
        // Round each change in taper with a quadratic fillet. The middle of each panel
        // stays straight for lettering, and the ends still meet their attachment points.
        var skin = [rings[0]]
        for i in 1..<(rings.count - 1) {
            let corner = rings[i]
            let before = zip(corner, rings[i - 1]).map { $0 + ($1 - $0) * 0.24 }
            let after = zip(corner, rings[i + 1]).map { $0 + ($1 - $0) * 0.24 }
            skin.append(before)
            skin.append(corner.indices.map { (before[$0] + 2 * corner[$0] + after[$0]) * 0.25 })
            skin.append(after)
        }
        skin.append(rings[rings.count - 1])
        shell.loft(slot, skin)
        return skin
    }

    private static func frame(_ part: CarPart, size: GarageDimensions, shell: inout Shell,
                              number: (Int, board: SIMD3<Float>, ink: SIMD3<Float>)? = nil) {
        let w = size.bodyWidth, h = size.deckHeight, end = size.end
        panel(&shell, .metal, roof: 0.91, [
            (-end - 0.05, w * 0.61, 0.25, 0.39), (-end * 0.64, w, 0.24, 0.41),
            (end * 0.67, w, 0.24, 0.41), (end + 0.05, w * 0.62, 0.25, 0.39),
        ])

        let core = part == .atlas ? w * 0.65 : w
        let hull = panel(&shell, .paint, roof: part == .sprint ? 0.49 : 0.69, [
            (-end - 0.06, core * 0.47, 0.31, h * 0.89), (-end * 0.56, core * 0.88, 0.33, h + 0.05),
            (-end * 0.12, core, 0.33, h + 0.13), (end * 0.34, core * 0.91, 0.33, h + 0.06),
            (end + 0.05, core * 0.61, 0.32, h),
        ])
        // The race number on its board, on the bonnet ahead of the canopy.
        if let (number, board, ink) = number {
            let bonnet = CarMesh.Face.roof(hull[0], hull[1])
            shell.decal(String(number), color: ink, plate: board, centre: bonnet.centre - SIMD3(0, 0, 0.03),
                        normal: bonnet.normal, up: SIMD3(0, 0, -1), height: min(0.3, bonnet.length * 0.5),
                        maxWidth: bonnet.rise * 0.85)
        }

        if part != .sprint {
            for side: Float in [-1, 1] {
                let x = side * w * (part == .atlas ? 0.94 : 0.75)
                let span = part == .atlas ? w * 0.32 : w * 0.40
                panel(&shell, .paint, x: x, [
                    (-end * 0.84, span * 0.55, 0.33, h - 0.09),
                    (-end * 0.40, span, 0.31, h + 0.02), (end * 0.24, span, 0.30, h + 0.08),
                    (end * 0.78, span * 0.68, 0.31, h - 0.08),
                ])
                shell.box(.glow, centre: SIMD3(x + side * span * 0.63, h - 0.085, -end * 0.28),
                          size: SIMD3(0.035, 0.025, end * 0.49))
                for i in 0..<3 {
                    shell.box(.metal, centre: SIMD3(x, h + 0.055, end * 0.10 + Float(i) * 0.083),
                              size: SIMD3(span, 0.041, 0.039))
                }
            }
        }

        let glassWidth = core * (part == .atlas ? 0.83 : 0.68)
        let rise: Float = part == .sprint ? 0.30 : 0.40
        // Glass tint grades from the sill to the crown.
        let nose = -end * 0.62, tail = end * 0.24, sill = h + 0.04, crown = h + rise + 0.015
        shell.mapping = { p, _, _ in SIMD2((p.z - nose) / (tail - nose), (p.y - sill) / (crown - sill)) }
        let canopy = panel(&shell, .glass, roof: 0.56, [
            (nose, glassWidth * 0.66, sill, h + 0.10),
            (-end * 0.27, glassWidth, h + 0.09, h + rise),
            (-end * 0.02, glassWidth * 0.94, h + 0.09, crown),
            (tail, glassWidth * 0.72, sill, h + 0.15),
        ])
        shell.mapping = nil
        // A bow over the glass where the windscreen meets the roof.
        let bowZ = -end * 0.27
        // Sample the finished canopy so the trim follows the curved windscreen precisely.
        func bowRing(at z: Float) -> [SIMD3<Float>] {
            let i = canopy.firstIndex { $0[0].z >= z }!
            let a = canopy[i - 1], b = canopy[i]
            let t = (z - a[0].z) / (b[0].z - a[0].z)
            return zip(a, b).map { start, finish in
                let p = start + (finish - start) * t
                return SIMD3(p.x * 1.025, p.y + 0.009, z)
            }
        }
        shell.loft(.accent, [bowRing(at: bowZ - 0.028), bowRing(at: bowZ + 0.028)])
        for side: Float in [-1, 1] {
            shell.box(.accent, centre: SIMD3(side * glassWidth, h + 0.10, -end * 0.27),
                      size: SIMD3(0.09, 0.046, end * 0.56))
        }
    }

    private static func frontLights(_ part: CarPart) -> [CarMesh.HeadlightMount] {
        let centre: SIMD3<Float>
        let size: SIMD3<Float>
        switch part {
        case .plow:
            centre = SIMD3(0.62, 0.405, -0.665)
            size = SIMD3(0.24, 0.034, 0.057)
        case .fork:
            centre = SIMD3(0.77, 0.43, -0.873)
            size = SIMD3(0.24, 0.038, 0.032)
        default:
            centre = SIMD3(0.17, 0.366, -0.403)
            size = SIMD3(0.11, 0.027, 0.03)
        }
        return [-centre.x, centre.x].map {
            CarMesh.HeadlightMount(centre: SIMD3($0, centre.y, centre.z), size: size)
        }
    }

    private static func front(_ part: CarPart, shell: inout Shell) {
        switch part {
        case .plow:
            panel(&shell, .paint, [
                (-0.72, 0.68, 0.27, 0.40), (-0.63, 0.99, 0.25, 0.56),
                (-0.46, 0.87, 0.26, 0.66), (-0.26, 0.48, 0.27, 0.62), (0.14, 0.30, 0.32, 0.51),
            ])
            panel(&shell, .metal, [(-0.731, 0.46, 0.28, 0.35), (-0.62, 0.53, 0.27, 0.43)])
        case .fork:
            panel(&shell, .metal, [
                (-0.61, 0.91, 0.29, 0.41), (-0.46, 0.86, 0.31, 0.48), (0.14, 0.29, 0.32, 0.50),
            ])
            for side: Float in [-1, 1] {
                panel(&shell, .paint, x: side * 0.77, [
                    (-0.87, 0.26, 0.31, 0.47), (-0.69, 0.39, 0.29, 0.61), (-0.45, 0.28, 0.32, 0.67),
                ])
                shell.box(.accent, centre: SIMD3(side * 0.77, 0.603, -0.60),
                          size: SIMD3(0.16, 0.038, 0.17))
            }
        default:
            panel(&shell, .paint, roof: 0.63, [
                (-0.40, 0.31, 0.28, 0.39), (-0.29, 0.54, 0.28, 0.44), (0.14, 0.37, 0.30, 0.52),
            ])
            shell.box(.metal, centre: SIMD3(0, 0.29, -0.22), size: SIMD3(0.86, 0.099, 0.22))
        }
        for lamp in frontLights(part) { shell.box(.glow, centre: lamp.centre, size: lamp.size) }
        if part.attachment != nil { mountPads(&shell, mount: addonMount(for: part), span: 0.33) }
    }

    private static func rear(_ part: CarPart, shell: inout Shell) {
        switch part {
        case .flightDeck:
            panel(&shell, .paint, [
                (-0.13, 0.35, 0.31, 0.50), (0.19, 0.65, 0.26, 0.59),
                (0.50, 1.04, 0.30, 0.65), (0.76, 0.85, 0.37, 0.55),
            ])
            for side: Float in [-1, 1] {
                shell.box(.accent, centre: SIMD3(side * 0.76, 0.585, 0.63),
                          size: SIMD3(0.13, 0.074, 0.24))
            }
        case .twinTail:
            panel(&shell, .metal, [(-0.14, 0.31, 0.31, 0.54), (0.54, 0.84, 0.28, 0.46)])
            for side: Float in [-1, 1] {
                panel(&shell, .paint, x: side * 0.76, [
                    (0.37, 0.29, 0.34, 0.57), (0.60, 0.38, 0.30, 0.74), (0.86, 0.26, 0.38, 0.66),
                ])
            }
            shell.box(.accent, centre: SIMD3(0, 0.53, 0.49), size: SIMD3(1.16, 0.17, 0.27))
        default:
            panel(&shell, .paint, [
                (-0.13, 0.45, 0.31, 0.48), (0.16, 0.49, 0.27, 0.52), (0.39, 0.31, 0.34, 0.44),
            ])
        }
        if part.attachment != nil { mountPads(&shell, mount: addonMount(for: part), span: 0.49) }
    }

    /// Where each rear part carries its tail lights, in the part's own space.
    private static func tailLamps(_ part: CarPart) -> [(centre: SIMD3<Float>, size: SIMD3<Float>)] {
        switch part {
        case .flightDeck:
            return ([-1, 1] as [Float]).map { (SIMD3($0 * 0.65, 0.487, 0.766), SIMD3(0.21, 0.041, 0.031)) }
        case .twinTail:
            return ([-1, 1] as [Float]).map { (SIMD3($0 * 0.76, 0.555, 0.87), SIMD3(0.33, 0.045, 0.031)) }
        default:
            return [(SIMD3(0, 0.411, 0.398), SIMD3(0.37, 0.029, 0.026))]
        }
    }

    /// Height of a wing's blade above its mount, and its half-span.
    private static func wingSize(_ part: CarPart) -> (high: Float, span: Float) {
        part == .doubleDeck ? (0.79, 1.23) : (0.46, 0.99)
    }

    private static func addonMount(for part: CarPart) -> SIMD3<Float> {
        switch part {
        case .plow: return SIMD3(0, 0.51, -0.53)
        case .fork: return SIMD3(0, 0.43, -0.68)
        case .flightDeck: return SIMD3(0, 0.61, 0.45)
        default: return SIMD3(0, 0.61, 0.49)
        }
    }

    private static func mountPads(_ shell: inout Shell, mount: SIMD3<Float>, span: Float) {
        for side: Float in [-1, 1] {
            let pad = mount + SIMD3(side * span, 0.025, 0)
            shell.box(.metal, centre: pad, size: SIMD3(0.18, 0.085, 0.16))
            shell.box(.accent, centre: pad + SIMD3(0, 0.047, 0), size: SIMD3(0.066, 0.018, 0.076))
        }
    }

    private static func splitter(_ part: CarPart, shell: inout Shell) {
        if part == .divePlanes {
            shell.box(.metal, centre: SIMD3(0, 0.073, -0.04), size: SIMD3(1.54, 0.073, 0.17))
            for side: Float in [-1, 1] {
                panel(&shell, .paint, x: side * 0.88, [
                    (-0.46, 0.27, 0.09, 0.14), (-0.25, 0.39, 0.11, 0.19), (0.12, 0.24, 0.15, 0.21),
                ])
                shell.box(.accent, centre: SIMD3(side * 1.20, 0.22, -0.21), size: SIMD3(0.07, 0.17, 0.24))
            }
        } else {
            panel(&shell, .paint, roof: 0.92, [
                (-0.42, 0.58, 0.07, 0.12), (-0.29, 1.07, 0.08, 0.14), (0.10, 0.78, 0.11, 0.16),
            ])
            shell.box(.accent, centre: SIMD3(0, 0.135, -0.34), size: SIMD3(0.71, 0.025, 0.085))
        }
    }

    private static func wing(_ part: CarPart, shell: inout Shell, name: (String, SIMD3<Float>)? = nil) {
        // A wing is a lettering surface: no seams under the name.
        shell.plain = true
        let (high, span) = wingSize(part)
        for side: Float in [-1, 1] {
            shell.slab(.metal, root: (SIMD3(side * 0.49, 0.03, -0.07), SIMD3(side * 0.49, 0.03, 0.08)),
                       tip: (SIMD3(side * 0.71, high, 0.06), SIMD3(side * 0.71, high, 0.24)),
                       thickness: SIMD3(0.046, 0, 0))
            shell.box(.accent, centre: SIMD3(side * span, high - 0.055, 0.18),
                      size: SIMD3(0.075, 0.23, 0.46))
        }
        let blade = panel(&shell, .paint, roof: 1, [
            (-0.11, span * 0.82, high, high + 0.07), (0.05, span, high + 0.015, high + 0.09),
            (0.40, span * 0.92, high + 0.041, high + 0.07),
        ])
        // The frame's name across the wing, where the chasing pack reads it.
        if let (name, ink) = name {
            let top = CarMesh.Face.roof(blade[blade.count - 2], blade[blade.count - 1])
            shell.decal(name, color: ink, centre: top.centre, normal: top.normal, up: SIMD3(0, 0, -1),
                        height: top.length * 0.62, maxWidth: top.rise * 0.7)
        }
        if part == .doubleDeck {
            panel(&shell, .paint, roof: 1, [
                (-0.04, 0.74, 0.34, 0.41), (0.12, 0.93, 0.35, 0.43), (0.36, 0.84, 0.36, 0.42),
            ])
        }
    }

    private static func motorMount(_ size: GarageDimensions) -> SIMD3<Float> {
        SIMD3(0, size.deckHeight - 0.015, size.end - 0.42)
    }

    private static func nozzles(for part: CarPart) -> [Nozzle] {
        switch part {
        case .twinJet:
            return [(SIMD3(-0.30, 0.21, 0.78), 0.164), (SIMD3(0.30, 0.21, 0.78), 0.164)]
        case .reactor:
            return [(SIMD3(-0.34, 0.17, 0.76), 0.12), (SIMD3(0, 0.35, 0.80), 0.23),
                    (SIMD3(0.34, 0.17, 0.76), 0.12)]
        default:
            return [(SIMD3(0, 0.14, 0.71), 0.147)]
        }
    }

    private static func motor(_ part: CarPart, shell: inout Shell) {
        let width: Float = part == .pulse ? 0.24 : 0.47
        panel(&shell, .metal, [(-0.35, width * 0.8, -0.035, 0.12), (0.64, width, -0.03, 0.16)])
        if part == .reactor {
            panel(&shell, .paint, [
                (-0.31, 0.30, 0.07, 0.22), (-0.12, 0.38, 0.04, 0.61),
                (0.36, 0.39, 0.08, 0.56), (0.59, 0.31, 0.08, 0.47),
            ])
            for side: Float in [-1, 1] {
                shell.box(.glow, centre: SIMD3(side * 0.235, 0.557, 0.16), size: SIMD3(0.039, 0.075, 0.30))
            }
        }
        for (position, radius) in nozzles(for: part) {
            func ring(_ depth: Float, _ scale: Float) -> [SIMD3<Float>] {
                (0..<10).map { index in
                    let angle = Float(index) * 2 * .pi / 10
                    return position + SIMD3(cos(angle) * radius * scale, sin(angle) * radius * scale, depth)
                }
            }
            shell.loft(.paint, [ring(-0.94, 0.64), ring(-0.71, 1.14), ring(-0.27, 1.19), ring(-0.14, 0.91)])
            shell.loft(.metal, [ring(-0.25, 0.92), ring(-0.075, 1.03), ring(-0.02, 0.98)])
            shell.loft(.glow, [ring(-0.069, 0.76), ring(-0.014, 0.73)])
            shell.loft(.metal, [ring(-0.027, 0.35), ring(-0.009, 0.31)])
        }
    }

    private static func suspensionMesh(_ size: GarageDimensions) -> SCNNode {
        var shell = Shell()
        for position in WheelPosition.allCases {
            let z = position.isFront ? -size.axle : size.axle
            let radius = position.isFront ? size.frontRadius : size.rearRadius
            let hub = position.side * (size.track - size.tyreWidth * 0.42)
            let root = position.side * size.bodyWidth * 0.65
            for (delta, height) in [(Float(-0.19), Float(0.36)), (0.17, 0.44)] {
                shell.slab(.metal, root: (SIMD3(root, height, z + delta - 0.065),
                                         SIMD3(root, height, z + delta + 0.065)),
                           tip: (SIMD3(hub, radius, z - 0.046), SIMD3(hub, radius, z + 0.046)),
                           thickness: SIMD3(0, 0.036, 0))
            }
        }
        return node(named: "suspension", shell: shell, paint: CarSlot.frame.factoryPaint)
    }

    /// `inboard` is the side of the wheel that faces the car: +1 towards +x.
    private static func wheel(_ part: CarPart, radius: Float, width: Float, paint: GaragePaint,
                              inboard: Float) -> SCNNode {
        var shell = Shell()
        let segments = part == .wideTrack ? 20 : 24
        func ring(_ x: Float, _ radius: Float, sides: Int? = nil) -> [SIMD3<Float>] {
            let count = sides ?? segments
            return (0..<count).map { i in
                let angle = Float(i) * 2 * .pi / Float(count)
                return SIMD3(x, cos(angle) * radius, sin(angle) * radius)
            }
        }
        // Everything bolted to the axle is round, so it can turn with the wheel: a brake disc
        // and the carrier the suspension arms run into.
        var brake = Shell()
        let back = inboard * width * 0.51
        brake.loft(.metal, [ring(back + inboard * 0.030, radius * 0.60), ring(back + inboard * 0.052, radius * 0.60)])
        brake.loft(.metal, [ring(back, radius * 0.27), ring(back + inboard * 0.13, radius * 0.21)])
        for side: Float in [-1, 1] {
            let inner = side * width * 0.43
            let outer = side * width * 0.51
            let lip: Float = part == .aero ? 0.78 : 0.68
            shell.loft(.paint, [ring(inner, radius * lip), ring(outer, radius * lip * 0.96)])
            // Spokes, hub and its lock nut are on the face that shows.
            if side == inboard { continue }
            shell.loft(.metal, [ring(outer, radius * 0.30), ring(outer + side * 0.034, radius * 0.25)])
            shell.loft(.accent, [ring(outer + side * 0.034, radius * 0.15, sides: 6),
                                 ring(outer + side * 0.066, radius * 0.12, sides: 6)])
            for i in 0..<(part == .slick ? 3 : 6) {
                let angle = 2 * Float.pi * Float(i) / (part == .slick ? 3 : 6)
                let a = SIMD3<Float>(0, cos(angle), sin(angle))
                shell.slab(part == .aero ? .accent : .metal,
                           root: (SIMD3(outer + side * 0.014, 0, 0), SIMD3(outer + side * 0.015, 0.045, 0)),
                           tip: (a * radius * lip * 0.90 + SIMD3(outer + side * 0.02, 0, 0),
                                 a * radius * lip * 0.94 + SIMD3(outer + side * 0.02, 0.065, 0)),
                           thickness: SIMD3(0.011, 0, 0))
            }
        }
        // Panel seams belong on bodywork, not across a rim.
        let node = node(named: part.rawValue, shell: shell, paint: paint, detailed: false)
        node.addChildNode(SCNNode(geometry: brake.geometry(
            materials: Array(repeating: CarMesh.steel(), count: Slot.allCases.count))))
        var tyre = Shell()
        // Once round the wheel and once across the tread. A face on the join is unwrapped
        // towards its own centre, so the tread carries on over it.
        tyre.mapping = { p, _, centre in
            let middle = atan2(centre.z, centre.y)
            var angle = atan2(p.z, p.y)
            if angle - middle > .pi { angle -= 2 * .pi } else if middle - angle > .pi { angle += 2 * .pi }
            return SIMD2(angle / (2 * .pi), p.x / width + 0.5)
        }
        // The closed section follows the tire sidewalls without covering the colored rims.
        for side: Float in [-1, 1] {
            let edge = ring(side * width * 0.49, radius * 0.74)
            let sidewall = ring(side * width / 2, radius * 0.86)
            let shoulder = ring(side * width * 0.36, radius * 0.98)
            let crown = ring(0, radius)
            for i in 0..<segments {
                let j = (i + 1) % segments
                for (slot, inner, outer) in [(Slot.metal, edge, sidewall), (.metal, sidewall, shoulder), (.paint, shoulder, crown)] {
                    tyre.quad(slot, inner[i], inner[j], outer[j], outer[i], from: .zero)
                }
            }
        }
        // Wide Track carries its tread as blocks; the others have it cut into the rubber.
        let rubber = CarMesh.rubber()
        let tread = part == .wideTrack ? rubber : CarMesh.rubber(treadAround: radius)
        node.addChildNode(SCNNode(geometry: tyre.geometry(materials: [tread, rubber, rubber, rubber, rubber])))
        if part == .wideTrack {
            for i in 0..<segments {
                let angle = Float(i) * 2 * .pi / Float(segments)
                let block = SCNBox(width: CGFloat(width * 0.70), height: 0.025, length: 0.058, chamferRadius: 0.005)
                block.firstMaterial = rubber
                let tread = SCNNode(geometry: block)
                tread.simdPosition = SIMD3(i.isMultiple(of: 2) ? -0.04 : 0.04,
                                          cos(angle) * radius * 0.976, sin(angle) * radius * 0.976)
                tread.eulerAngles.x = angle
                node.addChildNode(tread)
            }
        }
        return node
    }
}
