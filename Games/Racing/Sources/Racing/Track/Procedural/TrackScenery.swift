import SceneKit
import simd

/// The city the track hangs in. Everything is placed in the curve's own frame:
/// a distance along the lap, a lateral offset and a height relative to the deck.
enum CityScenery {

    private enum Slot: Int, CaseIterable {
        case facadeA, facadeB, facadeC, hull, neonA, neonB, floor, lamp, arrow
    }

    private struct Tower {
        var center: SIMD2<Float>
        var radius: Float
    }

    static func build(path: TrackPath) -> SCNNode {
        let theme = path.definition.theme, seed = path.definition.seed
        var rng = SplitMix64(seed: seed &+ 909)
        var mesh = MeshBuilder(materialCount: Slot.allCases.count, colors: true)

        let lowest = path.samples.map(\.position.y).min() ?? 0
        let floorY = lowest - 190

        towers(path: path, floorY: floorY, rng: &rng, mesh: &mesh)
        pylons(path: path, floorY: floorY, mesh: &mesh)
        let signs = gates(path: path, rng: &rng, mesh: &mesh)
        turnArrows(path: path, mesh: &mesh)

        let mid = (path.boundsMin + path.boundsMax) / 2
        let reach: Float = 4000
        mesh.flatQuad(Slot.floor.rawValue,
                      SIMD3(mid.x - reach, floorY, mid.y + reach), SIMD3(mid.x + reach, floorY, mid.y + reach),
                      SIMD3(mid.x + reach, floorY, mid.y - reach), SIMD3(mid.x - reach, floorY, mid.y - reach))

        var materials = (0..<3).map {
            ProceduralTextures.facade(variant: $0, theme: theme, seed: seed &+ 70 &+ UInt64($0))
                .material(name: "facade-\($0)", tile: SIMD2(48, 48), glow: 1.8)
        }
        let hull = TrackMeshBuilder.hullMaterial(theme: theme, seed: seed)
        for property in [hull.diffuse, hull.metalness, hull.roughness, hull.emission, hull.normal] {
            property.contentsTransform = SCNMatrix4MakeScale(1 / 8, 1 / 8, 1)   // box UVs are in metres
        }
        materials.append(hull)
        materials.append(TrackMeshBuilder.neon(theme.neonA, intensity: 3.2))
        materials.append(TrackMeshBuilder.neon(theme.neonB, intensity: 3.2))
        materials.append(ProceduralTextures.cityFloor(theme: theme, seed: seed &+ 80)
            .material(name: "city-floor", tile: SIMD2(800, 800), glow: 1.5))
        materials.append(TrackMeshBuilder.neon(theme.window, intensity: 2))
        let arrow = TrackMeshBuilder.neon(SIMD3(1.0, 0.62, 0.08), intensity: 3.0)
        arrow.isDoubleSided = true
        materials.append(arrow)

        let node = SCNNode(geometry: mesh.geometry(materials: materials))
        node.name = "city"
        node.castsShadow = false
        signs.forEach(node.addChildNode)
        return node
    }

    /// Additive glowing lettering on a quad; `corners` are bottom-left, bottom-right,
    /// top-right, top-left as the reader sees them.
    private static func sign(_ image: UIImage, corners: [[SIMD3<Float>]]) -> SCNNode {
        var mesh = MeshBuilder(materialCount: 1)
        let rows = corners.count
        var previous: (UInt32, UInt32)?
        for (r, pair) in corners.enumerated() {
            let v = 1 - Float(r) / Float(rows - 1)
            let current = (mesh.vertex(pair[0], SIMD3(0, 1, 0), SIMD2(0, v)),
                           mesh.vertex(pair[1], SIMD3(0, 1, 0), SIMD2(1, v)))
            if let p = previous { mesh.quad(0, p.0, p.1, current.1, current.0) }
            previous = current
        }
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.black
        m.emission.contents = image
        m.emission.intensity = 2.2
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        let node = SCNNode(geometry: mesh.geometry(materials: [m]))
        node.castsShadow = false
        node.renderingOrder = 10
        return node
    }

    // MARK: - Towers

    private static func towers(path: TrackPath, floorY: Float, rng: inout SplitMix64, mesh: inout MeshBuilder) {
        let step = path.totalLength / Float(path.stepCount)
        var placed: [Tower] = []

        /// Rejects footprints that would touch the road anywhere on the lap, or another tower.
        func isFree(_ center: SIMD2<Float>, _ radius: Float) -> Bool {
            for i in stride(from: 0, to: path.stepCount, by: 3) {
                let s = path.samples[i]
                let clearance = radius + s.halfWidth + 14
                if simd_distance_squared(center, SIMD2(s.position.x, s.position.z)) < clearance * clearance { return false }
            }
            return placed.allSatisfy { simd_distance($0.center, center) > $0.radius + radius + 5 }
        }

        // Two rings: a tight canyon beside the road, then a taller skyline behind it.
        let rings: [(spacing: ClosedRange<Float>, lateral: ClosedRange<Float>, size: ClosedRange<Float>, rise: ClosedRange<Float>)] = [
            (34...58, 26...90, 18...34, -35...120),
            (70...120, 130...360, 30...60, 40...260),
        ]
        for ring in rings {
            for side: Float in [-1, 1] {
                var arc = rng.float(0...40)
                while arc < path.totalLength {
                    let s = path.sample(at: Int(arc / step))
                    arc += rng.float(ring.spacing)
                    let width = rng.float(ring.size), depth = rng.float(ring.size)
                    let radius = 0.5 * (width * width + depth * depth).squareRoot()
                    let forward = simd_normalize(SIMD3(s.forward.x, 0, s.forward.z))
                    let right = simd_cross(forward, SIMD3(0, 1, 0))
                    let offset = s.halfWidth + rng.float(ring.lateral) + depth / 2
                    let base = s.position + right * (side * offset)
                    let top = s.position.y + rng.float(ring.rise)
                    let style = Int.random(in: 0..<3, using: &rng)
                    let shade = rng.float(0.7...1.1)
                    let details = (rng.float(), rng.float(), rng.float(), rng.float())
                    guard isFree(SIMD2(base.x, base.z), radius) else { continue }
                    placed.append(Tower(center: SIMD2(base.x, base.z), radius: radius))
                    tower(at: SIMD3(base.x, floorY, base.z),
                          basis: simd_float3x3(columns: (right, SIMD3(0, 1, 0), simd_cross(right, SIMD3(0, 1, 0)))),
                          size: SIMD3(width, top - floorY, depth), style: style, shade: shade,
                          details: details, mesh: &mesh)
                }
            }
        }
    }

    private static func tower(at origin: SIMD3<Float>, basis: simd_float3x3, size: SIMD3<Float>, style: Int,
                              shade: Float, details: (Float, Float, Float, Float), mesh: inout MeshBuilder) {
        let color = SIMD3<Float>(repeating: shade)
        let neon = details.0 < 0.5 ? Slot.neonA.rawValue : Slot.neonB.rawValue
        let bodyHeight = size.y * (0.68 + details.1 * 0.2)
        mesh.box(style, origin: origin, basis: basis, size: SIMD3(size.x, bodyHeight, size.z),
                 color: color, topSlot: Slot.hull.rawValue)

        // A few towers carry a light band under the roof line.
        if details.2 > 0.72 {
            mesh.box(neon, origin: origin + SIMD3(0, bodyHeight - 4, 0), basis: basis,
                     size: SIMD3(size.x + 0.8, 1.0, size.z + 0.8))
        }

        var roof = bodyHeight
        if details.2 < 0.75 {
            let h = size.y - bodyHeight
            let inset = 0.55 + details.3 * 0.25
            mesh.box(style, origin: origin + SIMD3(0, roof, 0), basis: basis,
                     size: SIMD3(size.x * inset, h * 0.7, size.z * inset), color: color * 0.9,
                     topSlot: Slot.hull.rawValue)
            roof += h * 0.7
        }
        if details.3 < 0.55 {
            mesh.box(Slot.hull.rawValue, origin: origin + SIMD3(0, roof, 0), basis: basis,
                     size: SIMD3(1.6, 26 + details.1 * 30, 1.6), color: SIMD3(repeating: 0.6))
            mesh.box(Slot.neonB.rawValue, origin: origin + SIMD3(0, roof + 26 + details.1 * 30, 0), basis: basis,
                     size: SIMD3(1.4, 1.4, 1.4))
        }
        // Neon riser up one corner.
        if details.0 > 0.88 {
            let corner = basis * SIMD3(size.x / 2 * (details.1 < 0.5 ? 1 : -1), 0, size.z / 2)
            mesh.box(neon, origin: origin + corner + SIMD3(0, bodyHeight * 0.35, 0), basis: basis,
                     size: SIMD3(1.2, bodyHeight * 0.6, 1.2))
        }
    }

    // MARK: - Pylons

    /// Columns from the city floor to a collar under the hull, every eighth section.
    private static func pylons(path: TrackPath, floorY: Float, mesh: inout MeshBuilder) {
        let per = TrackPath.sectionSamples
        let slot = Slot.hull.rawValue
        for section in stride(from: 4, to: path.sectionCount, by: 8) {
            let s = path.samples[section * per]
            let forward = simd_normalize(SIMD3(s.forward.x, 0, s.forward.z))
            let right = simd_cross(forward, SIMD3(0, 1, 0))
            let upright = simd_float3x3(columns: (right, SIMD3(0, 1, 0), simd_cross(right, SIMD3(0, 1, 0))))
            let frame = simd_float3x3(columns: (s.right, s.up, simd_cross(s.right, s.up)))
            let underside = s.position - s.up * TrackMeshBuilder.keelDepth

            mesh.box(slot, origin: underside - s.up * 2.2, basis: frame,
                     size: SIMD3(s.halfWidth * 1.3, 2.2, 6), color: SIMD3(repeating: 0.9))
            let top = underside.y - 1.6
            mesh.box(slot, origin: SIMD3(s.position.x, floorY, s.position.z), basis: upright,
                     size: SIMD3(3.6, top - floorY, 3.6), color: SIMD3(repeating: 0.8), top: false)
        }
    }

    // MARK: - Turn arrows

    /// Big lit arrows along the outside of every corner, pointing the way round it.
    private static func turnArrows(path: TrackPath, mesh: inout MeshBuilder) {
        let per = TrackPath.sectionSamples
        let sections = TrackSections.plan(path: path)
        // Arrow outline in (along, up): a shaft and a broad head.
        let length: Float = 9, shaft: Float = 0.75, head: Float = 2, neck: Float = 9 / 2 - 3.6
        let outline: [SIMD2<Float>] = [
            SIMD2(-length / 2, -shaft), SIMD2(neck, -shaft), SIMD2(neck, -head), SIMD2(length / 2, 0),
            SIMD2(neck, head), SIMD2(neck, shaft), SIMD2(-length / 2, shaft),
        ]
        for section in stride(from: 0, to: path.sectionCount, by: 2) where sections[section].enclosure == nil {
            let s = path.samples[section * per + per / 2]
            let mean = (0..<per).reduce(Float(0)) { $0 + path.samples[section * per + $1].curvature } / Float(per)
            guard abs(mean) >= TrackSections.bendCurvature else { continue }
            let side: Float = mean > 0 ? -1 : 1          // outside of the corner
            let forward = simd_normalize(SIMD3(s.forward.x, 0, s.forward.z))
            let out = simd_cross(forward, SIMD3(0, 1, 0)) * side
            let up = SIMD3<Float>(0, 1, 0)
            let base = s.position + out * (s.halfWidth + TrackMeshBuilder.shoulder + 1.6)
            let centre = base + up * 4.6
            let slot = Slot.arrow.rawValue
            var faces: [[UInt32]] = []
            for depth: Float in [-0.35, 0.35] {
                faces.append(outline.map { mesh.vertex(centre + forward * $0.x + up * $0.y + out * depth, -out * (depth < 0 ? 1 : -1)) })
            }
            for f in faces {
                mesh.quad(slot, f[0], f[1], f[5], f[6])
                mesh.triangle(slot, f[2], f[3], f[4])
            }
            for k in 0..<outline.count {
                let j = (k + 1) % outline.count
                mesh.quad(slot, faces[0][k], faces[0][j], faces[1][j], faces[1][k])
            }
            // Post.
            mesh.box(Slot.hull.rawValue, origin: base - up * 1.5,
                     basis: simd_float3x3(columns: (forward, up, simd_cross(forward, up))),
                     size: SIMD3(0.7, 6.1 - head, 0.5), color: SIMD3(repeating: 0.8), top: false)
        }
    }

    // MARK: - Gates

    /// Arches over the road in the banked track frame; the one on the start line is heavier.
    /// Returns the numbered signs: one on each beam and a numeral on the deck before it.
    private static func gates(path: TrackPath, rng: inout SplitMix64, mesh: inout MeshBuilder) -> [SCNNode] {
        let theme = path.definition.theme
        var signs: [SCNNode] = []
        let sections = TrackSections.plan(path: path)
        let per = TrackPath.sectionSamples
        let slot = Slot.hull.rawValue
        var section = 0
        var index = 0
        while section < path.sectionCount - 3 {
            // Gates do not fit under a roof.
            guard sections[section].enclosure == nil else { section += 1; continue }
            let s = path.samples[section * per + per / 2]
            let frame = simd_float3x3(columns: (s.right, s.up, simd_cross(s.right, s.up)))
            let start = section == 0
            let neon = (start || index % 2 == 1) ? Slot.neonB.rawValue : Slot.neonA.rawValue
            let reach = s.halfWidth + TrackMeshBuilder.shoulder + 1.2
            let height: Float = start ? 9.5 : 8
            let beam: Float = start ? 2.4 : 1.4
            let color = SIMD3<Float>(repeating: 1.1)

            for side: Float in [-1, 1] {
                mesh.box(slot, origin: s.position + s.right * (side * reach) - s.up * 1.2, basis: frame,
                         size: SIMD3(1.4, height + 1.2, 2.4), color: color, top: false)
            }
            mesh.box(slot, origin: s.position + s.up * height, basis: frame,
                     size: SIMD3(reach * 2 + 1.4, beam, 2.8), color: color)
            // Floodlights under the beam.
            for x: Float in [-0.6, -0.2, 0.2, 0.6] {
                mesh.box(Slot.lamp.rawValue, origin: s.position + s.right * (x * s.halfWidth) + s.up * (height - 0.25),
                         basis: frame, size: SIMD3(1.6, 0.25, 0.8))
            }
            // Sign on the face of the beam that oncoming cars see.
            // Every third gate carries a speed board instead of its number.
            let words = ["MAX 600 KPH", "CAUTION", "GO"]
            let numbered = start || index % 3 != 0
            let text = start ? "START" : (numbered ? String(format: "%02d", index) : words[(index / 3) % words.count])
            let amber = SIMD3<Float>(1.0, 0.68, 0.12)
            let lettering = ProceduralTextures.sign(
                text, color: numbered ? (neon == Slot.neonB.rawValue ? theme.neonB : theme.neonA) : amber)
            let forward = simd_cross(s.up, s.right)
            let signHeight = beam * 0.8
            let half = min(signHeight * lettering.aspect, s.halfWidth * 1.6) / 2
            let face = s.position + s.up * (height + beam / 2) - forward * 1.45
            signs.append(sign(lettering.image, corners: [
                [face - s.right * half - s.up * signHeight / 2, face + s.right * half - s.up * signHeight / 2],
                [face - s.right * half + s.up * signHeight / 2, face + s.right * half + s.up * signHeight / 2],
            ]))
            // The same numeral laid along the deck on the approach.
            if !start, numbered {
                let centre = section * per + per / 2
                let length: Float = 10
                let halfDeck = min(length * lettering.aspect, 9) / 2
                signs.append(sign(lettering.image, corners: (-9...(-4)).map { k in
                    let d = path.sample(at: centre + k)
                    let p = d.position + d.up * 0.05
                    return [p - d.right * halfDeck, p + d.right * halfDeck]
                }))
            }
            section += Int.random(in: 9...15, using: &rng)
            index += 1
        }
        return signs
    }
}
