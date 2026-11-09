import Foundation
import simd

/// Generates the four-stage job: rough surface, rough outline, finish surface, finish outline.
public enum ToolpathGenerator {
    public static func generate(layout L: FretboardLayout, settings s: CNCSettings) -> Toolpath {
        var g = Generator(L: L, s: s)
        g.run()
        return Toolpath(start: SIMD3(0, 0, s.safeZ), moves: g.moves, settings: s)
    }

    // MARK: Outline offset

    /// Tool-centre path around the board outline, offset outward by `d`, counter-clockwise seen from above
    /// (climb milling with a clockwise spindle). The path starts and ends at the middle of the nut end.
    public static func offsetOutline(_ L: FretboardLayout, offset d: Double) -> [SIMD2<Double>] {
        var pts: [SIMD2<Double>] = []
        func add(_ x: Double, _ y: Double) {
            let p = SIMD2(x, y)
            if let l = pts.last, simd_distance(l, p) < 1e-9 { return }
            pts.append(p)
        }
        func arc(_ cx: Double, _ cy: Double, _ rad: Double, _ a0: Double, _ a1: Double) {
            let span = a1 - a0
            let n = max(2, Int(ceil(abs(span) / (4 * Double.pi / 180))))
            for i in 0...n {
                let a = a0 + span * Double(i) / Double(n)
                add(cx + rad * cos(a), cy + rad * sin(a))
            }
        }
        let thN = L.cornerEndAngle
        let xEnd = L.xEnd, hwE = L.taperHalfWidth(at: xEnd)
        let rc = L.cornerRadius, yc = L.cornerCenterY
        let hasNotch = L.params.hasSpokeWheelTrussRod
        let c = L.notchHalfWidth, nd = L.notchDepth, rf = L.notchFillet

        add(xEnd + d, 0)
        arc(xEnd, hwE, d, 0, thN)                          // convex nut-end corner (+y)
        arc(rc, yc, rc + d, thN, Double.pi)                // heel corner (+y)
        if hasNotch {
            add(-d, c)
            arc(0, c, d, Double.pi, 1.5 * Double.pi)       // convex mouth corner
            if rf > d { arc(nd - rf, c - rf, rf - d, Double.pi / 2, 0) } else { add(nd - d, c - d) }
            if rf > d { arc(nd - rf, -(c - rf), rf - d, 0, -Double.pi / 2) } else { add(nd - d, -(c - d)) }
            add(0, -(c - d))
            arc(0, -c, d, Double.pi / 2, Double.pi)        // convex mouth corner
        }
        add(-d, -yc)
        arc(rc, -yc, rc + d, Double.pi, 2 * Double.pi - thN)   // heel corner (-y)
        arc(xEnd, -hwE, d, 2 * Double.pi - thN, 2 * Double.pi) // convex nut-end corner (-y)
        add(xEnd + d, 0)
        return pts
    }

    // MARK: Generator

    struct Generator {
        let L: FretboardLayout
        let s: CNCSettings
        var moves: [Move] = []
        var pos: SIMD3<Double>
        let r: Double
        let T: Double
        /// Sample offsets within the cutter footprint: (dx, dy, distance from centre).
        let samples: [SIMD3<Double>]

        init(L: FretboardLayout, s: CNCSettings) {
            self.L = L; self.s = s
            pos = SIMD3(0, 0, s.safeZ)
            r = s.cutterRadius
            T = s.stockThickness
            var sm: [SIMD3<Double>] = [SIMD3(0, 0, 0)]
            for (ring, n) in [(0.5, 8), (1.0, 16)] {
                for i in 0..<n {
                    let a = 2 * Double.pi * Double(i) / Double(n)
                    sm.append(SIMD3(cos(a) * ring * s.cutterRadius, sin(a) * ring * s.cutterRadius, ring * s.cutterRadius))
                }
            }
            if s.cutter == .ball {
                // The contact point sits close to the centre line of the cutter, towards the board's centre line (±Y),
                // so sample that direction densely as well.
                for f in [0.05, 0.1, 0.15, 0.2, 0.3, 0.45, 0.6, 0.8] {
                    let d = f * s.cutterRadius
                    sm.append(SIMD3(0, d, d)); sm.append(SIMD3(0, -d, d))
                }
            }
            samples = sm
        }

        // MARK: Surface model

        /// Height (model coordinates) of the cutter tip so it touches but never gouges the top surface.
        func tip(_ x: Double, _ y: Double) -> Double {
            var m = -Double.infinity
            for o in samples {
                var z = L.topZ(x: x + o.x, y: y + o.y)
                if s.cutter == .ball { z += (r * r - o.z * o.z).squareRoot() - r }
                m = max(m, z)
            }
            return m
        }

        /// Machine Z (top of stock = 0) for the cutter tip.
        func machineZ(_ x: Double, _ y: Double, allowance: Double) -> Double { tip(x, y) + allowance - T }

        // MARK: Move helpers

        mutating func rapid(_ p: SIMD3<Double>, _ op: CutOperation) {
            moves.append(Move(kind: .rapid, op: op, to: p, feed: s.rapidFeed)); pos = p
        }

        mutating func cut(_ p: SIMD3<Double>, _ op: CutOperation) {
            let d = p - pos
            let xy = (d.x * d.x + d.y * d.y).squareRoot()
            var feed = s.xyFeed
            if abs(d.z) > 1e-9 {
                let len = simd_length(d)
                feed = xy < 1e-9 ? s.zFeed : min(s.xyFeed, s.zFeed * len / abs(d.z))
            }
            moves.append(Move(kind: .cut, op: op, to: p, feed: feed)); pos = p
        }

        mutating func retract(_ op: CutOperation) {
            if pos.z < s.safeZ - 1e-9 { rapid(SIMD3(pos.x, pos.y, s.safeZ), op) }
        }

        /// Rapid to above the start point, rapid down to the approach height, then plunge at Z feed.
        mutating func enter(_ p: SIMD3<Double>, approachZ: Double, _ op: CutOperation) {
            retract(op)
            rapid(SIMD3(p.x, p.y, s.safeZ), op)
            let a = min(s.safeZ, max(approachZ, p.z))
            if a < s.safeZ - 1e-9 { rapid(SIMD3(p.x, p.y, a), op) }
            if p.z < a - 1e-9 { cut(p, op) }
        }

        // MARK: Job

        mutating func run() {
            surfacePass(.roughSurface, allowance: s.roughAllowance, overlap: s.roughOverlap, layered: true)
            outlineRough()
            surfacePass(.finishSurface, allowance: 0, overlap: s.finishOverlap, layered: false)
            outlineFinish()
            retract(.finishOutline)
            rapid(SIMD3(0, 0, s.safeZ), .finishOutline)
        }

        // MARK: Surface passes (raster along Y, stepping along the board length)

        mutating func surfacePass(_ op: CutOperation, allowance: Double, overlap: Double, layered: Bool) {
            let step = s.cutterDiameter * (1 - overlap)
            let x0 = -(r + s.edgeMargin), x1 = L.xEnd + r + s.edgeMargin
            let n = max(1, Int(ceil((x1 - x0) / step)))
            let dy = 0.5

            struct Line { var x: Double; var ys: [Double]; var zt: [Double] }
            var lines: [Line] = []
            for i in 0...n {
                let x = x0 + (x1 - x0) * Double(i) / Double(n)
                let ye = L.taperHalfWidth(at: min(max(x, 0), L.xEnd)) + r + s.edgeMargin
                let m = max(2, Int(ceil(2 * ye / dy)))
                var ys: [Double] = [], zt: [Double] = []
                for j in 0...m {
                    let y = -ye + 2 * ye * Double(j) / Double(m)
                    ys.append(y); zt.append(machineZ(x, y, allowance: allowance))
                }
                lines.append(Line(x: x, ys: ys, zt: zt))
            }
            let minZ = lines.flatMap(\.zt).min() ?? 0
            var levels: [Double]
            if layered {
                let k = max(1, Int(ceil(-minZ / s.roughDepthPerPass - 1e-9)))
                levels = (1...k).map { -Double($0) * s.roughDepthPerPass }
            } else {
                levels = [-Double.infinity]
            }

            var prevLevel = 0.0
            for level in levels {
                var forward = true
                var lastStation = -10
                var linked = false
                for (si, line) in lines.enumerated() {
                    // Range of samples that still has material to remove.
                    let need = line.zt.indices.filter { layered ? line.zt[$0] < prevLevel - 1e-6 : true }
                    guard let i0 = need.first, let i1 = need.last else { continue }
                    var idx = Array(i0...i1)
                    if !forward { idx.reverse() }
                    let raw = idx.map { j in SIMD2(line.ys[j], max(level, line.zt[j])) }
                    let simp = Self.simplify(raw, tol: 0.004)
                    let first = SIMD3(line.x, simp[0].x, simp[0].y)
                    // Stay down and step over when the next line starts at (nearly) the same end of the raster.
                    let adjacent = si == lastStation + 1 && linked
                        && abs(pos.y - first.y) < 1.0 && abs(pos.z - first.z) < 0.5
                    if adjacent {
                        cut(first, op)
                    } else {
                        let top = layered ? max(prevLevel, first.z) : first.z + allowance
                        enter(first, approachZ: top + 1.0, op)
                    }
                    for p in simp.dropFirst() { cut(SIMD3(line.x, p.x, p.y), op) }
                    lastStation = si; linked = true
                    forward.toggle()
                }
                retract(op)
                prevLevel = level
            }
        }

        /// Douglas-Peucker simplification of a (y, z) polyline.
        static func simplify(_ pts: [SIMD2<Double>], tol: Double) -> [SIMD2<Double>] {
            guard pts.count > 2 else { return pts }
            var keep = [Bool](repeating: false, count: pts.count)
            keep[0] = true; keep[pts.count - 1] = true
            var stack = [(0, pts.count - 1)]
            while let (a, b) = stack.popLast() {
                let pa = pts[a], pb = pts[b]
                let ab = pb - pa
                let len = simd_length(ab)
                var worst = 0.0, wi = -1
                if b > a + 1 {
                    for i in (a + 1)..<b {
                        let ap = pts[i] - pa
                        let d = len < 1e-12 ? simd_length(ap) : abs(ab.x * ap.y - ab.y * ap.x) / len
                        if d > worst { worst = d; wi = i }
                    }
                }
                if worst > tol, wi >= 0 {
                    keep[wi] = true
                    stack.append((a, wi)); stack.append((wi, b))
                }
            }
            return pts.indices.filter { keep[$0] }.map { pts[$0] }
        }

        // MARK: Outline passes

        mutating func outlineRough() {
            let d = r + s.roughAllowance
            let path = ToolpathGenerator.offsetOutline(L, offset: d)
            let floorZ = -T + s.outlineFloorAllowance
            let topSurface = path.map { machineZ($0.x, $0.y, allowance: s.roughAllowance) }.max() ?? 0
            var levels: [Double] = []
            var l = min(0, topSurface)
            while l > floorZ + 1e-9 {
                l = max(l - s.roughDepthPerPass, floorZ)
                levels.append(l)
            }
            runOutline(path, levels: levels, op: .roughOutline,
                       surfaceAtStart: machineZ(path[0].x, path[0].y, allowance: s.roughAllowance))
        }

        mutating func outlineFinish() {
            let path = ToolpathGenerator.offsetOutline(L, offset: r)
            runOutline(path, levels: [-T - s.throughCutExtra], op: .finishOutline,
                       surfaceAtStart: machineZ(path[0].x, path[0].y, allowance: 0))
        }

        mutating func runOutline(_ path: [SIMD2<Double>], levels: [Double], op: CutOperation, surfaceAtStart: Double) {
            guard let p0 = path.first, !levels.isEmpty else { return }
            var first = true
            for level in levels {
                let start = SIMD3(p0.x, p0.y, level)
                if first {
                    enter(start, approachZ: surfaceAtStart + 1.0, op)
                    first = false
                } else {
                    cut(start, op)       // step down at the start point, at Z feed
                }
                for p in path.dropFirst() { cut(SIMD3(p.x, p.y, level), op) }
            }
            retract(op)
        }
    }
}
