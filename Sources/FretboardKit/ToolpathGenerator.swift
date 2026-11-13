import Foundation
import simd

/// Generates the four-stage job: rough surface, rough outline, finish surface, finish outline.
public enum ToolpathGenerator {
    public static func generate(layout L: FretboardLayout, settings s: CNCSettings) -> Toolpath {
        var g = Generator(L: L, s: s)
        g.run()
        return Toolpath(start: SIMD3(0, 0, s.safeZ), moves: g.moves, settings: s)
    }

    /// How far outside the final edge the finish outline plunges (mm).
    public static let finishLeadIn = 1.0

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
            if d <= nd {
                arc(0, c, d, Double.pi, 1.5 * Double.pi)   // convex mouth corner
                if rf > d { arc(nd - rf, c - rf, rf - d, Double.pi / 2, 0) } else { add(nd - d, c - d) }
                if rf > d { arc(nd - rf, -(c - rf), rf - d, 0, -Double.pi / 2) } else { add(nd - d, -(c - d)) }
                add(0, -(c - d))
                arc(0, -c, d, Double.pi / 2, Double.pi)    // convex mouth corner
            } else {
                // The offset is deeper than the cutout: the back wall's offset line (x = nd - d) is
                // reached while still going round the mouth corners.
                let a = acos((nd - d) / d)                 // in (π/2, π]
                arc(0, c, d, Double.pi, 2 * Double.pi - a)
                arc(0, -c, d, a, Double.pi)
            }
        }
        add(-d, -yc)
        arc(rc, -yc, rc + d, Double.pi, 2 * Double.pi - thN)   // heel corner (-y)
        arc(xEnd, -hwE, d, 2 * Double.pi - thN, 2 * Double.pi) // convex nut-end corner (-y)
        add(xEnd + d, 0)
        return pts
    }

    /// Arc-length intervals along `path` where the cutter is lifted to leave tabs. Tabs sit on the two straight
    /// long sides. The lift is wider than the tab by the cutter diameter, because the cutter's footprint
    /// reaches half a diameter either side of its centre.
    public static func tabZones(layout L: FretboardLayout, path: [SIMD2<Double>], settings s: CNCSettings) -> [(Double, Double)] {
        guard s.tabCount > 0, path.count > 1 else { return [] }
        var cum = [0.0]
        for i in 1..<path.count { cum.append(cum[i - 1] + simd_distance(path[i], path[i - 1])) }
        var zones: [(Double, Double)] = []
        let half = (s.tabWidth + s.cutterDiameter) / 2
        for sign in [1.0, -1.0] {
            let k = s.tabCount / 2 + (sign > 0 ? s.tabCount % 2 : 0)
            for i in 0..<k {
                let xc = L.xEnd * (Double(i) + 0.5) / Double(k)
                for j in 1..<path.count {
                    let a = path[j - 1], b = path[j]
                    guard (a.x - xc) * (b.x - xc) <= 0, a.x != b.x, a.y * sign > 5, b.y * sign > 5 else { continue }
                    let t = (xc - a.x) / (b.x - a.x)
                    let sc = cum[j - 1] + t * (cum[j] - cum[j - 1])
                    zones.append((sc - half, sc + half))
                    break
                }
            }
        }
        return zones.sorted { $0.0 < $1.0 }
    }

    // MARK: Generator

    struct Generator {
        let L: FretboardLayout
        let s: CNCSettings
        var moves: [Move] = []
        var pos: SIMD3<Double>
        let r: Double
        let T: Double
        /// Sample offsets within the cutter footprint (centre, then two rings).
        let samples: [SIMD2<Double>]

        init(L: FretboardLayout, s: CNCSettings) {
            self.L = L; self.s = s
            pos = SIMD3(0, 0, s.safeZ)
            r = s.cutterRadius
            T = s.stockThickness
            var sm: [SIMD2<Double>] = [SIMD2(0, 0)]
            for (ring, n) in [(0.5, 8), (1.0, 16)] {
                for i in 0..<n {
                    let a = 2 * Double.pi * Double(i) / Double(n)
                    sm.append(SIMD2(cos(a) * ring * s.cutterRadius, sin(a) * ring * s.cutterRadius))
                }
            }
            samples = sm
        }

        // MARK: Surface model

        /// Height (model coordinates) of the cutter's flat bottom so it touches but never gouges the top surface.
        func tip(_ x: Double, _ y: Double) -> Double {
            var m = -Double.infinity
            for o in samples { m = max(m, L.topZ(x: x + o.x, y: y + o.y)) }
            return m
        }

        /// Machine Z (top of stock = 0) for the cutter bottom.
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
            // How far the cutter centre must travel beyond the board edge:
            // roughing covers the whole outline trench, finishing only has to clear the board edge.
            let roughReach = s.roughAllowance + s.trenchWidth - r + s.edgeMargin
            let finishReach = r + s.edgeMargin
            surfacePass(.roughSurface, allowance: s.roughAllowance, overlap: s.roughOverlap, layered: true,
                        reach: roughReach, dy: 0.5, tol: 0.004)
            outlineRough()
            surfacePass(.finishSurface, allowance: 0, overlap: s.finishOverlap, layered: false,
                        reach: finishReach, dy: 0.25, tol: 0.002)
            outlineFinish()
            retract(.finishOutline)
            rapid(SIMD3(0, 0, s.safeZ), .finishOutline)
        }

        // MARK: Surface passes (raster along Y, stepping along the board length)

        mutating func surfacePass(_ op: CutOperation, allowance: Double, overlap: Double, layered: Bool,
                                  reach: Double, dy: Double, tol: Double) {
            let step = s.cutterDiameter * (1 - overlap)
            // Cutter centres stay on the blank; lines that reach its edge start and end just outside it,
            // so the cutter enters and leaves in air rather than plunging into the blank.
            let x0 = max(-reach, s.stockMinX), x1 = min(L.xEnd + reach, s.stockMaxX)
            let n = max(1, Int(ceil((x1 - x0) / step)))

            struct Line { var x: Double; var ys: [Double]; var zt: [Double] }
            var lines: [Line] = []
            for i in 0...n {
                let x = x0 + (x1 - x0) * Double(i) / Double(n)
                let ye = L.taperHalfWidth(at: min(max(x, 0), L.xEnd)) + reach
                let yEnd = ye >= s.stockHalfWidth ? s.stockHalfWidth + r + 1 : ye
                let m = max(2, Int(ceil(2 * yEnd / dy)))
                var ys: [Double] = [], zt: [Double] = []
                for j in 0...m {
                    let y = -yEnd + 2 * yEnd * Double(j) / Double(m)
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
                    let simp = Self.simplify(raw, tol: tol)
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

        /// Closed loop in the requested direction (counter-clockwise = climb with a clockwise spindle).
        func loop(offset d: Double) -> [SIMD2<Double>] {
            let p = ToolpathGenerator.offsetOutline(L, offset: d)
            return s.climbOutline ? p : Array(p.reversed())
        }

        /// Rough the trench around the board: on each depth layer the outermost loop is cut first and the loop
        /// beside the board last, so the board's edge is left by the lightest cut.
        mutating func outlineRough() {
            let loops = s.trenchLoopOffsets.map { loop(offset: $0) }
            guard let outer = loops.first?.first else { return }
            let floorZ = -T + s.outlineFloorAllowance
            let topSurface = loops.flatMap { $0 }.map { machineZ($0.x, $0.y, allowance: s.roughAllowance) }.max() ?? 0
            var levels: [Double] = []
            var l = min(0, topSurface)
            while l > floorZ + 1e-9 {
                l = max(l - s.roughDepthPerPass, floorZ)
                levels.append(l)
            }
            guard !levels.isEmpty else { return }
            let op = CutOperation.roughOutline
            var prevLevel: Double?
            for level in levels {
                let start = SIMD3(outer.x, outer.y, level)
                if let pl = prevLevel {
                    cut(SIMD3(outer.x, outer.y, pl), op)                // stay down, move back out to the outer loop
                    cut(start, op)                                      // step down at Z feed
                } else {
                    enter(start, approachZ: machineZ(outer.x, outer.y, allowance: s.roughAllowance) + 1.0, op)
                }
                for (li, path) in loops.enumerated() {
                    if li > 0 { cut(SIMD3(path[0].x, path[0].y, level), op) }   // step in to the next loop
                    for p in path.dropFirst() { cut(SIMD3(p.x, p.y, level), op) }
                }
                prevLevel = level
            }
            retract(op)
        }

        /// Full-depth cut round the board, leaving tabs. The cutter plunges 1 mm clear of the board and eases in to
        /// the final offset along the straight nut end, so the plunge never marks the finished edge.
        mutating func outlineFinish() {
            let path = loop(offset: r - s.outlineTrim)
            guard path.count > 1 else { return }
            let p0 = path[0]
            let op = CutOperation.finishOutline
            let level = -T - s.throughCutExtra
            let tabZ = -T + s.tabHeight
            let zones = ToolpathGenerator.tabZones(layout: L, path: path, settings: s)

            // Lead-in along the first (straight) segment, from 1 mm out to the final offset.
            let seg = simd_distance(p0, path[1])
            let straight = abs(path[1].x - p0.x) < 1e-6 && seg > 2
            let leadLen = straight ? min(8.0, seg * 0.8) : 0
            let q = straight ? p0 + simd_normalize(path[1] - p0) * leadLen : p0
            let start = straight ? SIMD2(p0.x + ToolpathGenerator.finishLeadIn, p0.y) : p0
            enter(SIMD3(start.x, start.y, level), approachZ: machineZ(start.x, start.y, allowance: 0) + 1.0, op)
            if straight { cut(SIMD3(q.x, q.y, level), op) }

            var cum = [0.0]
            for i in 1..<path.count { cum.append(cum[i - 1] + simd_distance(path[i], path[i - 1])) }
            let events = zones.flatMap { [$0.0, $0.1] }.sorted()
            for _ in 0..<(s.outlineSpringPass ? 2 : 1) {
                var ei = 0
                var z = level
                for i in 1..<path.count {
                    let a = (i == 1 && straight) ? q : path[i - 1], b = path[i]
                    let sa = (i == 1 && straight) ? leadLen : cum[i - 1], sb = cum[i]
                    while ei < events.count, events[ei] <= sb + 1e-9 {
                        let e = max(events[ei], sa)
                        let t = sb > sa ? (e - sa) / (sb - sa) : 1
                        let p = a + (b - a) * t
                        cut(SIMD3(p.x, p.y, z), op)
                        z = (z == level) ? tabZ : level                      // lift over the tab / drop after it
                        cut(SIMD3(p.x, p.y, z), op)
                        ei += 1
                    }
                    if simd_distance(SIMD2(pos.x, pos.y), b) > 1e-9 || abs(pos.z - z) > 1e-9 { cut(SIMD3(b.x, b.y, z), op) }
                }
                if straight { cut(SIMD3(q.x, q.y, z), op) }                  // run past the start to clean the lead-in wedge
            }
            retract(op)
        }
    }
}
