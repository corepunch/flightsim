import UIKit
import SceneKit
import simd

/// One shaded point of a generated surface.
struct Texel {
    var albedo = SIMD3<Float>(repeating: 0.5)
    var metal: Float = 1
    var rough: Float = 0.4
    var emission = SIMD3<Float>.zero
    /// Relief used to derive the normal map (positive = raised).
    var height: Float = 0

    /// Opaque paint over the metal. `alpha` should already include wear.
    mutating func paint(_ color: SIMD3<Float>, _ alpha: Float) {
        albedo = simd_mix(albedo, color, SIMD3(repeating: alpha))
        metal = mix(metal, 0, alpha)
        rough = mix(rough, 0.62, alpha)
        height += alpha * 0.04
    }

    /// A light source set into the surface.
    mutating func glow(_ color: SIMD3<Float>, _ mask: Float) {
        albedo = simd_mix(albedo, color * 0.25, SIMD3(repeating: mask))
        metal = mix(metal, 0, mask)
        rough = mix(rough, 0.3, mask)
        emission += color * mask
    }
}

/// The PBR maps baked from one `Texel` shader.
struct TextureSet {
    let albedo: UIImage
    /// Metalness in red, roughness in green.
    let surface: UIImage
    let emission: UIImage
    let normal: UIImage

    /// `tile` is how many UV units one copy of the texture covers on each axis.
    func material(name: String, tile: SIMD2<Float> = SIMD2(1, 1), glow: CGFloat = 1) -> SCNMaterial {
        let m = SCNMaterial()
        m.name = name
        m.lightingModel = .physicallyBased
        m.diffuse.contents = albedo
        m.metalness.contents = surface
        m.metalness.textureComponents = .red
        m.roughness.contents = surface
        m.roughness.textureComponents = .green
        m.emission.contents = emission
        m.emission.intensity = glow
        m.normal.contents = normal
        let transform = SCNMatrix4MakeScale(1 / tile.x, 1 / tile.y, 1)
        for property in [m.diffuse, m.metalness, m.roughness, m.emission, m.normal] {
            property.wrapS = .repeat
            property.wrapT = .repeat
            property.mipFilter = .linear
            property.maxAnisotropy = 8
            property.contentsTransform = transform
        }
        return m
    }

    /// Lays the set over a material as colourless detail: the albedo darkens the lit surface
    /// (seams, vents, grime), roughness and relief come from the other maps, and the material
    /// keeps its own colour or livery and its metalness.
    func overlay(on m: SCNMaterial, tile: SIMD2<Float>) {
        m.multiply.contents = albedo
        m.roughness.contents = surface
        m.roughness.textureComponents = .green
        m.normal.contents = normal
        let transform = SCNMatrix4MakeScale(1 / tile.x, 1 / tile.y, 1)
        for property in [m.diffuse, m.multiply, m.roughness, m.normal] {
            property.wrapS = .repeat
            property.wrapT = .repeat
            property.mipFilter = .linear
            property.maxAnisotropy = 8
            property.contentsTransform = transform
        }
    }
}

/// Antialiased coverage of a line of stencil lettering, sampled by the texture shaders.
struct TextMask {
    let width: Int
    let height: Int
    private let pixels: [UInt8]
    /// Width over height of the lettering's bounding box.
    var aspect: Float { Float(width) / Float(height) }

    init(_ text: String, height: Int = 96, tracking: CGFloat = 0.12) {
        let size = CGFloat(height) * 1.08
        let font = UIFont(name: "DINCondensed-Bold", size: size)
            ?? UIFont.monospacedSystemFont(ofSize: size * 0.8, weight: .heavy)
        let string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: UIColor.white, .kern: size * tracking,
        ])
        // Condensed DIN stretched wide gives square, extended capitals.
        let stretch: CGFloat = 1.5
        let bounds = string.size()
        let w = max(4, Int((bounds.width * stretch).rounded(.up)) + 4)
        var data = [UInt8](repeating: 0, count: w * height)
        data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: height, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: stretch, y: -1)
            UIGraphicsPushContext(ctx)
            // Centre the cap height; DIN's line box has extra room above the capitals.
            let y = (CGFloat(height) - font.capHeight) / 2 - (font.ascender - font.capHeight)
            string.draw(at: CGPoint(x: 2 / stretch, y: y))
            UIGraphicsPopContext()
        }
        // A thin horizontal cut through every letter.
        let cut = Int(Float(height) * 0.43)
        for row in cut..<(cut + max(2, height / 22)) {
            for x in 0..<w { data[row * w + x] = 0 }
        }
        width = w
        self.height = height
        pixels = data
    }

    /// Coverage at (s, t): s runs in the reading direction, t from baseline side up. 0 outside.
    func sample(_ s: Float, _ t: Float) -> Float {
        guard s > 0, s < 1, t > 0, t < 1 else { return 0 }
        let x = s * Float(width) - 0.5, y = (1 - t) * Float(height) - 0.5
        let x0 = max(0, Int(x.rounded(.down))), y0 = max(0, Int(y.rounded(.down)))
        let x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
        let fx = min(max(x - Float(x0), 0), 1), fy = min(max(y - Float(y0), 0), 1)
        func px(_ x: Int, _ y: Int) -> Float { Float(pixels[y * width + x]) / 255 }
        return mix(mix(px(x0, y0), px(x1, y0), fx), mix(px(x0, y1), px(x1, y1), fx), fy)
    }

    /// Lettering `size` metres tall centred at `center`, for a point `p` (metres) on a surface
    /// whose reading direction is +x and whose "up" is +y.
    func coverage(_ p: SIMD2<Float>, center: SIMD2<Float>, size: Float) -> Float {
        sample((p.x - center.x) / (size * aspect) + 0.5, (p.y - center.y) / size + 0.5)
    }
}

/// CPU-generated, tileable textures. Everything is seeded so a track looks identical every launch.
enum ProceduralTextures {

    // MARK: - Image plumbing

    private static func makeImage(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int,
                                  linear: Bool = false) -> UIImage {
        let data = Data(bytes: pixels, count: width * height * 4) as CFData
        let space = CGColorSpace(name: linear ? CGColorSpace.linearSRGB : CGColorSpace.sRGB)!
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: width * 4, space: space,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: CGDataProvider(data: data)!, decode: nil,
                         shouldInterpolate: true, intent: .defaultIntent)!
        return UIImage(cgImage: cg)
    }

    @inline(__always) private static func store(_ c: SIMD3<Float>, _ p: UnsafeMutablePointer<UInt8>) {
        let v = simd_clamp(c, .zero, SIMD3(repeating: 1)) * 255
        p[0] = UInt8(v.x); p[1] = UInt8(v.y); p[2] = UInt8(v.z); p[3] = 255
    }

    /// Renders `shade(u, v)` (u, v in [0, 1)) into an sRGB image, rows in parallel.
    static func image(width: Int, height: Int, _ shade: (Float, Float) -> SIMD3<Float>) -> UIImage {
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        defer { pixels.deallocate() }
        DispatchQueue.concurrentPerform(iterations: height) { y in
            let v = (Float(y) + 0.5) / Float(height)
            for x in 0..<width {
                store(shade((Float(x) + 0.5) / Float(width), v), pixels + (y * width + x) * 4)
            }
        }
        return makeImage(pixels, width: width, height: height)
    }

    /// Bakes albedo, metal/rough, emission and a normal map from one shader, rows in parallel.
    /// `shade` receives exact texture coordinates and must tile on both axes.
    static func bake(width: Int, height: Int, bump: Float = 2.5,
                     _ shade: (Float, Float) -> Texel) -> TextureSet {
        let count = width * height
        let albedo = UnsafeMutablePointer<UInt8>.allocate(capacity: count * 4)
        let surface = UnsafeMutablePointer<UInt8>.allocate(capacity: count * 4)
        let emission = UnsafeMutablePointer<UInt8>.allocate(capacity: count * 4)
        let normal = UnsafeMutablePointer<UInt8>.allocate(capacity: count * 4)
        let relief = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { albedo.deallocate(); surface.deallocate(); emission.deallocate(); normal.deallocate(); relief.deallocate() }

        DispatchQueue.concurrentPerform(iterations: height) { y in
            let v = (Float(y) + 0.5) / Float(height)
            for x in 0..<width {
                let t = shade((Float(x) + 0.5) / Float(width), v)
                let i = y * width + x
                store(t.albedo, albedo + i * 4)
                store(SIMD3(t.metal, t.rough, 0), surface + i * 4)
                store(t.emission, emission + i * 4)
                relief[i] = t.height
            }
        }
        DispatchQueue.concurrentPerform(iterations: height) { y in
            let up = ((y - 1 + height) % height) * width, down = ((y + 1) % height) * width
            for x in 0..<width {
                let dx = relief[y * width + (x + 1) % width] - relief[y * width + (x - 1 + width) % width]
                let dy = relief[down + x] - relief[up + x]
                let n = simd_normalize(SIMD3(-dx * bump, -dy * bump, 1))
                store(n * 0.5 + 0.5, normal + (y * width + x) * 4)
            }
        }
        return TextureSet(albedo: makeImage(albedo, width: width, height: height),
                          surface: makeImage(surface, width: width, height: height, linear: true),
                          emission: makeImage(emission, width: width, height: height),
                          normal: makeImage(normal, width: width, height: height))
    }

    /// Glowing lettering on black, for additive decals. One texel row per `height` pixel.
    static func sign(_ text: String, color: SIMD3<Float>, height: Int = 128) -> (image: UIImage, aspect: Float) {
        let mask = TextMask(text, height: height)
        let img = image(width: mask.width, height: mask.height) { u, v in color * mask.sample(u, 1 - v) }
        return (img, mask.aspect)
    }

    // MARK: - Shape helpers

    /// 1 inside `|d| < half`, antialiased over `aa`.
    @inline(__always) private static func band(_ d: Float, _ half: Float, _ aa: Float) -> Float {
        1 - smoothstep(half - aa, half + aa, abs(d))
    }

    /// 1 inside the box centred on the origin.
    @inline(__always) private static func box(_ x: Float, _ y: Float, _ hx: Float, _ hy: Float, _ aa: Float) -> Float {
        band(x, hx, aa) * band(y, hy, aa)
    }

    @inline(__always) private static func fract(_ x: Float) -> Float { x - x.rounded(.down) }

    /// A V-shaped stripe whose apex points towards +y. `x` is centred, `y` is measured from the apex.
    @inline(__always) private static func chevron(_ x: Float, _ y: Float, halfWidth: Float, slope: Float,
                                                 thickness: Float, aa: Float) -> Float {
        band(y + abs(x) * slope, thickness, aa) * band(x, halfWidth, aa)
    }

    /// Worn, brushed plate. Tiles on [0, 1); `cells` scales the detail.
    private struct MetalBase {
        let noise: Noise2D
        init(seed: UInt64) { noise = Noise2D(seed: seed) }

        /// `tone` multiplies albedo; `wear` in 0...1 marks dull, scuffed areas.
        func sample(_ u: Float, _ v: Float, cells: Int = 4) -> (tone: Float, wear: Float, grain: Float) {
            let c = Float(cells)
            let brushed = noise.noise(u * c * 48, v * c * 2, period: cells * 2)
            let blotch = noise.fbm(u * c, v * c, octaves: 3, period: cells)
            let streak = noise.noise(u * c * 24, v * c, period: cells)
            let grain = noise.noise(u * c * 40, v * c * 40, period: cells * 40)
            let wear = smoothstep(0.35, 0.8, blotch * 0.5 + 0.5 + streak * 0.25)
            return (1 + brushed * 0.06 + blotch * 0.07 + streak * 0.03, wear, grain)
        }
    }

    /// Corrosion blooming out of the scuffed areas: brown, dull and non-metallic.
    @inline(__always) private static func corrode(_ t: inout Texel, wear: Float, grain: Float, amount: Float) {
        let r = smoothstep(0.45, 0.95, wear + grain * 0.2) * amount
        let rust = SIMD3<Float>(0.42, 0.20, 0.09) * (0.75 + grain * 0.5)
        t.albedo = simd_mix(t.albedo, rust, SIMD3(repeating: r))
        t.metal = mix(t.metal, 0.1, r)
        t.rough = mix(t.rough, 0.9, r)
    }

    /// Rectangular plating with seams. `du`/`dv` are the texture's size in metres so seams stay square.
    private static func plates(_ u: Float, _ v: Float, cols: Int, rows: Int, size: SIMD2<Float>,
                               seam: Float, stagger: Bool, noise: Noise2D)
        -> (seam: Float, tint: Float, bolt: Float) {
        let fv = v * Float(rows)
        let row = Int(fv.rounded(.down))
        let fu = u * Float(cols) + (stagger && row & 1 == 1 ? 0.5 : 0)
        let col = Int(fu.rounded(.down))
        let lu = fu - Float(col), lv = fv - Float(row)
        let cell = SIMD2(size.x / Float(cols), size.y / Float(rows))
        let ex = min(lu, 1 - lu) * cell.x, ey = min(lv, 1 - lv) * cell.y
        let groove = 1 - smoothstep(seam * 0.4, seam, min(ex, ey))
        let tint = Float(noise.hash(((col % cols) + cols) % cols * 7 + 3, row * 13 + 5) & 255) / 255
        let bx = ex - 0.22, by = ey - 0.22
        let bolt = 1 - smoothstep(0.045, 0.07, sqrt(bx * bx + by * by))
        return (groove, tint, bolt)
    }

    // MARK: - Track deck

    /// One 16 m section of deck: u across the road, v in the direction of travel.
    static func deck(_ pattern: DeckPattern, theme: TrackTheme, seed: UInt64) -> TextureSet {
        let base = MetalBase(seed: seed)
        let n = base.noise
        let aa: Float = 0.003
        let dark = SIMD3<Float>(0.035, 0.037, 0.04)
        let white = SIMD3<Float>(repeating: 0.88)
        // Stencilled lettering; the driver reads it with +u to the right and +v ahead.
        let code = String(format: "%02d", Int(seed % 89) + 7)
        let label: TextMask?
        switch pattern {
        case .plain: label = TextMask("TRK-\(code) // MAGLOCK")
        case .hazard: label = TextMask("CAUTION")
        case .grate: label = TextMask("VENT \(code)")
        case .boost: label = TextMask("BOOST")
        case .barcode: label = TextMask("SECTOR \(code)  AG-7")
        case .start: label = TextMask("GRID")
        case .chevrons, .bands: label = nil
        }
        let cream = SIMD3<Float>(0.86, 0.83, 0.74)
        // Lane lines are light strips, bright enough to bloom even where distance thins them out.
        let laneGlow: Float = 1.0
        return bake(width: 1024, height: 1024) { u, v in
            let pm = SIMD2(u * 16, v * 16)     // metres
            let x = u * 2 - 1
            // Asphalt dragged into long streaks by speed, darker along the rubbered racing line.
            let streak = n.noise(u * 64, v * 2, period: 2)
            let fine = n.noise(u * 176, v * 4, period: 4)
            let blotch = n.fbm(u * 4, v * 4, octaves: 3, period: 4)
            let grain = n.noise(u * 200, v * 200, period: 200)
            let rubber = band(x, 0.4, 0.3) * (0.55 + 0.45 * n.noise(u * 24, v * 2, period: 2))
            var t = Texel()
            t.albedo = theme.road * (1 + streak * 0.3 + fine * 0.16 + blotch * 0.12 + grain * 0.07)
                * (1 - rubber * 0.28)
            // Brown run-off stains smeared along the direction of travel.
            let stain = smoothstep(0.25, 0.7, n.fbm(u * 6, v * 2, octaves: 3, period: 2) + streak * 0.3)
            t.albedo = simd_mix(t.albedo, SIMD3(0.30, 0.19, 0.11) * (1 + fine * 0.3),
                                SIMD3(repeating: stain * 0.4 * theme.rust))
            t.metal = 0
            t.rough = 0.5 + blotch * 0.12 - rubber * 0.1
            t.height = grain * 0.12
            // One expansion joint per section.
            let joint = max(band(v, 0.003, 0.001), band(v - 1, 0.003, 0.001))
            t.albedo *= 1 - joint * 0.6
            t.height -= joint

            // Paint is scuffed away in patches.
            let chips = n.fbm(u * 48, v * 48, octaves: 2, period: 48)
            let wearMask = 1 - 0.75 * smoothstep(0.5, 0.75, chips * 0.5 + 0.3 + blotch * 0.3 + rubber * 0.15)

            // The edge band runs through every section and ties them together.
            let e = min(u, 1 - u) / 0.105          // 0 at the gutter, 1 at the band's inner edge
            if pattern != .hazard, e < 1.2 {
                switch theme.edge {
                case .sawtooth:
                    // Pale triangles biting into the road, four per section.
                    let tooth = 1 - abs(fract(v * 4) * 2 - 1)
                    let tri = 1 - smoothstep(-0.03, 0.03, e - tooth * 0.95)
                    t.paint(cream, tri * (0.45 + wearMask * 0.5))
                    // Lit edge line along the teeth's inner tips.
                    t.glow(cream * laneGlow, band(e - 1.02, 0.025, 0.015) * wearMask)
                case .kerb:
                    // Racing kerb: long alternating blocks, then a thin line.
                    let block = fract(v * 4) < 0.5
                    let kerb = (1 - smoothstep(0.6, 0.66, e)) * band(fract(v * 8) - 0.5, 0.47, 0.02)
                    t.paint(block ? theme.paint : cream, kerb * (0.55 + wearMask * 0.45))
                    t.height += kerb * 0.12 * (0.5 + 0.5 * sin(v * 64 * .pi))
                    // The edge line is a light strip.
                    t.glow(cream * laneGlow, band(e - 0.95, 0.06, 0.03) * wearMask)
                }
            }

            switch pattern {
            case .plain:
                let dash = band(fract(v * 4) - 0.5, 0.25, aa * 4) * band(x, 0.01, aa * 2)
                t.glow(cream * laneGlow, dash * wearMask * 0.8)
                t.paint(white, label!.coverage(pm, center: SIMD2(12.2, 2.6), size: 0.42) * wearMask)

            case .chevrons:
                // One huge, weathered arrowhead set into a paler slab.
                let slab = box(x, v - 0.5, 0.74, 0.42, aa)
                t.albedo = simd_mix(t.albedo, t.albedo * 1.45 + 0.03, SIMD3(repeating: slab * 0.8))
                let c = chevron(x, v - 0.72, halfWidth: 0.66, slope: 0.36, thickness: 0.13, aa: aa)
                t.paint(dark * 2.2, c * slab * (0.45 + wearMask * 0.4))

            case .bands:
                // Wide colour bands across the road with an arrowhead between them.
                let inside = band(x, 0.78, aa * 2)
                let stripes = max(band(v - 0.2, 0.13, aa), band(v - 0.8, 0.13, aa))
                t.paint(theme.paint * 0.85, stripes * inside * (0.5 + wearMask * 0.4))
                let c = chevron(x, v - 0.6, halfWidth: 0.62, slope: 0.3, thickness: 0.06, aa: aa)
                t.paint(cream, c * wearMask * 0.6)

            case .hazard:
                let side = max(band(u - 0.12, 0.06, aa), band(u - 0.88, 0.06, aa))
                let stripe = band(fract((u * (u < 0.5 ? 1 : -1) + v) * 14) - 0.5, 0.25, aa * 14)
                t.paint(dark, side)
                t.paint(theme.paint, side * stripe * wearMask)
                let plate = box(x, v - 0.5, 0.34, 0.07, aa)
                let bars = band(fract(v * 8) - 0.5, 0.12, aa * 8) * band(x, 0.3, aa * 2) * (1 - plate)
                t.paint(theme.paint, bars * wearMask * 0.9)
                t.paint(dark, plate)
                t.paint(theme.paint, label!.coverage(pm, center: SIMD2(8, 8), size: 1.3) * wearMask)

            case .grate:
                let frame = box(x, v - 0.5, 0.52, 0.44, aa)
                let inner = box(x, v - 0.5, 0.47, 0.415, aa)
                let slot = band(fract(v * 28) - 0.5, 0.2, aa * 28) * band(fract(u * 3) - 0.5, 0.42, aa * 3)
                t.paint(theme.paint, (frame - inner) * wearMask)
                let hole = inner * slot
                t.albedo = simd_mix(t.albedo, dark, SIMD3(repeating: hole))
                t.height -= hole * 0.9
                t.rough = mix(t.rough, 0.7, hole)
                t.emission += theme.neonB * hole * 0.12
                t.paint(white, label!.coverage(pm, center: SIMD2(14.1, 8), size: 0.5) * wearMask)

            case .boost:
                let pad = box(x, v - 0.5, 0.42, 0.44, aa)
                t.paint(dark, pad)
                var c: Float = 0
                for k in 0..<4 {
                    c = max(c, chevron(x, v - (0.3 + Float(k) * 0.2), halfWidth: 0.34, slope: 0.38,
                                       thickness: 0.035, aa: aa))
                }
                t.glow(theme.neonA, c * pad)
                let rim = (box(x, v - 0.5, 0.44, 0.455, aa) - pad)
                t.glow(theme.neonA * 0.6, max(rim, 0))
                let word = max(label!.coverage(pm, center: SIMD2(2.3, 8), size: 0.9),
                               label!.coverage(pm, center: SIMD2(13.7, 8), size: 0.9))
                t.paint(white, word * wearMask)

            case .barcode:
                // Transverse bars of hashed widths on one side, a block glyph on the other.
                let slotIndex = Int((v * 32).rounded(.down))
                let on = n.hash(slotIndex, 91) & 3 != 0
                let bar = on ? band(fract(v * 32) - 0.5, 0.36, aa * 32) * band(x + 0.52, 0.2, aa * 2) : 0
                t.paint(theme.paint, bar * wearMask)
                let gx = Int(((x - 0.3) / 0.075).rounded(.down)), gy = Int((v * 12).rounded(.down))
                if gx >= 0, gx < 6, n.hash(gx + 40, gy + 7) & 1 == 0 {
                    let cellMask = band(fract((x - 0.3) / 0.075) - 0.5, 0.4, 0.05) * band(fract(v * 12) - 0.5, 0.4, 0.05)
                    t.paint(SIMD3(repeating: 0.85), cellMask * wearMask)
                }
                t.paint(white, label!.coverage(pm, center: SIMD2(11.6, 14.6), size: 0.6) * wearMask)

            case .start:
                let stripe = band(v - 0.5, 0.075, aa) * band(x, 0.9, aa)
                let checker = (Int((u * 24).rounded(.down)) + Int(((v - 0.425) / 0.05).rounded(.down))) & 1 == 0
                t.paint(checker ? SIMD3(repeating: 0.92) : dark, stripe)
                let line = band(v - 0.62, 0.008, aa) * band(x, 0.9, aa)
                t.paint(theme.paint, line)
                t.paint(white, label!.coverage(pm, center: SIMD2(8, 12), size: 1.6) * wearMask)
                // Grid brackets behind the line.
                for k in 0..<2 {
                    let cx = k == 0 ? Float(-0.42) : 0.42
                    let cy: Float = k == 0 ? 0.22 : 0.3
                    let outer = box(x - cx, v - cy, 0.2, 0.07, aa)
                    let inner = box(x - cx, v - cy + 0.012, 0.18, 0.07, aa)
                    t.paint(SIMD3(repeating: 0.9), max(outer - inner, 0) * wearMask)
                }
            }
            return t
        }
    }

    // MARK: - Barrier walls

    /// Inner face of the barrier: u from the deck up to the lip (1.36 m), v along 16 m of track.
    /// `label` is lettered along `.label` sections; it reads left to right from the road
    /// on the right-hand wall, and on the left-hand one once the mesh flips v.
    static func wall(_ pattern: WallPattern, theme: TrackTheme, seed: UInt64, label: String = "") -> TextureSet {
        let lettering = pattern == .label ? TextMask(label) : nil
        let base = MetalBase(seed: seed)
        let n = base.noise
        let dark = SIMD3<Float>(0.04, 0.042, 0.046)
        return bake(width: 128, height: 1024) { u, v in
            let m = base.sample(u * 0.125, v, cells: 4)
            let p = plates(u, v, cols: 1, rows: 4, size: SIMD2(40, 16), seam: 0.05, stagger: false, noise: n)
            var t = Texel()
            t.albedo = theme.hull * (0.9 + p.tint * 0.4) * m.tone * 1.5
            t.rough = 0.36 + m.wear * 0.2
            corrode(&t, wear: m.wear, grain: m.grain, amount: theme.rust)
            t.height = -p.seam
            t.albedo *= 1 - p.seam * 0.7
            // Dark lip and kick plate.
            let trim = max(1 - smoothstep(0.06, 0.08, u), smoothstep(0.9, 0.92, u))
            t.albedo = simd_mix(t.albedo, dark, SIMD3(repeating: trim * 0.8))
            t.height += trim * 0.5

            let y = v * 16, x = u * 1.36          // metres
            let cream = SIMD3<Float>(0.86, 0.83, 0.74)
            let scuff = 0.7 + m.wear * 0.3
            switch pattern {
            case .strip:
                t.paint(theme.paint, band(u - 0.68, 0.035, 0.02) * scuff)
                let vent = band(u - 0.3, 0.1, 0.02) * band(fract(y / 0.25) - 0.5, 0.25, 0.08)
                    * band(fract(v * 4) - 0.5, 0.3, 0.01)
                t.albedo = simd_mix(t.albedo, dark, SIMD3(repeating: vent))
                t.height -= vent * 0.6
            case .blocks:
                // Two-colour marker blocks through corners, like the kerbs.
                let back = band(u - 0.5, 0.3, 0.02)
                t.paint(fract(y / 4) < 0.5 ? theme.paint : cream, back * scuff)
            case .hazard:
                let back = band(u - 0.48, 0.3, 0.02)
                let stripe = band(fract((x + y) / 0.8) - 0.5, 0.25, 0.04)
                t.paint(dark, back)
                t.paint(theme.paint, back * stripe * scuff)
            case .label:
                let back = band(u - 0.47, 0.3, 0.02)
                t.paint(dark, back)
                // Twice per section, reading against +v.
                let q = SIMD2(4 - (y.truncatingRemainder(dividingBy: 8)), x)
                t.paint(cream, lettering!.coverage(q, center: SIMD2(0, 0.64), size: 0.5) * back)
            }
            return t
        }
    }

    // MARK: - Structure

    /// Ribbed structural plating, 8 m square. Used for the hull, pylons and gates.
    static func hull(theme: TrackTheme, seed: UInt64) -> TextureSet {
        let base = MetalBase(seed: seed)
        let n = base.noise
        return bake(width: 512, height: 512, bump: 3) { u, v in
            let m = base.sample(u, v)
            let p = plates(u, v, cols: 2, rows: 4, size: SIMD2(8, 8), seam: 0.06, stagger: true, noise: n)
            var t = Texel()
            t.albedo = theme.hull * (0.75 + p.tint * 0.5) * m.tone
            t.rough = 0.42 + m.wear * 0.25
            corrode(&t, wear: m.wear, grain: m.grain, amount: theme.rust)
            let rib = band(fract(u * 16) - 0.5, 0.12, 0.05) * Float(p.tint > 0.55 ? 1 : 0)
            t.height = -p.seam + rib * 0.5 + p.bolt * 0.4
            t.albedo *= (1 - p.seam * 0.7) * (1 + rib * 0.12)
            return t
        }
    }

    /// Underside keel with recessed light bars: u across, v along 8 m.
    static func belly(theme: TrackTheme, seed: UInt64) -> TextureSet {
        let base = MetalBase(seed: seed)
        let n = base.noise
        return bake(width: 256, height: 512) { u, v in
            let m = base.sample(u, v, cells: 2)
            let p = plates(u, v, cols: 2, rows: 2, size: SIMD2(6, 8), seam: 0.06, stagger: false, noise: n)
            var t = Texel()
            t.albedo = theme.hull * (0.7 + p.tint * 0.4) * m.tone
            t.rough = 0.45 + m.wear * 0.2
            corrode(&t, wear: m.wear, grain: m.grain, amount: theme.rust)
            t.height = -p.seam
            t.glow(theme.neonA, box(u - 0.5, v - 0.5, 0.2, 0.2, 0.01))
            return t
        }
    }

    // MARK: - Cars

    // Car textures share one layout, 4 m across by 2 m along the car. Across, the texture is
    // folded about the centre line so both halves of a car mirror: decks use the first 1.3 m
    // (distance from the centre line) and flanks the rest, starting `carFlank` out, where the
    // distance is height above the road.

    /// Metres one copy of a car texture covers: across, then along.
    static let carTile = SIMD2<Float>(4, 2)
    /// Where a flank at road height sits across the texture, in metres.
    static let carFlank: Float = 1.1
    /// A spot on a deck with nothing on it in any texture: surfaces mapped here stay clean for lettering.
    static let carBlank = SIMD2<Float>(0.5, 0.75)

    /// Metres from the centre line (0...2) and along the car (0..<2) for a texture coordinate.
    @inline(__always) private static func carSpace(_ u: Float, _ v: Float) -> (a: Float, z: Float) {
        (abs(fract(u + 0.5) - 0.5) * carTile.x, v * carTile.y)
    }

    /// Painted bodywork: a few broad panel gaps and a vent under light wear.
    static let carPanels = carDetail(panels: true, rough: 0.34, seed: 0xCA7)
    /// Bare structure (floor, arms, nozzles): brushed and scuffed, no seams.
    static let carMetal = carDetail(panels: false, rough: 0.45, seed: 0xCA8)

    /// Colourless detail for `TextureSet.overlay`: white leaves the paint alone.
    private static func carDetail(panels: Bool, rough: Float, seed: UInt64) -> TextureSet {
        let base = MetalBase(seed: seed)
        let length = carTile.y
        /// Lengthwise gaps: one down each side of the spine and a belt line low on the flank.
        let spine: Float = 0.24, belt = carFlank + 0.44
        /// The one gap across, from the spine gap over the deck edge and down to the belt line.
        let cut: Float = 1.45
        return bake(width: 1024, height: 512, bump: 2.5) { u, v in
            let m = base.sample(u, v)
            var t = Texel()
            var shade = 1 - m.wear * 0.06 + (m.tone - 1) * 0.2
            t.rough = rough + m.wear * 0.16 + m.grain * 0.03
            guard panels else {
                t.albedo = SIMD3(repeating: shade - 0.04 + m.grain * 0.04)
                t.height = m.grain * 0.08
                return t
            }

            let (a, z) = carSpace(u, v)
            var gap = min(abs(a - spine), abs(a - belt))
            if a > spine && a < belt { gap = min(gap, abs(z - cut), length - abs(z - cut)) }
            // Everything here is several texels wide with soft edges: a line near one texel
            // crawls as the car moves, and a sharp groove sparkles under the lacquer.
            let seam = 1 - smoothstep(0.011, 0.019, gap)
            let groove = 1 - smoothstep(0.004, 0.028, gap)
            // Three broad slats let into the deck.
            let slats = band(fract((z - 0.085) / 0.09) - 0.5, 0.2, 0.07) * box(a - 0.42, z - 0.22, 0.07, 0.135, 0.006)

            // Grime gathers along the gaps, so each panel reads as its own piece.
            shade -= (1 - smoothstep(0, 0.06, gap)) * 0.06
            shade *= (1 - seam * 0.58) * (1 - slats * 0.7)
            t.albedo = SIMD3(repeating: shade)
            t.rough += seam * 0.4 + slats * 0.4
            t.height = -groove * 0.45 - slats * 0.5
            return t
        }
    }

    /// Smoked tint lightens towards the crown. Highlights come from the scene environment.
    static let canopy: UIImage = image(width: 4, height: 64) { _, v in
        SIMD3(repeating: mix(0.26, 0.64, smoothstep(0.1, 1, v)))
    }

    static let carLiveryStyles = 3
    private static let liveries = NSCache<NSString, UIImage>()

    /// Paint with racing graphics in a second colour: stripes down the deck and a band of
    /// marks along each flank, pointing forward. One texture per colour pair and style.
    static func carLivery(paint: SIMD3<Float>, graphics: SIMD3<Float>, style: Int) -> UIImage {
        func hex(_ c: SIMD3<Float>) -> String {
            let v = simd_clamp(c, .zero, SIMD3(repeating: 1)) * 255
            return String(format: "%02X%02X%02X", Int(v.x), Int(v.y), Int(v.z))
        }
        let key = "\(hex(paint))-\(hex(graphics))-\(style)" as NSString
        if let image = liveries.object(forKey: key) { return image }
        let image = image(width: 1024, height: 512) { u, v in
            let (a, z) = carSpace(u, v)
            return simd_mix(paint, graphics, SIMD3(repeating: liveryMask(a, z, style: style)))
        }
        liveries.setObject(image, forKey: key)
        return image
    }

    /// Coverage of the second colour. The flank band sits on the upper bodywork, 0.47 to 0.62 m
    /// above the road; the nose is towards −z, so marks lean and point that way.
    private static func liveryMask(_ a: Float, _ z: Float, style: Int) -> Float {
        let aa: Float = 0.004
        let dy = a - carFlank - 0.545
        let flank = band(dy, 0.075, aa)
        /// Stripes `pitch` apart whose position along the car is `s`; `fill` is the painted share.
        func stripes(_ s: Float, pitch: Float, fill: Float) -> Float {
            band(fract(s / pitch) - 0.5, fill / 2, aa / pitch)
        }
        /// 1 while `s` is between `from` and `to`.
        func span(_ s: Float, _ from: Float, _ to: Float) -> Float {
            band(s - (from + to) / 2, (to - from) / 2, aa)
        }
        switch style % carLiveryStyles {
        case 0:
            // >>>>> then a pin line to the next run; twin stripes either side of the spine.
            let s = z - abs(dy) * 1.3
            let run = stripes(s, pitch: 0.22, fill: 0.42) * span(s, 0.0, 1.1)
            let pin = band(dy, 0.02, aa) * span(s, 1.16, 1.96)
            return max(band(a - 0.11, 0.035, aa), flank * run, pin)
        case 1:
            // ////// hazard block; one broad stripe down the spine with a keyline.
            let s = z + dy * 1.0
            let block = stripes(s, pitch: 0.15, fill: 0.5) * span(s, 0.15, 1.05)
            return max(band(a, 0.085, aa), band(a - 0.15, 0.02, aa), flank * block)
        default:
            // A solid band with an arrowhead cut out of it every metre; stripes beside the canopy.
            let s = z - abs(dy) * 1.3
            let cut = stripes(s, pitch: 1.0, fill: 0.08) + stripes(s - 0.13, pitch: 1.0, fill: 0.08)
            return max(band(a - 0.32, 0.03, aa), flank * (1 - min(cut, 1)))
        }
    }

    /// A piece of lettering ready to lay on a car: the image and its width over its height.
    final class Lettering {
        let image: UIImage
        let aspect: Float
        init(image: UIImage, aspect: Float) { self.image = image; self.aspect = aspect }
    }

    private static let letterings = NSCache<NSString, Lettering>()

    /// Stencil lettering for a car decal, in the track signage's hand. On its own it is `color`
    /// on clear; with a `plate` it sits on a rounded board of that colour, as race numbers do.
    static func lettering(_ text: String, color: SIMD3<Float>, plate: SIMD3<Float>? = nil) -> Lettering {
        let key = "\(text)-\(color)-\(String(describing: plate))" as NSString
        if let made = letterings.object(forKey: key) { return made }
        let mask = TextMask(text, height: 96)
        let pad = plate == nil ? 0 : mask.height / 3
        let w = mask.width + 2 * pad, h = mask.height + 2 * pad
        let radius = Float(h) * 0.24
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let ink = mask.sample((Float(x - pad) + 0.5) / Float(mask.width),
                                      1 - (Float(y - pad) + 0.5) / Float(mask.height))
                var rgb = color, alpha = ink
                if let plate {
                    let qx = abs(Float(x) + 0.5 - Float(w) / 2) - (Float(w) / 2 - radius)
                    let qy = abs(Float(y) + 0.5 - Float(h) / 2) - (Float(h) / 2 - radius)
                    let edge = sqrt(max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)) + min(max(qx, qy), 0) - radius
                    alpha = 1 - smoothstep(-1, 1, edge)
                    rgb = simd_mix(plate, color, SIMD3(repeating: ink))
                }
                // Premultiplied, so the clear surround never bleeds a fringe into the edge.
                let v = simd_clamp(rgb * alpha, .zero, SIMD3(repeating: 1)) * 255
                let i = (y * w + x) * 4
                pixels[i] = UInt8(v.x); pixels[i + 1] = UInt8(v.y); pixels[i + 2] = UInt8(v.z)
                pixels[i + 3] = UInt8(min(max(alpha, 0), 1) * 255)
            }
        }
        let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                         shouldInterpolate: true, intent: .defaultIntent)!
        let made = Lettering(image: UIImage(cgImage: cg), aspect: Float(w) / Float(h))
        letterings.setObject(made, forKey: key)
        return made
    }

    /// One block of tyre tread: u once per block round the wheel, v across the tread.
    static let tyreTread: TextureSet = bake(width: 128, height: 256, bump: 3) { u, v in
        let c = abs(v - 0.5)
        // Chevron grooves, two channels round the tyre and slots in the shoulders.
        let chevron = band(fract(u + c * 1.1) - 0.5, 0.11, 0.03) * (1 - smoothstep(0.36, 0.4, c))
        let channel = band(c - 0.14, 0.022, 0.012)
        let slot = band(fract(u * 2) - 0.5, 0.14, 0.04) * smoothstep(0.38, 0.42, c)
        let groove = max(chevron, channel, slot)
        var t = Texel()
        t.albedo = SIMD3(repeating: 1 - groove * 0.6)
        t.rough = 0.8 + groove * 0.15
        t.height = -groove
        return t
    }

    // MARK: - Studio

    /// Softboxes on the ceiling and two walls of a dark photographic studio.
    /// Project rays onto flat panels so their edges stay straight in the reflected room.
    static let studio: UIImage = image(width: 512, height: 256) { u, v in
        let azimuth = 2 * Float.pi * u, polar = Float.pi * v
        let ray = SIMD3(sin(polar) * cos(azimuth), cos(polar), sin(polar) * sin(azimuth))
        var light = SIMD3<Float>(0.043, 0.050, 0.062)
        if ray.y > 0 {
            let x = ray.x / ray.y, z = ray.z / ray.y
            let ceiling = box(x + 0.30, z, 0.48, 1.45, 0.075)
            light += SIMD3(0.95, 0.94, 0.90) * ceiling
        }
        if ray.x > 0 {
            let z = ray.z / ray.x, y = ray.y / ray.x
            let strip = box(z + 0.15, y - 0.38, 1.55, 0.14, 0.035)
            light += SIMD3(0.88, 0.93, 0.98) * strip
        }
        if ray.z < 0 {
            let x = ray.x / -ray.z, y = ray.y / -ray.z
            let upright = box(x + 0.62, y - 0.36, 0.19, 0.58, 0.055)
            light += SIMD3(0.72, 0.77, 0.82) * upright
        }
        return light
    }

    // MARK: - Tunnels and halls

    /// Interior cladding: u is 8 m around the cross-section, v is 16 m along the track.
    /// A rib closes each section, with a light tube and cable trays between ribs.
    static func tunnelWall(theme: TrackTheme, seed: UInt64) -> TextureSet {
        let base = MetalBase(seed: seed)
        let n = base.noise
        let dark = SIMD3<Float>(0.03, 0.032, 0.036)
        return bake(width: 512, height: 1024, bump: 3) { u, v in
            let m = base.sample(u, v)
            let p = plates(u, v, cols: 4, rows: 4, size: SIMD2(8, 16), seam: 0.05, stagger: true, noise: n)
            var t = Texel()
            t.albedo = theme.hull * (0.8 + p.tint * 0.5) * m.tone
            t.rough = 0.4 + m.wear * 0.25
            corrode(&t, wear: m.wear, grain: m.grain, amount: theme.rust)
            t.height = -p.seam + p.bolt * 0.4
            t.albedo *= 1 - p.seam * 0.7
            // Structural rib across the direction of travel, with a thin signal line.
            let rib = max(band(v, 0.035, 0.004), band(v - 1, 0.035, 0.004))
            t.albedo = simd_mix(t.albedo, dark, SIMD3(repeating: rib * 0.85))
            t.height += rib * 1.2
            // Continuous light tube in a dark recess.
            let recess = band(u - 0.5, 0.045, 0.006) * (1 - rib)
            t.albedo = simd_mix(t.albedo, dark, SIMD3(repeating: recess))
            t.height -= recess * 0.6
            t.glow(theme.window, band(u - 0.5, 0.016, 0.006) * (1 - rib) * 0.8)
            // Cable trays.
            let tray = max(band(u - 0.2, 0.025, 0.004), band(u - 0.8, 0.025, 0.004)) * (1 - rib)
            let cable = 0.5 + 0.5 * sin(u * 8 * 160 * .pi)
            t.albedo = simd_mix(t.albedo, dark * (1 + cable), SIMD3(repeating: tray * 0.8))
            t.height += tray * cable * 0.5
            // Small forward ticks beside the tube.
            let tick = chevron((u - 0.36) * 8, fract(v * 8) - 0.7, halfWidth: 0.3, slope: 0.5,
                               thickness: 0.035, aa: 0.01) * (1 - rib)
            t.paint(theme.paint, tick * (0.5 + m.wear * 0.3))
            return t
        }
    }

    /// Chamfer between wall and ceiling: a row of framed light panels, four per section.
    static func tunnelLight(theme: TrackTheme, seed: UInt64) -> TextureSet {
        let base = MetalBase(seed: seed)
        let warm = simd_mix(theme.window, SIMD3(repeating: 1), SIMD3(repeating: 0.3))
        return bake(width: 64, height: 512) { u, v in
            let m = base.sample(u * 0.25, v, cells: 4)
            var t = Texel()
            t.albedo = theme.hull * 0.7 * m.tone
            t.rough = 0.45
            let lv = fract(v * 4)
            let panel = band(u - 0.5, 0.3, 0.03) * band(lv - 0.5, 0.36, 0.01)
            let frame = band(u - 0.5, 0.36, 0.03) * band(lv - 0.5, 0.4, 0.01)
            t.height = frame * 0.6 - panel * 0.4
            t.albedo *= 1 - (frame - panel) * 0.6
            // Diffuser slats.
            let slat = 0.82 + 0.18 * sin(lv * 40 * .pi)
            t.glow(warm, panel * slat)
            return t
        }
    }

    // MARK: - City

    /// Tower cladding with lit windows; one copy covers 48 m × 48 m (16 bays × 16 floors).
    static func facade(variant: Int, theme: TrackTheme, seed: UInt64) -> TextureSet {
        let base = MetalBase(seed: seed)
        let n = base.noise
        let glass = SIMD3<Float>(0.03, 0.04, 0.06)
        return bake(width: 512, height: 512, bump: 1.5) { u, v in
            let m = base.sample(u, v)
            var t = Texel()
            t.albedo = theme.hull * 0.8 * m.tone
            t.rough = 0.5
            let col = Int((u * 16).rounded(.down)), row = Int((v * 16).rounded(.down))
            let lu = fract(u * 16), lv = fract(v * 16)
            let h = n.hash(col * 3 + variant * 17, row * 5 + 1)
            switch variant % 3 {
            case 0:
                // Punched windows, randomly lit.
                let w = box(lu - 0.5, lv - 0.48, 0.36, 0.3, 0.04)
                let lit: Float = h & 7 < 3 ? 0.35 + Float(h >> 3 & 7) / 10 : 0
                t.albedo = simd_mix(t.albedo, glass, SIMD3(repeating: w))
                t.metal = mix(1, 0, w); t.rough = mix(0.5, 0.08, w)
                t.emission = theme.window * w * lit
                t.height = -w * 0.6
            case 1:
                // Ribbon glazing: whole floors lit in runs.
                let w = band(lv - 0.45, 0.3, 0.04) * band(lu - 0.5, 0.47, 0.03)
                let run = n.hash(col / 4 + 9, row * 7 + variant)
                let lit: Float = run & 3 == 0 ? 0.7 : (run & 3 == 1 ? 0.25 : 0)
                t.albedo = simd_mix(t.albedo, glass, SIMD3(repeating: w))
                t.metal = mix(1, 0, w); t.rough = mix(0.5, 0.08, w)
                t.emission = simd_mix(theme.window, theme.neonA, SIMD3(repeating: 0.35)) * w * lit
                t.height = -w * 0.6
            default:
                // Dark monolith with neon risers and a few service lights.
                t.albedo *= 0.6
                let riser = col % 8 == 3 ? band(lu - 0.5, 0.16, 0.05) : 0
                let color = col % 16 == 3 ? theme.neonA : theme.neonB
                t.emission = color * riser * 0.5 * Float(row % 4 == 0 ? 0 : 1) * Float(col % 16 == 3 ? 1 : 0)
                let dot = h & 31 == 0 ? box(lu - 0.5, lv - 0.5, 0.12, 0.12, 0.04) : 0
                t.emission += theme.window * dot
                t.height = -band(lv, 0.04, 0.02) * 0.5 - riser * 0.4
            }
            return t
        }
    }

    /// The city floor far below: a grid of lit streets and blocks, one copy per 800 m.
    static func cityFloor(theme: TrackTheme, seed: UInt64) -> TextureSet {
        let n = Noise2D(seed: seed)
        return bake(width: 512, height: 512, bump: 0) { u, v in
            var t = Texel()
            t.albedo = theme.hull * 0.25
            t.metal = 0; t.rough = 0.8
            let lu = fract(u * 16), lv = fract(v * 16)
            let street = max(band(lu, 0.04, 0.02), band(lu - 1, 0.04, 0.02), band(lv, 0.04, 0.02), band(lv - 1, 0.04, 0.02))
            let dashes = band(fract(u * 128) - 0.5, 0.25, 0.1) * band(fract(v * 128) - 0.5, 0.25, 0.1)
            t.emission = theme.window * street * dashes * 0.9
            let h = n.hash(Int((u * 64).rounded(.down)), Int((v * 64).rounded(.down)))
            let block = (1 - street) * box(fract(u * 64) - 0.5, fract(v * 64) - 0.5, 0.3, 0.3, 0.1)
            if h & 7 == 0 { t.emission += (h & 8 == 0 ? theme.neonA : theme.neonB) * block * 0.5 }
            if h & 7 == 1 { t.emission += theme.window * block * 0.3 }
            return t
        }
    }

    /// Equirectangular sky: gradient, horizon glow, haze streaks and stars. Also lights the metal.
    static func sky(theme: TrackTheme, seed: UInt64) -> UIImage {
        let n = Noise2D(seed: seed)
        return image(width: 2048, height: 1024) { u, v in
            let elevation = (0.5 - v) * .pi
            let h = sin(elevation)
            var c: SIMD3<Float>
            if h >= 0 {
                c = simd_mix(theme.skyHorizon, theme.skyZenith, SIMD3(repeating: pow(h, 0.45)))
                let streak = n.fbm(u * 8, v * 40, octaves: 3, period: 8) * 0.5 + 0.5
                let cloud = smoothstep(0.5, 0.8, streak) * exp(-pow(elevation / 0.5, 2))
                c += theme.skyGlow * cloud * 0.25
                let cell = n.cellular(u * 240, v * 120, cells: 240)
                let star = (1 - smoothstep(0.03, 0.09, cell.f1)) * Float(cell.id & 7 == 0 ? 1 : 0)
                c += SIMD3(repeating: star * theme.stars * smoothstep(0.1, 0.5, h) * 0.9)
            } else {
                c = simd_mix(theme.skyHorizon, theme.skyHorizon * 0.3, SIMD3(repeating: smoothstep(0, 0.6, -h)))
            }
            let glow = exp(-pow(elevation / 0.13, 2)) * (0.55 + 0.45 * n.fbm(u * 6, 0.5, octaves: 2, period: 6))
            return c + theme.skyGlow * glow * 0.35
        }
    }
}
