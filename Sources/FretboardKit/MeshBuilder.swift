import Foundation
import simd

public struct MeshResolution: Sendable {
    /// Spacing of cross-section slices along the length. The top surface is almost
    /// linear in X, so this can be coarse.
    public var xStep = 2.0
    /// Spacing of samples across the width (controls how well the radius arc is captured).
    public var yStep = 0.5
    /// Segments in each wide-end corner arc.
    public var cornerSteps = 24
    public init() {}
}

public struct Triangle: Sendable {
    public var a: SIMD3<Double>
    public var b: SIMD3<Double>
    public var c: SIMD3<Double>
    public var normal: SIMD3<Double> {
        let n = simd_cross(b - a, c - a)
        let len = simd_length(n)
        return len > 0 ? n / len : .zero
    }
}

/// Welded (indexed) triangle mesh. Triangles are counter-clockwise seen from outside.
public struct IndexedMesh: Sendable {
    public var vertices: [SIMD3<Double>] = []
    public var triangles: [SIMD3<Int32>] = []

    public var triangleCount: Int { triangles.count }

    public func triangle(_ i: Int) -> Triangle {
        let t = triangles[i]
        return Triangle(a: vertices[Int(t.x)], b: vertices[Int(t.y)], c: vertices[Int(t.z)])
    }

    public var allTriangles: [Triangle] { (0..<triangles.count).map(triangle) }

    /// Signed volume in mm^3 (positive for correctly oriented closed meshes).
    public var volume: Double {
        var v = 0.0
        for i in 0..<triangles.count {
            let t = triangle(i)
            v += simd_dot(t.a, simd_cross(t.b, t.c))
        }
        return v / 6
    }

    public var boundsMin: SIMD3<Double> {
        vertices.reduce(SIMD3<Double>(repeating: .infinity)) { simd_min($0, $1) }
    }
    public var boundsMax: SIMD3<Double> {
        vertices.reduce(SIMD3<Double>(repeating: -.infinity)) { simd_max($0, $1) }
    }

    /// True when every directed edge is matched by exactly one opposite edge.
    public var isWatertight: Bool {
        var edges = [UInt64: Int]()
        for t in triangles {
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                edges[Self.key(a, b), default: 0] += 1
            }
        }
        for (k, n) in edges {
            if n != 1 { return false }
            let a = Int32(truncatingIfNeeded: k >> 32), b = Int32(truncatingIfNeeded: k & 0xffff_ffff)
            if edges[Self.key(b, a)] != 1 { return false }
        }
        return true
    }

    static func key(_ a: Int32, _ b: Int32) -> UInt64 {
        (UInt64(UInt32(bitPattern: a)) << 32) | UInt64(UInt32(bitPattern: b))
    }
}

private struct Welder {
    struct Key: Hashable { var x, y, z: Int64 }
    var map: [Key: Int32] = [:]
    var vertices: [SIMD3<Double>] = []

    mutating func index(_ p: SIMD3<Double>) -> Int32 {
        let q = 1e4  // 0.1 micron
        let k = Key(x: Int64((p.x * q).rounded()), y: Int64((p.y * q).rounded()), z: Int64((p.z * q).rounded()))
        if let i = map[k] { return i }
        let i = Int32(vertices.count)
        vertices.append(p)
        map[k] = i
        return i
    }
}

public enum MeshBuilder {
    /// X positions of cross-section slices.
    static func sliceXs(_ L: FretboardLayout, _ res: MeshResolution) -> [Double] {
        var xs: [Double] = [0, L.xEnd, L.xLastFret, L.xNut, L.fretX(1), L.notchDepth]
        if L.cornerRadius > 0 {
            for k in 0...res.cornerSteps {
                let phi = Double.pi + (L.cornerEndAngle - Double.pi) * Double(k) / Double(res.cornerSteps)
                xs.append(L.cornerRadius * (1 + cos(phi)))
            }
        }
        if L.notchFillet > 0 {
            let r = L.notchFillet
            for k in 0...12 {
                let th = Double.pi / 2 * Double(k) / 12
                xs.append(L.notchDepth - r + r * sin(th))
            }
        }
        var x = L.cornerTangentX
        while x < L.xEnd { xs.append(x); x += res.xStep }
        xs = xs.filter { $0 >= 0 && $0 <= L.xEnd }.sorted()
        var out: [Double] = []
        for v in xs where out.last.map({ v - $0 > 1e-9 }) ?? true { out.append(v) }
        return out
    }

    /// Builds the closed solid: curved top, flat bottom, walls.
    ///
    /// The top surface is tiled by three structured grids (left of the cutout, right of
    /// the cutout, and the centre strip that only exists beyond the cutout depth). Walls
    /// are generated from the boundary edges of the top surface, which guarantees a
    /// watertight result.
    public static func build(_ L: FretboardLayout, resolution res: MeshResolution = MeshResolution()) -> IndexedMesh {
        let xs = sliceXs(L, res)
        let cm = L.notchBackHalfWidth   // seam half-width beyond the cutout / flat back wall
        let hwMax = xs.map { L.outlineHalfWidth(at: $0) }.max() ?? cm + 1
        let nl = max(2, Int(ceil((hwMax - cm) / res.yStep)))
        let m = max(2, Int(ceil(2 * cm / res.yStep)))
        let notch = L.notchDepth

        var w = Welder()
        func pt(_ x: Double, _ y: Double) -> SIMD3<Double> { SIMD3(x, y, L.topZ(x: x, y: y)) }

        var left: [[Int32]] = [], right: [[Int32]] = [], mid: [[Int32]] = []
        for x in xs {
            let hw = L.outlineHalfWidth(at: x)
            let c = L.notchHalfWidth(at: x)
            var l: [Int32] = [], r: [Int32] = []
            for j in 0...nl {
                let t = Double(j) / Double(nl)
                let yl = j == nl ? -c : -hw + (hw - c) * t
                let yr = j == 0 ? c : c + (hw - c) * t
                l.append(w.index(pt(x, yl)))
                r.append(w.index(pt(x, yr)))
            }
            left.append(l); right.append(r)
            if x >= notch - 1e-9 {
                var row: [Int32] = []
                for k in 0...m {
                    let y = k == 0 ? -cm : (k == m ? cm : -cm + 2 * cm * Double(k) / Double(m))
                    row.append(w.index(pt(x, y)))
                }
                mid.append(row)
            }
        }

        var top: [SIMD3<Int32>] = []
        func tile(_ rows: [[Int32]]) {
            guard rows.count >= 2 else { return }
            for i in 0..<(rows.count - 1) {
                for j in 0..<(rows[i].count - 1) {
                    let p00 = rows[i][j], p10 = rows[i + 1][j]
                    let p11 = rows[i + 1][j + 1], p01 = rows[i][j + 1]
                    top.append(SIMD3(p00, p10, p11))
                    top.append(SIMD3(p00, p11, p01))
                }
            }
        }
        tile(left); tile(right); tile(mid)

        // Boundary edges of the top surface (directed edge with no opposite partner).
        var edgeSet = Set<UInt64>()
        for t in top {
            edgeSet.insert(IndexedMesh.key(t.x, t.y))
            edgeSet.insert(IndexedMesh.key(t.y, t.z))
            edgeSet.insert(IndexedMesh.key(t.z, t.x))
        }
        var boundary: [(Int32, Int32)] = []
        for t in top {
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)]
            where !edgeSet.contains(IndexedMesh.key(b, a)) {
                boundary.append((a, b))
            }
        }

        // Bottom copy of every top vertex, at z = 0.
        let topVertexCount = w.vertices.count
        var bottomIndex = [Int32](repeating: -1, count: topVertexCount)
        func bottom(_ v: Int32) -> Int32 {
            let i = Int(v)
            if bottomIndex[i] < 0 {
                let p = w.vertices[i]
                bottomIndex[i] = w.index(SIMD3(p.x, p.y, 0))
            }
            return bottomIndex[i]
        }

        var tris = top
        for t in top { tris.append(SIMD3(bottom(t.x), bottom(t.z), bottom(t.y))) }
        for (a, b) in boundary {
            let a0 = bottom(a), b0 = bottom(b)
            tris.append(SIMD3(a, b0, b))
            tris.append(SIMD3(a, a0, b0))
        }

        var mesh = IndexedMesh()
        mesh.vertices = w.vertices
        mesh.triangles = tris
        return mesh
    }
}
