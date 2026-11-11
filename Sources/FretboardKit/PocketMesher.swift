import Foundation
import simd

extension MeshBuilder {
    /// Maximum edge length of the re-triangulated surface and floors. Keeps the flat triangles within a few
    /// microns of the radiused surface.
    static let pocketMaxEdge = 2.0
    /// Pocket outlines are split into edges no longer than this before meshing.
    static let pocketRingStep = 1.0

    private struct Ring {
        var pts: [SIMD2<Double>]
        var pocket: Int
        /// Even = pocket boundary (pocket on the left, counter-clockwise), odd = island (clockwise).
        var depth: Int
        var parent: Int?
    }

    /// Replaces the part of `top` around the pockets with a surface that has the pockets cut into it:
    /// the surrounding surface, vertical walls and the floors. Returns the new top surface. Boundary edges
    /// of the replaced region are kept exactly, so the result stays watertight against the rest of the solid.
    static func cutPockets(_ L: FretboardLayout, pockets: [Pocket], top: [SIMD3<Int32>], w: inout Welder) -> [SIMD3<Int32>] {
        // Rings: densified, nested and oriented.
        var rings: [Ring] = []
        for (pi, p) in pockets.enumerated() {
            let raw = p.rings.map { Geometry2D.densify(ring: $0, maxLen: pocketRingStep) }.filter { $0.count >= 3 }
            let depths = Geometry2D.nestingDepths(raw)
            let parents = Geometry2D.parents(raw)
            let base = rings.count
            for (i, r) in raw.enumerated() {
                let ccw = Geometry2D.signedArea(r) > 0
                let want = depths[i] % 2 == 0
                rings.append(Ring(pts: ccw == want ? r : r.reversed(), pocket: pi, depth: depths[i],
                                  parent: parents[i].map { $0 + base }))
            }
        }
        guard !rings.isEmpty else { return top }

        // Replace whole grid quads (consecutive triangle pairs) near each pocket.
        let margin = 1.5
        let boxes: [(SIMD2<Double>, SIMD2<Double>)] = pockets.indices.map { pi in
            let b = Geometry2D.bounds(rings.filter { $0.pocket == pi }.map(\.pts))
            return (b.min - margin, b.max + margin)
        }
        var selected = [Bool](repeating: false, count: top.count)
        var q = 0
        while q + 1 < top.count {
            var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
            for t in [top[q], top[q + 1]] {
                for v in [t.x, t.y, t.z] {
                    let p = w.vertices[Int(v)]
                    lo = simd_min(lo, SIMD2(p.x, p.y)); hi = simd_max(hi, SIMD2(p.x, p.y))
                }
            }
            if boxes.contains(where: { lo.x <= $0.1.x && hi.x >= $0.0.x && lo.y <= $0.1.y && hi.y >= $0.0.y }) {
                selected[q] = true; selected[q + 1] = true
            }
            q += 2
        }
        var out = top.indices.filter { !selected[$0] }.map { top[$0] }

        // Boundary loops of the replaced region.
        var edges = Set<UInt64>()
        for (i, t) in top.enumerated() where selected[i] {
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] { edges.insert(IndexedMesh.key(a, b)) }
        }
        var nextOf: [Int32: Int32] = [:]
        for (i, t) in top.enumerated() where selected[i] {
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] where !edges.contains(IndexedMesh.key(b, a)) {
                nextOf[a] = b
            }
        }
        var loops: [[Int32]] = []
        var visited = Set<Int32>()
        for start in nextOf.keys.sorted() where !visited.contains(start) {
            var loop: [Int32] = []
            var v = start
            while !visited.contains(v), let n = nextOf[v] {
                visited.insert(v); loop.append(v); v = n
            }
            if loop.count >= 3 { loops.append(loop) }
        }
        func xy(_ v: Int32) -> SIMD2<Double> { let p = w.vertices[Int(v)]; return SIMD2(p.x, p.y) }
        let loopPts = loops.map { $0.map(xy) }
        let loopArea = loopPts.map(Geometry2D.signedArea)
        let outers = loops.indices.filter { loopArea[$0] > 0 }
        func owner(_ p: SIMD2<Double>) -> Int? {
            outers.filter { Geometry2D.contains(loopPts[$0], p) }.min { loopArea[$0] < loopArea[$1] }
        }

        let surface: (Double, Double) -> Double = { L.topZ(x: $0, y: $1) }
        func vertex(_ p: SIMD2<Double>, _ z: (Double, Double) -> Double) -> Int32 {
            w.index(SIMD3(p.x, p.y, z(p.x, p.y)))
        }

        /// Triangulates a face given as an outer loop and holes of 2D points with their vertex ids, then refines it.
        func face(outer: [(SIMD2<Double>, Int32)], holes: [[(SIMD2<Double>, Int32)]], z: @escaping (Double, Double) -> Double) {
            let tri = Geometry2D.triangulate(outer: outer.map(\.0), holes: holes.map { $0.map(\.0) })
            let ids = outer.map(\.1) + holes.flatMap { $0.map(\.1) }
            var t = tri.map { SIMD3(ids[Int($0.x)], ids[Int($0.y)], ids[Int($0.z)]) }
                .filter { $0.x != $0.y && $0.y != $0.z && $0.z != $0.x }
            refine(&t, &w, maxLen: pocketMaxEdge, z: z)
            out += t
        }
        func ringVerts(_ r: [SIMD2<Double>], _ z: (Double, Double) -> Double) -> [(SIMD2<Double>, Int32)] {
            r.map { ($0, vertex($0, z)) }
        }

        // Surface around the pockets.
        for oi in outers {
            let outer = loops[oi].map { (xy($0), $0) }
            var holes = loops.indices.filter { loopArea[$0] < 0 && owner(loopPts[$0][0]) == oi }
                .map { loops[$0].map { (xy($0), $0) } }
            for r in rings where r.depth == 0 && owner(r.pts[0]) == oi {
                holes.append(ringVerts(r.pts.reversed(), surface))
            }
            face(outer: outer, holes: holes, z: surface)
        }
        // Floors (pocket boundaries with their islands as holes) and island tops.
        for (i, r) in rings.enumerated() {
            let pk = pockets[r.pocket]
            let floorFn: (Double, Double) -> Double = { pk.floorZ(L, $0, $1) }
            let children = rings.indices.filter { rings[$0].parent == i }
            if r.depth % 2 == 0 {
                face(outer: ringVerts(r.pts, floorFn), holes: children.map { ringVerts(rings[$0].pts, floorFn) }, z: floorFn)
            } else {
                face(outer: ringVerts(r.pts.reversed(), surface),
                     holes: children.map { ringVerts(rings[$0].pts.reversed(), surface) }, z: surface)
            }
        }
        // Walls: every ring has the pocket on its left.
        for r in rings {
            let pk = pockets[r.pocket]
            let n = r.pts.count
            let tops = r.pts.map { vertex($0, surface) }
            let floors = r.pts.map { p in w.index(SIMD3(p.x, p.y, pk.floorZ(L, p.x, p.y))) }
            for i in 0..<n {
                let j = (i + 1) % n
                out.append(SIMD3(tops[i], tops[j], floors[j]))
                out.append(SIMD3(tops[i], floors[j], floors[i]))
            }
        }
        return out
    }

    /// Splits interior edges longer than `maxLen` (both triangles sharing them), placing the new vertex on `z`.
    /// Edges on the boundary of the triangle set are never split, so neighbours still match.
    static func refine(_ tris: inout [SIMD3<Int32>], _ w: inout Welder, maxLen: Double, z: (Double, Double) -> Double) {
        var skip = Set<UInt64>()
        for _ in 0..<60 {
            var map: [UInt64: Int] = [:]
            for (i, t) in tris.enumerated() {
                for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] { map[IndexedMesh.key(a, b)] = i }
            }
            var cands: [(Double, Int32, Int32)] = []
            for t in tris {
                for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] where a < b && map[IndexedMesh.key(b, a)] != nil && !skip.contains(IndexedMesh.key(a, b)) {
                    let l = simd_distance(w.vertices[Int(a)], w.vertices[Int(b)])
                    if l > maxLen { cands.append((l, a, b)) }
                }
            }
            if cands.isEmpty { return }
            cands.sort { $0.0 > $1.0 }
            var touched = Set<Int>()
            for (_, a, b) in cands {
                guard let ti = map[IndexedMesh.key(a, b)], let tj = map[IndexedMesh.key(b, a)],
                      !touched.contains(ti), !touched.contains(tj) else { continue }
                let c = other(tris[ti], a, b), d = other(tris[tj], a, b)
                let pa = w.vertices[Int(a)], pb = w.vertices[Int(b)]
                let mx = (pa.x + pb.x) / 2, my = (pa.y + pb.y) / 2
                // A midpoint that lands on an existing vertex (a collinear sliver) would weld onto it; leave it.
                let before = w.vertices.count
                let m = w.index(SIMD3(mx, my, z(mx, my)))
                guard Int(m) >= before else { skip.insert(IndexedMesh.key(a, b)); continue }
                touched.insert(ti); touched.insert(tj)
                tris[ti] = SIMD3(a, m, c); tris.append(SIMD3(m, b, c))
                tris[tj] = SIMD3(b, m, d); tris.append(SIMD3(m, a, d))
            }
        }
    }

    private static func other(_ t: SIMD3<Int32>, _ a: Int32, _ b: Int32) -> Int32 {
        for v in [t.x, t.y, t.z] where v != a && v != b { return v }
        return t.x
    }
}
