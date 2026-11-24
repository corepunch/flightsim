import SceneKit
import simd

/// Accumulates vertices and per-material triangle lists, then emits an SCNGeometry.
struct MeshBuilder {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var colors: [SIMD3<Float>] = []
    var uvs2: [SIMD2<Float>] = []
    var useColors = false
    var useUV2 = false
    private(set) var indices: [[UInt32]]

    init(materialCount: Int, colors: Bool = false, secondUV: Bool = false) {
        indices = Array(repeating: [], count: materialCount)
        useColors = colors
        useUV2 = secondUV
    }

    var isEmpty: Bool { indices.allSatisfy(\.isEmpty) }

    @discardableResult
    mutating func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float> = .zero,
                         color: SIMD3<Float> = SIMD3(repeating: 1), uv2: SIMD2<Float> = .zero) -> UInt32 {
        positions.append(p)
        normals.append(n)
        uvs.append(uv)
        if useColors { colors.append(color) }
        if useUV2 { uvs2.append(uv2) }
        return UInt32(positions.count - 1)
    }

    mutating func triangle(_ slot: Int, _ a: UInt32, _ b: UInt32, _ c: UInt32) {
        indices[slot].append(contentsOf: [a, b, c])
    }

    /// Quad a-b-c-d in counter-clockwise order (as seen from the front).
    mutating func quad(_ slot: Int, _ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) {
        indices[slot].append(contentsOf: [a, b, c, a, c, d])
    }

    /// Flat quad with its own vertices; UVs in metres (u along a→b, v along a→d).
    mutating func flatQuad(_ slot: Int, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                           _ d: SIMD3<Float>, uvOrigin: SIMD2<Float> = .zero,
                           color: SIMD3<Float> = SIMD3(repeating: 1)) {
        let n = simd_normalize(simd_cross(b - a, d - a))
        let w = simd_length(b - a), h = simd_length(d - a)
        let o = uvOrigin
        let i0 = vertex(a, n, SIMD2(o.x, o.y), color: color)
        let i1 = vertex(b, n, SIMD2(o.x + w, o.y), color: color)
        let i2 = vertex(c, n, SIMD2(o.x + w, o.y + h), color: color)
        let i3 = vertex(d, n, SIMD2(o.x, o.y + h), color: color)
        quad(slot, i0, i1, i2, i3)
    }

    /// Axis-aligned box in a local frame (`basis` columns = right, up, forward), base at `origin`.
    mutating func box(_ slot: Int, origin: SIMD3<Float>, basis: simd_float3x3,
                      size: SIMD3<Float>, color: SIMD3<Float> = SIMD3(repeating: 1),
                      top: Bool = true, topSlot: Int? = nil, vOffset: Float = 0) {
        let hx = size.x / 2, hz = size.z / 2
        func p(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { origin + basis * SIMD3(x, y, z) }
        let y0: Float = 0, y1 = size.y
        let c = [p(-hx, y0, -hz), p(hx, y0, -hz), p(hx, y0, hz), p(-hx, y0, hz)]
        let t = [p(-hx, y1, -hz), p(hx, y1, -hz), p(hx, y1, hz), p(-hx, y1, hz)]
        let o = SIMD2<Float>(0, vOffset)
        // Walls wind outward; u runs along the wall so facades tile horizontally.
        flatQuad(slot, c[3], c[2], t[2], t[3], uvOrigin: o, color: color)
        flatQuad(slot, c[2], c[1], t[1], t[2], uvOrigin: o, color: color)
        flatQuad(slot, c[1], c[0], t[0], t[1], uvOrigin: o, color: color)
        flatQuad(slot, c[0], c[3], t[3], t[0], uvOrigin: o, color: color)
        if top { flatQuad(topSlot ?? slot, t[3], t[2], t[1], t[0], color: color) }
    }

    /// Blends the normals of vertices that share a position wherever their faces meet at less
    /// than the crease angle, so gentle bends shade as curves and real edges stay sharp.
    mutating func smoothNormals(creaseCosine: Float = 0.8) {
        var groups: [SIMD3<Int32>: [Int]] = [:]
        for (i, p) in positions.enumerated() {
            let q = (p * 2000).rounded(.toNearestOrAwayFromZero)
            groups[SIMD3(Int32(q.x), Int32(q.y), Int32(q.z)), default: []].append(i)
        }
        let flat = normals
        for group in groups.values where group.count > 1 {
            for i in group {
                var sum = SIMD3<Float>.zero
                for j in group where simd_dot(flat[i], flat[j]) >= creaseCosine { sum += flat[j] }
                normals[i] = simd_normalize(sum)
            }
        }
    }

    /// Position-only mesh of every slot, for static collision shapes.
    func collisionGeometry() -> SCNGeometry {
        let all = indices.flatMap { $0 }
        let data = all.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: data, primitiveType: .triangles,
                                         primitiveCount: all.count / 3, bytesPerIndex: 4)
        return SCNGeometry(sources: [Self.source(positions, semantic: .vertex)], elements: [element])
    }

    /// `skipping` leaves out slots that exist only for collision.
    func geometry(materials: [SCNMaterial], skipping: Set<Int> = []) -> SCNGeometry {
        var sources = [
            Self.source(positions, semantic: .vertex),
            Self.source(normals, semantic: .normal),
        ]
        let uvData = uvs.withUnsafeBufferPointer { Data(buffer: $0) }
        sources.append(SCNGeometrySource(
            data: uvData, semantic: .texcoord, vectorCount: uvs.count, usesFloatComponents: true,
            componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0,
            dataStride: MemoryLayout<SIMD2<Float>>.stride))
        if useUV2 {
            let data = uvs2.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(
                data: data, semantic: .texcoord, vectorCount: uvs2.count, usesFloatComponents: true,
                componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0,
                dataStride: MemoryLayout<SIMD2<Float>>.stride))
        }
        if useColors { sources.append(Self.source(colors, semantic: .color)) }

        var elements = [SCNGeometryElement]()
        var used = [SCNMaterial]()
        for (slot, list) in indices.enumerated() where !list.isEmpty && !skipping.contains(slot) {
            let data = list.withUnsafeBufferPointer { Data(buffer: $0) }
            elements.append(SCNGeometryElement(data: data, primitiveType: .triangles,
                                               primitiveCount: list.count / 3, bytesPerIndex: 4))
            used.append(materials[slot])
        }
        let geo = SCNGeometry(sources: sources, elements: elements)
        geo.materials = used
        return geo
    }

    private static func source(_ v: [SIMD3<Float>], semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        let data = v.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(
            data: data, semantic: semantic, vectorCount: v.count, usesFloatComponents: true,
            componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride)
    }
}
