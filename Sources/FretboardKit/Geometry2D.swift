import Foundation
import simd

/// Small 2D polygon toolkit used for pockets: orientation, containment, nesting, simplification,
/// densification and triangulation of polygons with holes.
public enum Geometry2D {
    public typealias P = SIMD2<Double>

    @inline(__always) static func cross(_ o: P, _ a: P, _ b: P) -> Double {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    /// Signed area (positive = counter-clockwise).
    public static func signedArea(_ r: [P]) -> Double {
        guard r.count > 2 else { return 0 }
        var a = 0.0
        for i in 0..<r.count {
            let p = r[i], q = r[(i + 1) % r.count]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }

    /// Even-odd point in polygon.
    public static func contains(_ r: [P], _ p: P) -> Bool {
        var inside = false
        var j = r.count - 1
        for i in 0..<r.count {
            let a = r[i], b = r[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Even-odd containment against a set of rings.
    public static func contains(rings: [[P]], _ p: P) -> Bool {
        var inside = false
        for r in rings where contains(r, p) { inside.toggle() }
        return inside
    }

    /// Distance from `p` to the segment a-b.
    public static func segmentDistance(_ p: P, _ a: P, _ b: P) -> Double {
        let ab = b - a
        let l2 = simd_length_squared(ab)
        let t = l2 > 0 ? min(1, max(0, simd_dot(p - a, ab) / l2)) : 0
        return simd_distance(p, a + ab * t)
    }

    /// Shortest distance from `p` to any edge of the closed ring.
    public static func ringDistance(_ r: [P], _ p: P) -> Double {
        var d = Double.infinity
        for i in 0..<r.count { d = min(d, segmentDistance(p, r[i], r[(i + 1) % r.count])) }
        return d
    }

    public static func bounds(_ rings: [[P]]) -> (min: P, max: P) {
        var lo = P(repeating: .infinity), hi = P(repeating: -.infinity)
        for r in rings { for p in r { lo = simd_min(lo, p); hi = simd_max(hi, p) } }
        return (lo, hi)
    }

    /// Nesting depth of every ring (0 = not inside any other ring). Rings must not cross.
    public static func nestingDepths(_ rings: [[P]]) -> [Int] {
        rings.indices.map { i in
            guard let p = rings[i].first else { return 0 }
            return rings.indices.filter { $0 != i && contains(rings[$0], p) }.count
        }
    }

    /// Index of the smallest ring that contains ring `i`, or nil.
    public static func parents(_ rings: [[P]]) -> [Int?] {
        let areas = rings.map { abs(signedArea($0)) }
        return rings.indices.map { i in
            guard let p = rings[i].first else { return nil }
            var best: Int?
            for j in rings.indices where j != i && areas[j] > areas[i] && contains(rings[j], p) {
                if best == nil || areas[j] < areas[best!] { best = j }
            }
            return best
        }
    }

    /// Douglas-Peucker simplification of a closed ring.
    public static func simplify(ring r: [P], tol: Double) -> [P] {
        guard r.count > 4 else { return r }
        // Split at the two points farthest apart so both halves are open polylines.
        var far = 0, best = -1.0
        for i in 1..<r.count { let d = simd_distance_squared(r[0], r[i]); if d > best { best = d; far = i } }
        let a = simplifyOpen(Array(r[0...far]), tol: tol)
        let b = simplifyOpen(Array(r[far...]) + [r[0]], tol: tol)
        let out = Array(a.dropLast()) + Array(b.dropLast())
        return out.count >= 3 ? out : r
    }

    static func simplifyOpen(_ pts: [P], tol: Double) -> [P] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var worst = 0.0, wi = -1
            for i in (a + 1)..<b {
                let d = segmentDistance(pts[i], pts[a], pts[b])
                if d > worst { worst = d; wi = i }
            }
            if worst > tol, wi >= 0 {
                keep[wi] = true
                stack.append((a, wi)); stack.append((wi, b))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    /// Inserts points so no edge of the closed ring is longer than `maxLen`, and drops near-duplicates.
    public static func densify(ring r: [P], maxLen: Double) -> [P] {
        var out: [P] = []
        for i in 0..<r.count {
            let a = r[i], b = r[(i + 1) % r.count]
            if let l = out.last, simd_distance(l, a) < 1e-4 { } else { out.append(a) }
            let n = Int(ceil(simd_distance(a, b) / maxLen))
            if n > 1 { for k in 1..<n { out.append(a + (b - a) * (Double(k) / Double(n))) } }
        }
        while out.count > 3, let f = out.first, let l = out.last, simd_distance(f, l) < 1e-4 { out.removeLast() }
        return out
    }

    public static func circle(center c: P, radius r: Double, segments n: Int) -> [P] {
        (0..<n).map { i in
            let a = 2 * Double.pi * Double(i) / Double(n)
            return c + P(cos(a), sin(a)) * r
        }
    }

    // MARK: Triangulation

    /// Ear-clipping triangulation of a polygon with holes. `outer` must be counter-clockwise and the holes
    /// clockwise. Returns index triples into `outer + holes.joined()`, counter-clockwise.
    public static func triangulate(outer: [P], holes: [[P]]) -> [SIMD3<Int32>] {
        var pts = outer
        var poly = Array(0..<outer.count)
        var holeStarts: [(start: Int, count: Int)] = []
        for h in holes {
            holeStarts.append((pts.count, h.count))
            pts += h
        }
        // Merge holes into the outer boundary, rightmost hole first (Eberly, "Triangulation by Ear Clipping").
        let order = holeStarts.indices.sorted { a, b in
            let ma = (0..<holeStarts[a].count).map { pts[holeStarts[a].start + $0].x }.max() ?? 0
            let mb = (0..<holeStarts[b].count).map { pts[holeStarts[b].start + $0].x }.max() ?? 0
            return ma > mb
        }
        for hi in order {
            let (s, n) = holeStarts[hi]
            guard n >= 3 else { continue }
            var mi = s
            for k in s..<(s + n) where pts[k].x > pts[mi].x { mi = k }
            guard let bridge = bridgeVertex(pts: pts, poly: poly, m: pts[mi]) else { continue }
            let holeLoop = (0...n).map { s + ((mi - s + $0) % n) }      // M ... back to M
            poly.insert(contentsOf: holeLoop + [poly[bridge]], at: bridge + 1)
        }
        return earClip(pts: pts, poly: poly)
    }

    /// Position in `poly` of a vertex visible from `m` along the +x ray.
    static func bridgeVertex(pts: [P], poly: [Int], m: P) -> Int? {
        var bestX = Double.infinity, edge = -1
        for i in 0..<poly.count {
            let a = pts[poly[i]], b = pts[poly[(i + 1) % poly.count]]
            guard (a.y - m.y) * (b.y - m.y) <= 0, a.y != b.y || a.y == m.y else { continue }
            let x = a.y == b.y ? min(a.x, b.x) : a.x + (m.y - a.y) / (b.y - a.y) * (b.x - a.x)
            if x >= m.x - 1e-12 && x < bestX { bestX = x; edge = i }
        }
        guard edge >= 0 else { return nil }
        let ia = edge, ib = (edge + 1) % poly.count
        let a = pts[poly[ia]], b = pts[poly[ib]]
        let I = P(bestX, m.y)
        if simd_distance(I, a) < 1e-12 { return ia }
        if simd_distance(I, b) < 1e-12 { return ib }
        var cand = a.x > b.x ? ia : ib
        let P0 = pts[poly[cand]]
        // Any reflex vertex inside triangle (M, I, P0) blocks visibility; pick the one with the smallest angle.
        var bestAngle = Double.infinity, bestDist = Double.infinity
        var found = false
        for i in 0..<poly.count {
            let v = pts[poly[i]]
            guard i != cand, v.x >= m.x - 1e-12 else { continue }
            let prev = pts[poly[(i - 1 + poly.count) % poly.count]], next = pts[poly[(i + 1) % poly.count]]
            guard cross(prev, v, next) <= 0 else { continue }                 // reflex in a CCW polygon
            guard pointInTriangle(v, m, I, P0) || pointInTriangle(v, m, P0, I) else { continue }
            let d = v - m
            let ang = abs(atan2(d.y, d.x)), dist = simd_length(d)
            if ang < bestAngle - 1e-12 || (abs(ang - bestAngle) <= 1e-12 && dist < bestDist) {
                bestAngle = ang; bestDist = dist; cand = i; found = true
            }
        }
        _ = found
        return cand
    }

    static func pointInTriangle(_ p: P, _ a: P, _ b: P, _ c: P) -> Bool {
        let d1 = cross(a, b, p), d2 = cross(b, c, p), d3 = cross(c, a, p)
        return d1 >= -1e-12 && d2 >= -1e-12 && d3 >= -1e-12
    }

    static func earClip(pts: [P], poly: [Int]) -> [SIMD3<Int32>] {
        var n = poly.count
        guard n >= 3 else { return [] }
        var prev = (0..<n).map { ($0 - 1 + n) % n }
        var next = (0..<n).map { ($0 + 1) % n }
        var alive = [Bool](repeating: true, count: n)
        var out: [SIMD3<Int32>] = []
        out.reserveCapacity(n)

        func isEar(_ i: Int, strict: Bool) -> Bool {
            let ia = prev[i], ic = next[i]
            let a = pts[poly[ia]], b = pts[poly[i]], c = pts[poly[ic]]
            let cr = cross(a, b, c)
            if strict ? cr <= 1e-14 : cr < -1e-14 { return false }
            var j = next[ic]
            while j != ia {
                let p = pts[poly[j]]
                // Ignore duplicates of the triangle's own corners (bridge seams).
                if simd_distance_squared(p, a) > 1e-20 && simd_distance_squared(p, b) > 1e-20
                    && simd_distance_squared(p, c) > 1e-20 && pointInTriangle(p, a, b, c) {
                    // Only reflex (or flat) vertices can lie inside an ear.
                    let pp = pts[poly[prev[j]]], pn = pts[poly[next[j]]]
                    if cross(pp, p, pn) <= 1e-14 { return false }
                }
                j = next[j]
            }
            return true
        }

        var i = 0
        var stall = 0
        while n > 3 {
            if isEar(i, strict: true) || (stall >= n && isEar(i, strict: false)) || stall >= 2 * n {
                out.append(SIMD3(Int32(poly[prev[i]]), Int32(poly[i]), Int32(poly[next[i]])))
                let p = prev[i], q = next[i]
                next[p] = q; prev[q] = p
                alive[i] = false
                n -= 1
                i = q
                stall = 0
            } else {
                i = next[i]
                stall += 1
            }
        }
        _ = alive
        out.append(SIMD3(Int32(poly[prev[i]]), Int32(poly[i]), Int32(poly[next[i]])))
        return out
    }
}
