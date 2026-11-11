import Foundation
import simd

/// A scalar field on a regular grid. Cell (i, j) sits at `origin + (i, j) * cell`.
public struct Grid2D: Sendable {
    public var w: Int
    public var h: Int
    public var values: [Float]
    public var origin: SIMD2<Double>
    public var cell: Double

    public init(w: Int, h: Int, fill: Float = 0, origin: SIMD2<Double> = .zero, cell: Double = 1) {
        self.w = w; self.h = h; values = [Float](repeating: fill, count: w * h); self.origin = origin; self.cell = cell
    }

    @inline(__always) public subscript(i: Int, j: Int) -> Float {
        get { values[j * w + i] }
        set { values[j * w + i] = newValue }
    }

    public func point(_ i: Double, _ j: Double) -> SIMD2<Double> { origin + SIMD2(i, j) * cell }

    /// Bilinear sample at a world position (outside the grid counts as 0).
    public func sample(_ p: SIMD2<Double>) -> Float {
        let g = (p - origin) / cell
        let i = Int(floor(g.x)), j = Int(floor(g.y))
        guard i >= 0, j >= 0, i + 1 < w, j + 1 < h else { return 0 }
        let fx = Float(g.x - Double(i)), fy = Float(g.y - Double(j))
        let a = self[i, j] * (1 - fx) + self[i + 1, j] * fx
        let b = self[i, j + 1] * (1 - fx) + self[i + 1, j + 1] * fx
        return a * (1 - fy) + b * fy
    }
}

public enum Raster {
    /// Closed iso-lines where the field crosses `level` (inside = above the level), in world coordinates.
    /// Saddles are resolved with the cell centre. The field should be below the level along its border.
    public static func contours(_ f: Grid2D, level: Float) -> [[SIMD2<Double>]] {
        let w = f.w, h = f.h
        guard w > 1, h > 1 else { return [] }
        // Edge keys: horizontal edge (i,j)-(i+1,j) = 2*(j*w+i); vertical edge (i,j)-(i,j+1) = 2*(j*w+i)+1.
        var pos: [Int: SIMD2<Double>] = [:]
        var adj: [Int: [Int]] = [:]
        func edgePoint(_ key: Int) -> SIMD2<Double> {
            if let p = pos[key] { return p }
            let base = key / 2, i = base % w, j = base / w
            let (i2, j2) = key % 2 == 0 ? (i + 1, j) : (i, j + 1)
            let a = f[i, j], b = f[i2, j2]
            let t = Double(a == b ? 0.5 : (level - a) / (b - a))
            let p = f.point(Double(i) + Double(i2 - i) * t, Double(j) + Double(j2 - j) * t)
            pos[key] = p
            return p
        }
        func link(_ a: Int, _ b: Int) {
            _ = edgePoint(a); _ = edgePoint(b)
            adj[a, default: []].append(b); adj[b, default: []].append(a)
        }
        for j in 0..<(h - 1) {
            for i in 0..<(w - 1) {
                let v0 = f[i, j], v1 = f[i + 1, j], v2 = f[i + 1, j + 1], v3 = f[i, j + 1]
                let b0 = v0 > level, b1 = v1 > level, b2 = v2 > level, b3 = v3 > level
                let idx = (b0 ? 1 : 0) | (b1 ? 2 : 0) | (b2 ? 4 : 0) | (b3 ? 8 : 0)
                if idx == 0 || idx == 15 { continue }
                let e0 = 2 * (j * w + i), e1 = 2 * (j * w + i + 1) + 1, e2 = 2 * ((j + 1) * w + i), e3 = 2 * (j * w + i) + 1
                if idx == 5 || idx == 10 {
                    let centre = (v0 + v1 + v2 + v3) / 4 > level
                    if (idx == 5) == centre { link(e0, e1); link(e2, e3) } else { link(e0, e3); link(e1, e2) }
                    continue
                }
                var crossed: [Int] = []
                if b0 != b1 { crossed.append(e0) }
                if b1 != b2 { crossed.append(e1) }
                if b3 != b2 { crossed.append(e2) }
                if b0 != b3 { crossed.append(e3) }
                if crossed.count == 2 { link(crossed[0], crossed[1]) }
            }
        }
        var used = Set<Int>()
        var loops: [[SIMD2<Double>]] = []
        for start in adj.keys.sorted() where !used.contains(start) {
            var loop: [SIMD2<Double>] = []
            var prev = -1, cur = start
            while !used.contains(cur) {
                used.insert(cur)
                loop.append(pos[cur]!)
                guard let nb = adj[cur] else { break }
                let nxt = nb.first { $0 != prev && !used.contains($0) } ?? nb.first { $0 != prev } ?? -1
                if nxt < 0 { break }
                prev = cur; cur = nxt
            }
            if loop.count >= 3 { loops.append(loop) }
        }
        return loops
    }

    /// Fills the even-odd interior of `rings` (world coordinates) on a grid covering their bounds plus `pad` cells.
    public static func rasterize(_ rings: [[SIMD2<Double>]], cell: Double, pad: Int = 3) -> Grid2D {
        let b = Geometry2D.bounds(rings)
        let origin = b.min - Double(pad) * cell
        let w = Int(ceil((b.max.x - b.min.x) / cell)) + 2 * pad + 1
        let h = Int(ceil((b.max.y - b.min.y) / cell)) + 2 * pad + 1
        var g = Grid2D(w: w, h: h, origin: origin, cell: cell)
        var xs: [Double] = []
        for j in 0..<h {
            let y = origin.y + Double(j) * cell
            xs.removeAll(keepingCapacity: true)
            for r in rings {
                var k = r.count - 1
                for i in 0..<r.count {
                    let a = r[i], c = r[k]
                    if (a.y > y) != (c.y > y) { xs.append(a.x + (y - a.y) / (c.y - a.y) * (c.x - a.x)) }
                    k = i
                }
            }
            xs.sort()
            var n = 0
            while n + 1 < xs.count {
                let i0 = max(0, Int(ceil((xs[n] - origin.x) / cell))), i1 = min(w - 1, Int(floor((xs[n + 1] - origin.x) / cell)))
                if i0 <= i1 { for i in i0...i1 { g[i, j] = 1 } }
                n += 2
            }
        }
        return g
    }

    /// Euclidean distance (world units) from every cell with value > 0.5 to the nearest cell ≤ 0.5. Outside cells get 0.
    /// The boundary lies half a cell beyond the last inside cell, so half a cell is taken off (conservative).
    /// Outline of what a cutter of radius `r` actually removes from the even-odd region `rings`: every point
    /// within r of a place where the whole cutter fits. Narrow parts (sharp tips, thin strokes) drop out.
    /// Traced on the smooth "distance to the nearest cutter centre" field, so the outline is smooth too.
    public static func cutRegion(_ rings: [[SIMD2<Double>]], radius r: Double, cell h: Double) -> [[SIMD2<Double>]] {
        guard r > 0, !rings.isEmpty else { return rings }
        let mask = rasterize(rings, cell: h, pad: Int(ceil(r / h)) + 4)
        let dist = distanceInside(mask)
        guard dist.values.contains(where: { Double($0) >= r - 1e-9 }) else { return [] }
        var reach = edt(dist) { Double($0) >= r - 1e-9 }
        for k in 0..<reach.values.count { reach.values[k] = Float(r) - reach.values[k] }   // inside = above 0
        return contours(reach, level: 0)
            .map { Geometry2D.simplify(ring: $0, tol: max(0.004, h / 4)) }
            .filter { $0.count >= 3 && abs(Geometry2D.signedArea($0)) > h * h }
    }

    public static func distanceInside(_ mask: Grid2D) -> Grid2D {
        var d = edt(mask) { $0 <= 0.5 }
        let half = Float(mask.cell / 2)
        for k in d.values.indices where d.values[k] > 0 { d.values[k] = max(0, d.values[k] - half) }
        return d
    }

    /// Euclidean distance (world units) from every cell to the nearest cell where `isFeature` holds.
    public static func edt(_ g: Grid2D, isFeature: (Float) -> Bool) -> Grid2D {
        let w = g.w, h = g.h
        let inf = 1e20
        var d = [Double](repeating: 0, count: w * h)
        for k in 0..<(w * h) { d[k] = isFeature(g.values[k]) ? 0 : inf }
        var f = [Double](repeating: 0, count: max(w, h))
        var out = [Double](repeating: 0, count: max(w, h))
        var v = [Int](repeating: 0, count: max(w, h))
        var z = [Double](repeating: 0, count: max(w, h) + 1)
        func pass(_ n: Int) {
            // Felzenszwalb & Huttenlocher 1D squared distance transform of f[0..<n] into out.
            var k = 0
            v[0] = 0; z[0] = -inf; z[1] = inf
            if n > 1 {
                for q in 1..<n {
                    var s: Double
                    repeat {
                        let p = v[k]
                        s = ((f[q] + Double(q * q)) - (f[p] + Double(p * p))) / Double(2 * q - 2 * p)
                        if s <= z[k] { k -= 1 } else { break }
                    } while k >= 0
                    k += 1
                    v[k] = q; z[k] = s; z[k + 1] = inf
                }
            }
            k = 0
            for q in 0..<n {
                while z[k + 1] < Double(q) { k += 1 }
                let p = v[k]
                out[q] = Double((q - p) * (q - p)) + f[p]
            }
        }
        for j in 0..<h {
            for i in 0..<w { f[i] = d[j * w + i] }
            pass(w)
            for i in 0..<w { d[j * w + i] = out[i] }
        }
        for i in 0..<w {
            for j in 0..<h { f[j] = d[j * w + i] }
            pass(h)
            for j in 0..<h { d[j * w + i] = out[j] }
        }
        var r = g
        for k in 0..<(w * h) { r.values[k] = Float(d[k].squareRoot() * g.cell) }
        return r
    }

    /// Labels 4-connected regions of cells > 0.5 (0 = background, 1... = region).
    public static func label(_ g: Grid2D) -> [Int32] {
        var lab = [Int32](repeating: 0, count: g.w * g.h)
        var next: Int32 = 0
        var stack: [Int] = []
        for s in 0..<(g.w * g.h) where g.values[s] > 0.5 && lab[s] == 0 {
            next += 1
            lab[s] = next; stack.append(s)
            while let k = stack.popLast() {
                let i = k % g.w, j = k / g.w
                for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let a = i + di, b = j + dj
                    guard a >= 0, b >= 0, a < g.w, b < g.h else { continue }
                    let n = b * g.w + a
                    if g.values[n] > 0.5 && lab[n] == 0 { lab[n] = next; stack.append(n) }
                }
            }
        }
        return lab
    }
}

/// Turns a grayscale image into inlay artwork.
public enum InlayTracer {
    public struct Options: Sendable, Equatable, Codable {
        /// 0...1: pixels darker than this are part of the inlay (lighter ones with `invert`).
        public var threshold = 0.5
        public var invert = false
        /// Box blur radius in pixels before tracing; smooths jagged edges.
        public var smoothing = 1
        /// Shapes smaller than this fraction of the artwork's bounding box are dropped as specks.
        public var minAreaFraction = 0.0005
        public init() {}
    }

    /// `gray` is row-major from the top-left, 0 = black, 255 = white.
    public static func trace(gray: [UInt8], width w: Int, height h: Int, options o: Options) -> InlayArtwork? {
        guard w > 2, h > 2, gray.count >= w * h else { return nil }
        let pad = 2 + o.smoothing
        var g = Grid2D(w: w + 2 * pad, h: h + 2 * pad)
        for j in 0..<h {
            for i in 0..<w {
                let v = Float(gray[j * w + i]) / 255
                g[i + pad, j + pad] = o.invert ? v : 1 - v
            }
        }
        if o.smoothing > 0 { g = boxBlur(boxBlur(g, o.smoothing), o.smoothing) }
        var loops = Raster.contours(g, level: Float(1 - o.threshold))
        loops = loops.map { Geometry2D.simplify(ring: $0, tol: 0.3) }.filter { $0.count >= 3 }
        guard !loops.isEmpty else { return nil }
        let b0 = Geometry2D.bounds(loops)
        let boxArea = max(1, (b0.max.x - b0.min.x) * (b0.max.y - b0.min.y))
        loops = loops.filter { abs(Geometry2D.signedArea($0)) >= o.minAreaFraction * boxArea }
        guard !loops.isEmpty else { return nil }
        let b = Geometry2D.bounds(loops)
        let bw = max(1e-9, b.max.x - b.min.x), bh = max(1e-9, b.max.y - b.min.y)
        let c = (b.min + b.max) / 2
        let rings = loops.map { $0.map { SIMD2(($0.x - c.x) / bw, -($0.y - c.y) / bh) } }
        return InlayArtwork(rings: rings, aspect: bw / bh)
    }

    static func boxBlur(_ g: Grid2D, _ r: Int) -> Grid2D {
        var a = g, b = g
        let n = Float(2 * r + 1)
        for j in 0..<g.h {
            var s: Float = 0
            for i in -r...r { s += g[min(max(i, 0), g.w - 1), j] }
            for i in 0..<g.w {
                a[i, j] = s / n
                s += g[min(i + r + 1, g.w - 1), j] - g[max(i - r, 0), j]
            }
        }
        for i in 0..<g.w {
            var s: Float = 0
            for j in -r...r { s += a[i, min(max(j, 0), g.h - 1)] }
            for j in 0..<g.h {
                b[i, j] = s / n
                s += a[i, min(j + r + 1, g.h - 1)] - a[i, max(j - r, 0)]
            }
        }
        return b
    }
}
