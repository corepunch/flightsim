import SceneKit
import simd

struct PathSample {
    var position: SIMD3<Float>
    var forward: SIMD3<Float>    // normalised, tangent to curve
    var right: SIMD3<Float>      // normalised, banked with the deck
    var up: SIMD3<Float>         // normalised, deck normal
    var arcLength: Float         // cumulative distance from sample[0]
    var halfWidth: Float         // deck half-width in metres
    var curvature: Float = 0     // signed 1/m, positive turning right

    var deckEdges: (left: SIMD3<Float>, right: SIMD3<Float>) {
        let edge = right * (halfWidth + TrackMeshBuilder.barrierOffset)
        return (position - edge, position + edge)
    }
}

final class TrackPath {

    let definition: TrackDefinition
    let samples: [PathSample]
    let totalLength: Float
    let stepCount: Int

    // 2-D bounds (XZ plane) for minimap projection
    let boundsMin: SIMD2<Float>
    let boundsMax: SIMD2<Float>

    /// Samples per texture section; `stepCount` is always a multiple of it.
    static let sectionSamples = 8
    var sectionCount: Int { stepCount / Self.sectionSamples }

    /// Resamples the closed Catmull-Rom loop at uniform arc length (`spacing` metres).
    init(definition: TrackDefinition = TrackLibrary.all[0], spacing: Float = 2) {
        self.definition = definition
        let pts = definition.curve.controlPoints()
        let n = pts.count

        // Dense evaluation for arc-length parameterisation.
        let dense = n * 64
        var densePos = [SIMD3<Float>]()
        var denseLen = [Float]()
        densePos.reserveCapacity(dense + 1)
        var acc: Float = 0
        for i in 0...dense {
            let t = Float(i) / Float(dense) * Float(n)
            let seg = Int(t) % n
            let u = i == dense ? 0 : t - floor(t)
            let p = catmullRom(pts[(seg - 1 + n) % n], pts[seg], pts[(seg + 1) % n], pts[(seg + 2) % n], u)
            if let last = densePos.last { acc += simd_length(p - last) }
            densePos.append(p)
            denseLen.append(acc)
        }
        let length = acc
        let count = max(8, Int((length / spacing / Float(Self.sectionSamples)).rounded())) * Self.sectionSamples
        let step = length / Float(count)
        self.stepCount = count
        self.totalLength = length

        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(count)
        var j = 0
        for i in 0..<count {
            let target = Float(i) * step
            while j < dense - 1 && denseLen[j + 1] < target { j += 1 }
            let segLen = max(denseLen[j + 1] - denseLen[j], 1e-5)
            let f = (target - denseLen[j]) / segLen
            positions.append(densePos[j] + (densePos[j + 1] - densePos[j]) * f)
        }

        // Frames, curvature and zone data.
        func at(_ i: Int) -> SIMD3<Float> { positions[((i % count) + count) % count] }
        var forwards = [SIMD3<Float>](repeating: .zero, count: count)
        var curvatures = [Float](repeating: 0, count: count)
        for i in 0..<count {
            forwards[i] = simd_normalize(at(i + 1) - at(i - 1))
        }
        for i in 0..<count {
            let a = forwards[(i - 3 + count) % count], b = forwards[(i + 3) % count]
            let ah = simd_normalize(SIMD2(a.x, a.z)), bh = simd_normalize(SIMD2(b.x, b.z))
            let cross = ah.x * bh.y - ah.y * bh.x
            curvatures[i] = asin(max(-1, min(1, cross))) / (6 * step)
        }
        // Smooth curvature so banking eases in and out.
        for _ in 0..<4 {
            var next = curvatures
            for i in 0..<count {
                var s: Float = 0
                for k in -4...4 { s += curvatures[((i + k) % count + count) % count] }
                next[i] = s / 9
            }
            curvatures = next
        }

        var rng = SplitMix64(seed: definition.seed &+ 77)
        let widthPhase = SIMD2<Float>(rng.float(0...(2 * .pi)), rng.float(0...(2 * .pi)))

        var built = [PathSample]()
        built.reserveCapacity(count)
        for i in 0..<count {
            let progress = Float(i) / Float(count)
            let fwd = forwards[i]
            let flatRight = simd_normalize(simd_cross(fwd, SIMD3<Float>(0, 1, 0)))
            let bank = max(-0.3, min(0.3, curvatures[i] * 26 * definition.banking))
            let q = simd_quatf(angle: bank, axis: fwd)
            let right = q.act(flatRight)
            let up = simd_normalize(simd_cross(right, fwd))
            let swell = 0.6 * sin(progress * 4 * .pi + widthPhase.x) + 0.4 * sin(progress * 10 * .pi + widthPhase.y)
            built.append(PathSample(
                position: positions[i], forward: fwd, right: right, up: up,
                arcLength: Float(i) * step,
                halfWidth: definition.halfWidth + definition.widthVariation * swell,
                curvature: curvatures[i]))
        }

        samples = built

        // Compute XZ bounds for minimap
        var minX = Float.greatestFiniteMagnitude, minZ = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
        for s in built {
            minX = min(minX, s.position.x); maxX = max(maxX, s.position.x)
            minZ = min(minZ, s.position.z); maxZ = max(maxZ, s.position.z)
        }
        boundsMin = SIMD2<Float>(minX - 20, minZ - 20)
        boundsMax = SIMD2<Float>(maxX + 20, maxZ + 20)
    }

    // Returns index of sample nearest to world position (XZ distance).
    func closestSampleIndex(to world: SIMD3<Float>) -> Int {
        var bestIdx = 0
        var bestDist = Float.greatestFiniteMagnitude
        for (i, s) in samples.enumerated() {
            let d = simd_length_squared(SIMD2<Float>(world.x - s.position.x, world.z - s.position.z))
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return bestIdx
    }

    func sample(at index: Int) -> PathSample {
        return samples[((index % stepCount) + stepCount) % stepCount]
    }

    /// Metres between consecutive samples.
    var step: Float { totalLength / Float(stepCount) }

    /// Signed clearance above the road triangle under this XZ position. Walk from the
    /// car's lap position so a crossing or a nearby parallel road cannot steal the car.
    func ground(at position: SIMD3<Float>, near distance: Float) -> (clearance: Float, normal: SIMD3<Float>)? {
        var index = Int(floor(distance / step))
        for _ in 0..<stepCount {
            let a = sample(at: index), b = sample(at: index + 1)
            if simd_cross(a.right, position - a.position).y < -0.0001 { index -= 1; continue }
            if simd_cross(b.right, position - b.position).y > 0.0001 { index += 1; continue }

            let start = a.deckEdges, end = b.deckEdges
            let offset = position - start.left
            guard simd_cross(end.right - start.right, position - start.right).y >= -0.001,
                  simd_cross(start.left - end.left, position - end.left).y >= -0.001 else { return nil }
            // Same diagonal as the two triangles in the collision deck.
            let diagonal = end.right - start.left
            let normal = simd_cross(offset, diagonal).y >= 0
                ? simd_cross(start.right - start.left, diagonal)
                : simd_cross(diagonal, end.left - start.left)
            guard normal.y > 0 else { return nil }
            let up = simd_normalize(normal)
            return (simd_dot(offset, up), up)
        }
        return nil
    }

    /// The deck frame at any distance round the lap (wraps), interpolated between samples.
    func frame(at distance: Float) -> PathSample {
        let f = distance / step
        let i = Int(f.rounded(.down))
        let t = f - Float(i)
        let a = sample(at: i), b = sample(at: i + 1)
        return PathSample(
            position: a.position + (b.position - a.position) * t,
            forward: simd_normalize(a.forward + (b.forward - a.forward) * t),
            right: simd_normalize(a.right + (b.right - a.right) * t),
            up: simd_normalize(a.up + (b.up - a.up) * t),
            arcLength: distance,
            halfWidth: a.halfWidth + (b.halfWidth - a.halfWidth) * t,
            curvature: a.curvature + (b.curvature - a.curvature) * t)
    }

    // Projects a world XZ position to normalised [0,1] minimap coordinates.
    func minimapPosition(for world: SIMD3<Float>) -> SIMD2<Float> {
        let range = boundsMax - boundsMin
        return SIMD2<Float>(
            (world.x - boundsMin.x) / range.x,
            (world.z - boundsMin.y) / range.y
        )
    }
}

// MARK: - Catmull-Rom

private func catmullRom(
    _ p0: SIMD3<Float>, _ p1: SIMD3<Float>,
    _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, _ t: Float
) -> SIMD3<Float> {
    let t2 = t * t, t3 = t2 * t
    let constant: SIMD3<Float> = 2 * p1
    let linear: SIMD3<Float> = (-p0 + p2) * t
    let quadratic: SIMD3<Float> = (2 * p0 - 5 * p1) + 4 * p2 - p3
    let cubic: SIMD3<Float> = (-p0 + 3 * p1) - 3 * p2 + p3
    return 0.5 * (constant + linear + quadratic * t2 + cubic * t3)
}
