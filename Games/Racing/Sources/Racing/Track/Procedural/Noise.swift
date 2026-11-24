import Foundation
import simd

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func float(_ range: ClosedRange<Float> = 0...1) -> Float {
        Float.random(in: range, using: &self)
    }
}

/// Seeded 2-D gradient noise with optional lattice wrapping for tileable textures.
struct Noise2D {
    private let perm: [Int]

    init(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var p = Array(0..<256)
        p.shuffle(using: &rng)
        perm = p + p
    }

    @inline(__always) func hash(_ x: Int, _ y: Int) -> Int {
        perm[perm[x & 255] + (y & 255)]
    }

    @inline(__always) private func grad(_ h: Int, _ x: Float, _ y: Float) -> Float {
        switch h & 7 {
        case 0: return  x + y
        case 1: return -x + y
        case 2: return  x - y
        case 3: return -x - y
        case 4: return  x * 1.4142
        case 5: return -x * 1.4142
        case 6: return  y * 1.4142
        default: return -y * 1.4142
        }
    }

    @inline(__always) private func wrap(_ v: Int, _ period: Int) -> Int {
        period > 0 ? ((v % period) + period) % period : v
    }

    /// Gradient noise, roughly in [-1, 1]. `period` (in lattice cells) makes it tile.
    func noise(_ x: Float, _ y: Float, period: Int = 0) -> Float {
        let xf = x.rounded(.down), yf = y.rounded(.down)
        let xi = Int(xf), yi = Int(yf)
        let x0 = wrap(xi, period), x1 = wrap(xi + 1, period)
        let y0 = wrap(yi, period), y1 = wrap(yi + 1, period)
        let fx = x - xf, fy = y - yf
        let u = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
        let v = fy * fy * fy * (fy * (fy * 6 - 15) + 10)
        let a = grad(hash(x0, y0), fx, fy)
        let b = grad(hash(x1, y0), fx - 1, fy)
        let c = grad(hash(x0, y1), fx, fy - 1)
        let d = grad(hash(x1, y1), fx - 1, fy - 1)
        let ab = a + (b - a) * u
        let cd = c + (d - c) * u
        return (ab + (cd - ab) * v) * 0.7
    }

    func fbm(_ x: Float, _ y: Float, octaves: Int, period: Int = 0, gain: Float = 0.5) -> Float {
        var sum: Float = 0, amp: Float = 1, norm: Float = 0
        var fx = x, fy = y, p = period
        for _ in 0..<octaves {
            sum += noise(fx, fy, period: p) * amp
            norm += amp
            amp *= gain
            fx *= 2; fy *= 2; p *= 2
        }
        return sum / norm
    }

    /// Ridged multifractal in [0, 1]: sharp crests for mountains and rock strata.
    func ridged(_ x: Float, _ y: Float, octaves: Int, period: Int = 0) -> Float {
        var sum: Float = 0, amp: Float = 0.5, norm: Float = 0, weight: Float = 1
        var fx = x, fy = y, p = period
        for _ in 0..<octaves {
            var n = 1 - abs(noise(fx, fy, period: p))
            n *= n * weight
            weight = min(max(n * 2, 0), 1)
            sum += n * amp
            norm += amp
            amp *= 0.5
            fx *= 2; fy *= 2; p *= 2
        }
        return sum / norm
    }

    /// Tileable Worley noise: (F1, F2, cell id) with `cells` feature points per axis.
    func cellular(_ x: Float, _ y: Float, cells: Int) -> (f1: Float, f2: Float, id: Int) {
        let cx = Int(x.rounded(.down)), cy = Int(y.rounded(.down))
        var f1: Float = 9, f2: Float = 9, id = 0
        for oy in -1...1 {
            for ox in -1...1 {
                let gx = cx + ox, gy = cy + oy
                let wx = wrap(gx, cells), wy = wrap(gy, cells)
                let h = hash(wx, wy)
                let jx = Float(h & 15) / 15 * 0.8 + 0.1
                let jy = Float(hash(wy + 17, wx + 31) & 15) / 15 * 0.8 + 0.1
                let dx = Float(gx) + jx - x, dy = Float(gy) + jy - y
                let d = sqrt(dx * dx + dy * dy)
                if d < f1 { f2 = f1; f1 = d; id = h } else if d < f2 { f2 = d }
            }
        }
        return (f1, f2, id)
    }
}

@inline(__always) func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}

@inline(__always) func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
