import SceneKit
import simd

/// A built car: the chassis node and its four wheel nodes (front-left, front-right,
/// rear-left, rear-right), which are direct children so the vehicle physics can drive them.
struct CarModel {
    let node: SCNNode
    let wheels: [SCNNode]
    let radii: [Float]
    let headlightMounts: [CarMesh.HeadlightMount]
}

/// Turns a `CarDesign` into its model, and holds what every car's bodywork is made with: the
/// lofted shell, its materials, the plumes and the lights. Nose points along −Z. The node's
/// origin is `axleHeight` above the road, between the axles.
enum CarMesh {

    /// Height of the chassis origin above the road when the car sits level.
    static let axleHeight: Float = 0.42
    /// Underside of the bodywork above the road.
    private static let clearance: Float = 0.3

    enum Slot: Int, CaseIterable { case paint, accent, metal, glass, glow }

    struct HeadlightMount {
        let centre: SIMD3<Float>
        let size: SIMD3<Float>
    }

    /// What a car carries in lettering: its maker's name and its race number.
    struct Markings {
        let maker: String
        let number: Int
    }

    /// Shell faces wind outward from a reference point.
    struct Shell {
        var mesh = MeshBuilder(materialCount: Slot.allCases.count)
        /// Where this shell sits on the car, so textures run on from one part to the next.
        var origin = SIMD3<Float>.zero
        /// Surfaces added while this is set take no seams or graphics: they are for lettering.
        var plain = false
        /// Replaces the bodywork projection: texture coordinates for a point, given its face's
        /// normal and centre.
        var mapping: ((_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ centre: SIMD3<Float>) -> SIMD2<Float>)?

        /// Lettering laid over the bodywork: the image and the corners it is stretched between,
        /// from top left round by top right.
        private var decals: [(image: UIImage, corners: [SIMD3<Float>], normal: SIMD3<Float>)] = []

        /// The finished surface: gentle bends shade as curves, edges sharper than 37° stay crisp.
        func geometry(materials: [SCNMaterial]) -> SCNGeometry {
            var smooth = mesh
            smooth.smoothNormals()
            return smooth.geometry(materials: materials)
        }

        /// The surface with its lettering on top.
        func node(materials: [SCNMaterial]) -> SCNNode {
            let node = SCNNode(geometry: geometry(materials: materials))
            for decal in decals {
                var quad = MeshBuilder(materialCount: 1)
                let uvs: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
                let i = zip(decal.corners, uvs).map { quad.vertex($0, decal.normal, $1) }
                quad.triangle(0, i[0], i[3], i[2])
                quad.triangle(0, i[0], i[2], i[1])
                // Painted on under the same lacquer as the bodywork.
                let m = SCNMaterial()
                m.lightingModel = .physicallyBased
                m.diffuse.contents = decal.image
                m.diffuse.mipFilter = .linear
                m.diffuse.maxAnisotropy = 8
                m.metalness.contents = 0.5
                m.roughness.contents = 0.34
                m.clearCoat.contents = 1.0
                m.clearCoatRoughness.contents = 0.18
                m.writesToDepthBuffer = false
                let child = SCNNode(geometry: quad.geometry(materials: [m]))
                child.castsShadow = false
                node.addChildNode(child)
            }
            return node
        }

        /// Lays lettering on a flat face: centred at `centre`, facing along `normal`, its top
        /// towards `up`. It is `height` tall unless that would make it wider than `maxWidth`.
        mutating func decal(_ text: String, color: SIMD3<Float>, plate: SIMD3<Float>? = nil, centre: SIMD3<Float>,
                            normal: SIMD3<Float>, up: SIMD3<Float>, height: Float, maxWidth: Float) {
            let lettering = ProceduralTextures.lettering(text, color: color, plate: plate)
            let h = min(height, maxWidth / lettering.aspect), w = h * lettering.aspect
            let n = simd_normalize(normal)
            let right = simd_normalize(simd_cross(up, n)) * (w / 2)
            let top = simd_cross(n, simd_normalize(right)) * (h / 2)
            // Clear of the surface by less than anyone can see, and by more than the depth buffer can confuse.
            let c = centre + n * 0.006
            decals.append((lettering.image, [c - right + top, c + right + top, c + right - top, c - right - top], n))
        }

        mutating func tri(_ slot: Slot, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, from o: SIMD3<Float>) {
            var n = simd_cross(b - a, c - a)
            let length = simd_length(n)
            guard length > 1e-6 else { return }
            n /= length
            let outward = simd_dot(n, (a + b + c) / 3 - o) >= 0
            if !outward { n = -n }
            let centre = (a + b + c) / 3
            func map(_ p: SIMD3<Float>) -> SIMD2<Float> {
                plain ? ProceduralTextures.carBlank : mapping?(p, n, centre) ?? uv(p, n)
            }
            let i0 = mesh.vertex(a, n, map(a)), i1 = mesh.vertex(b, n, map(b)), i2 = mesh.vertex(c, n, map(c))
            if outward { mesh.triangle(slot.rawValue, i0, i1, i2) } else { mesh.triangle(slot.rawValue, i0, i2, i1) }
        }

        /// Box projection in metres onto the layout the car textures share: decks by distance
        /// from the centre line, flanks by height, both by position along the car, so a seam
        /// across the deck carries on down the flank. A shoulder counts as flank once it is
        /// steeper than 30 degrees, because that is where a side graphic belongs.
        private func uv(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> SIMD2<Float> {
            let q = p + origin, m = abs(n)
            if m.x > 0.5 && m.x >= m.z { return SIMD2(ProceduralTextures.carFlank + q.y, q.z) }
            return m.z > m.y ? SIMD2(q.x, q.y) : SIMD2(q.x, q.z)
        }

        mutating func quad(_ slot: Slot, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                           from o: SIMD3<Float>) {
            tri(slot, a, b, c, from: o)
            tri(slot, a, c, d, from: o)
        }

        /// Skins consecutive rings (same point count) and caps both ends.
        mutating func loft(_ slot: Slot, _ rings: [[SIMD3<Float>]], endCap: Slot? = nil) {
            func centre(_ r: [SIMD3<Float>]) -> SIMD3<Float> { r.reduce(.zero, +) / Float(r.count) }
            for i in 0..<(rings.count - 1) {
                let a = rings[i], b = rings[i + 1]
                let o = (centre(a) + centre(b)) / 2
                for k in 0..<a.count {
                    let k1 = (k + 1) % a.count
                    quad(slot, a[k], a[k1], b[k1], b[k], from: o)
                }
            }
            let last = rings.count - 1
            for (ring, adjacent, capSlot) in [(rings[0], rings[1], slot),
                                              (rings[last], rings[last - 1], endCap ?? slot)] {
                let c = centre(ring)
                let inside = (c + centre(adjacent)) / 2
                for k in 0..<ring.count { tri(capSlot, c, ring[k], ring[(k + 1) % ring.count], from: inside) }
            }
        }

        /// Thin tapered slab between a root edge and a tip edge (suspension arms, struts).
        mutating func slab(_ slot: Slot, root: (SIMD3<Float>, SIMD3<Float>), tip: (SIMD3<Float>, SIMD3<Float>),
                           thickness: SIMD3<Float>) {
            loft(slot, [
                [root.0 - thickness, root.1 - thickness, root.1 + thickness, root.0 + thickness],
                [tip.0 - thickness * 0.6, tip.1 - thickness * 0.6, tip.1 + thickness * 0.6, tip.0 + thickness * 0.6],
            ])
        }

        mutating func box(_ slot: Slot, centre c: SIMD3<Float>, size: SIMD3<Float>) {
            let h = size / 2
            func ring(_ z: Float) -> [SIMD3<Float>] {
                [SIMD3(c.x - h.x, c.y - h.y, z), SIMD3(c.x + h.x, c.y - h.y, z),
                 SIMD3(c.x + h.x, c.y + h.y, z), SIMD3(c.x - h.x, c.y + h.y, z)]
            }
            loft(slot, [ring(c.z - h.z), ring(c.z + h.z)])
        }
    }

    /// A flat deck between elliptical shoulders, with a tighter radius below the beltline.
    /// The first two points bound the deck so lettering can sit flush on it.
    static func section(x: Float = 0, z: Float, halfWidth w: Float, top: Float, bottom: Float = clearance,
                        chine: Float = 0.45, roof: Float = 0.4) -> [SIMD3<Float>] {
        let belt = bottom + (top - bottom) * chine
        let deck = w * min(roof, 0.88)
        let floor = w * 0.70
        var side = [SIMD2(deck, top)]
        for i in 1..<5 {
            let angle = Float(i) * .pi / 10
            side.append(SIMD2(deck + (w - deck) * sin(angle), belt + (top - belt) * cos(angle)))
        }
        side.append(SIMD2(w, belt))
        for i in 1..<3 {
            let angle = Float(i) * .pi / 6
            side.append(SIMD2(floor + (w - floor) * cos(angle), belt - (belt - bottom) * sin(angle)))
        }
        side.append(SIMD2(floor, bottom))
        let right = side.map { SIMD3(x + $0.x, $0.y, z) }
        let left = side.reversed().map { SIMD3(x - $0.x, $0.y, z) }
        return [SIMD3(x - deck, top, z)] + right + left.dropLast()
    }

    /// One flat-ish face of a lofted body: its middle, the way it faces, and its size in the
    /// direction rings follow one another (`length`) and round the ring (`rise`).
    struct Face {
        let centre: SIMD3<Float>
        let normal: SIMD3<Float>
        let length: Float
        let rise: Float

        /// The face between points `i` and `j` of ring `a` and the same two of ring `b`.
        init(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>], _ i: Int, _ j: Int) {
            centre = (a[i] + a[j] + b[i] + b[j]) / 4
            let middleA: SIMD3<Float> = a.reduce(.zero, +) / Float(a.count)
            let middleB: SIMD3<Float> = b.reduce(.zero, +) / Float(b.count)
            let inside = (middleA + middleB) / 2
            let n = simd_normalize(simd_cross(b[j] - a[i], b[i] - a[j]))
            normal = simd_dot(n, centre - inside) < 0 ? -n : n
            length = simd_distance((a[i] + a[j]) / 2, (b[i] + b[j]) / 2)
            rise = (simd_distance(a[i], a[j]) + simd_distance(b[i], b[j])) / 2
        }

        /// The roof of a `section` body between two rings.
        static func roof(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Face { Face(a, b, 0, 1) }
    }

    static func build(_ design: CarDesign) -> CarModel {
        GarageMesh.build(design.build, glow: design.glow,
                         markings: Markings(maker: design.maker, number: design.number), livery: design.livery)
    }

    static func makeFlames(_ exhausts: [(SIMD3<Float>, Float)], glow: SIMD3<Float>) -> SCNNode {
        let flames = SCNNode()
        flames.name = "flames"
        let plume = SCNMaterial()
        plume.lightingModel = .constant
        plume.diffuse.contents = UIColor.black
        plume.emission.contents = color(glow)
        plume.emission.intensity = 2.4
        plume.blendMode = .add
        plume.writesToDepthBuffer = false
        plume.isDoubleSided = true
        for (position, radius) in exhausts {
            let cone = SCNCone(topRadius: 0, bottomRadius: CGFloat(radius * 0.72), height: 1)
            cone.radialSegmentCount = 8
            cone.firstMaterial = plume
            let flame = SCNNode(geometry: cone)
            // Cone points backwards with its base on the exhaust; the pivot makes scaling stretch it.
            flame.pivot = SCNMatrix4MakeTranslation(0, -0.5, 0)
            flame.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            flame.simdPosition = position
            flame.castsShadow = false
            flames.addChildNode(flame)
        }
        return flames
    }

    /// Red, whatever the car's colours: everyone behind reads it the same way.
    static let tailColor = SIMD3<Float>(1, 0.13, 0.37)

    /// Tail lights from boxes modelled with the road at y = 0. They are a node of their own,
    /// named for `setBrake`, with their own lens so one car's braking lights no other's.
    static func makeTailLights(_ lamps: [(centre: SIMD3<Float>, size: SIMD3<Float>)]) -> SCNNode {
        var shell = Shell()
        for lamp in lamps { shell.box(.glow, centre: lamp.centre, size: lamp.size) }
        let lens = SCNMaterial()
        lens.lightingModel = .constant
        lens.diffuse.contents = UIColor.black
        lens.emission.contents = color(tailColor)
        let node = SCNNode(geometry: shell.mesh.geometry(materials: Array(repeating: lens, count: Slot.allCases.count)))
        node.name = "tail"
        node.castsShadow = false
        setBrake(0, on: node, lens: lens)
        return node
    }

    /// Sets the tail lights: 0 running, anything more is the brakes, full by a light touch.
    static func setBrake(_ amount: Float, on car: SCNNode) {
        guard let lens = car.childNode(withName: "tail", recursively: false)?.geometry?.firstMaterial else { return }
        setBrake(amount, on: car, lens: lens)
    }

    private static func setBrake(_ amount: Float, on car: SCNNode, lens: SCNMaterial) {
        // Running lights sit just over the bloom threshold; brake lights flare well past it.
        let intensity = CGFloat(mix(1.8, 6, smoothstep(0.02, 0.2, amount)))
        if lens.emission.intensity != intensity { lens.emission.intensity = intensity }
    }

    /// Tyre rubber: dull, never metallic. `treadAround` a wheel of that radius cuts a tread into
    /// it, for surfaces mapped once round the wheel and once across it.
    static func rubber(treadAround radius: Float? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.075, alpha: 1)
        m.roughness.contents = 0.82
        m.metalness.contents = 0
        if let radius {
            let blocks = (2 * Float.pi * radius / 0.13).rounded()
            ProceduralTextures.tyreTread.overlay(on: m, tile: SIMD2(1 / blocks, 1))
        }
        return m
    }

    /// Machined steel for brake discs and hub carriers: pale, so it shows against a tyre.
    static func steel() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.62, alpha: 1)
        m.metalness.contents = 0.85
        m.roughness.contents = 0.38
        return m
    }

    /// Tinted glass with a polished surface that reflects the surrounding scene.
    static func glass(tint light: SIMD3<Float>) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color(simd_mix(SIMD3(0.08, 0.12, 0.2), light, SIMD3(repeating: 0.5)))
        m.multiply.contents = ProceduralTextures.canopy
        m.multiply.mipFilter = .linear
        m.metalness.contents = 0.25
        m.roughness.contents = 0.14
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.08
        return m
    }

    /// Sets the afterburners: 0 idle, 1 flat out, above 1 on boost.
    static func setThrust(_ amount: Float, on car: SCNNode) {
        if let flames = car.childNode(withName: "flames", recursively: false) {
            let length = 0.12 + 1.15 * amount
            let girth = 0.75 + 0.3 * min(amount, 1.6)
            for flame in flames.childNodes { flame.simdScale = SIMD3(girth, length, girth) }
        }
    }

    /// `ink` if it stands out on `surface`; otherwise white on a dark surface or a deep shade of
    /// a bright one, so lettering reads on any pair of team colours.
    static func legible(_ ink: SIMD3<Float>, on surface: SIMD3<Float>) -> SIMD3<Float> {
        func light(_ c: SIMD3<Float>) -> Float { simd_dot(c, SIMD3(0.299, 0.587, 0.114)) }
        if abs(light(ink) - light(surface)) >= 0.25 { return ink }
        return light(surface) > 0.5 ? surface * 0.16 + SIMD3(0.02, 0.03, 0.05) : SIMD3(0.93, 0.95, 0.98)
    }

    static func color(_ c: SIMD3<Float>) -> UIColor {
        UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }

    /// `detailed` lays panel seams, vents and wear over the paint, and `livery` paints racing
    /// graphics on it in a second colour. Shells carry the UVs for both; anything else (a rim
    /// on a stock cylinder) wants the plain colours.
    static func materials(paint: SIMD3<Float>, accent: SIMD3<Float>, light: SIMD3<Float>, detailed: Bool = true,
                          livery: (color: SIMD3<Float>, style: Int)? = nil) -> [SCNMaterial] {
        /// `coat` lacquers the surface: a second, mirror-sharp highlight over the paint.
        func pbr(_ c: SIMD3<Float>, metal: CGFloat, rough: CGFloat, coat: Bool = false,
                 detail: TextureSet? = nil) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = color(c)
            m.metalness.contents = metal
            m.roughness.contents = rough
            if coat {
                m.clearCoat.contents = 1.0
                m.clearCoatRoughness.contents = 0.18
            }
            if detailed { detail?.overlay(on: m, tile: ProceduralTextures.carTile) }
            return m
        }
        let body = pbr(paint, metal: 0.7, rough: 0.32, coat: true, detail: ProceduralTextures.carPanels)
        if detailed, let livery {
            body.diffuse.contents = ProceduralTextures.carLivery(paint: paint, graphics: livery.color, style: livery.style)
        }
        let glow = SCNMaterial()
        glow.lightingModel = .constant
        glow.diffuse.contents = UIColor.black
        glow.emission.contents = color(light)
        glow.emission.intensity = 3
        // Bodywork only reflects light; the glow strips and plumes are the car's only emitters.
        return [
            body,
            pbr(accent, metal: 0.5, rough: 0.4, coat: true, detail: ProceduralTextures.carPanels),
            pbr(SIMD3(0.09, 0.1, 0.12), metal: 0.9, rough: 0.45, detail: ProceduralTextures.carMetal),
            glass(tint: light),
            glow,
        ]
    }
}
