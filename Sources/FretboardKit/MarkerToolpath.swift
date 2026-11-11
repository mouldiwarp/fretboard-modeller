import Foundation
import simd

/// Cutting settings for the dot pockets (normally the same 6 mm cutter as the main job).
public struct DotCutSettings: Equatable, Sendable, Codable {
    public var cutterDiameter = 6.0
    /// Each peck goes this much deeper before the cutter lifts to clear chips.
    public var peckDepth = 1.0
    public var plungeFeed = 300.0
    public var xyFeed = 600.0
    /// Stepover (fraction of the cutter diameter) when a dot is larger than the cutter.
    public var stepover = 0.4
    public var spindleRPM = 0
    public var safeZ = 5.0
    public init() {}
}

public enum InlayOrigin: Int, CaseIterable, Sendable, Identifiable, Codable {
    /// Same origin as the board job: X0 heel edge, Y0 centre line, Z0 top of the original stock.
    case board
    /// X0/Y0 at the centre of the inlay, Z0 on the board surface at that point.
    case inlayCentre
    public var id: Int { rawValue }
    public var title: String { self == .board ? "Board origin" : "Inlay centre" }
}

/// Cutting settings for the custom inlay pocket with a small, fragile cutter.
public struct InlayCutSettings: Equatable, Sendable, Codable {
    public var cutterDiameter = 0.9
    public var fluteLength = 9.0
    public var depthPerLayer = 0.3
    /// Fraction of the cutter diameter.
    public var stepover = 0.35
    public var xyFeed = 300.0
    public var plungeFeed = 150.0
    /// Ramp entry angle in degrees (the cutter never plunges straight into uncut wood).
    public var rampAngle = 2.0
    /// Left on the walls by the clearing loops and removed by a light finishing loop on each layer.
    public var wallAllowance = 0.05
    /// Feed multiplier on the first loop after each entry, where the cutter is in a full-width slot.
    public var slotFeedFactor = 0.6
    /// Climb milling (with a clockwise spindle) or conventional.
    public var climb = true
    public var origin: InlayOrigin = .board
    /// Raster cell used to plan the pocket. Smaller is more accurate and slower.
    public var resolution = 0.025
    public var spindleRPM = 0
    public var safeZ = 5.0
    public init() {}
}

/// A generated marker job: the toolpath plus everything needed to write and show it.
public struct MarkerJob: Sendable {
    public var toolpath: Toolpath
    public var header: [String]
    public var warnings: [String]
    /// Model X/Y of the job's X0/Y0.
    public var originOffset: SIMD2<Double>
    /// Added to the job's coordinates to get the board job's machine coordinates (for showing it on the board).
    public var displayShift: SIMD3<Double> = .zero
    /// Areas the cutter cannot reach (model coordinates), and their total area in mm².
    public var uncut: [[SIMD2<Double>]] = []
    public var uncutArea = 0.0
    public var pocketArea = 0.0

    public var gcode: String { GCodeWriter.write(toolpath, header: header) }

    /// The toolpath moved into the board job's machine coordinates.
    public var displayToolpath: Toolpath {
        guard displayShift != .zero else { return toolpath }
        var t = toolpath
        t.start += displayShift
        for i in t.moves.indices { t.moves[i].to += displayShift }
        return t
    }
}

public enum MarkerToolpath {
    // MARK: Motion

    struct Mover {
        var moves: [Move] = []
        var pos: SIMD3<Double>
        let rapidFeed: Double
        let zFeed: Double
        let safeZ: Double

        mutating func rapid(_ p: SIMD3<Double>, _ op: CutOperation) {
            if simd_distance(p, pos) < 1e-9 { return }
            moves.append(Move(kind: .rapid, op: op, to: p, feed: rapidFeed)); pos = p
        }

        mutating func cut(_ p: SIMD3<Double>, _ op: CutOperation, feed xy: Double) {
            let d = p - pos
            let len = simd_length(d)
            if len < 1e-9 { return }
            let lxy = (d.x * d.x + d.y * d.y).squareRoot()
            var f = xy
            if abs(d.z) > 1e-9 { f = lxy < 1e-9 ? zFeed : min(xy, zFeed * len / abs(d.z)) }
            moves.append(Move(kind: .cut, op: op, to: p, feed: f)); pos = p
        }

        mutating func retract(_ z: Double, _ op: CutOperation) {
            if pos.z < z - 1e-9 { rapid(SIMD3(pos.x, pos.y, z), op) }
        }
    }

    static func machineSettings(_ cnc: CNCSettings, cutter: Double, xy: Double, z: Double, safeZ: Double, rpm: Int) -> CNCSettings {
        var s = cnc
        s.cutterDiameter = cutter; s.xyFeed = xy; s.zFeed = z; s.safeZ = safeZ; s.spindleRPM = rpm
        return s
    }

    // MARK: Dots

    public static func validate(dots s: DotCutSettings, markers m: MarkerSettings) -> [String] {
        var e: [String] = []
        if s.cutterDiameter <= 0 || s.peckDepth <= 0 || s.plungeFeed <= 0 || s.xyFeed <= 0 { e.append("Dot cutter settings must be positive.") }
        if s.cutterDiameter > m.dotDiameter + 1e-9 { e.append("The dot cutter is larger than the dots.") }
        if !(0.05...0.9).contains(s.stepover) { e.append("Dot stepover must be between 5% and 90%.") }
        return e
    }

    /// Peck-drills (or, for dots wider than the cutter, spirals out) every dot. Work origin is the board job's.
    public static func dots(layout L: FretboardLayout, markers m: MarkerSettings, settings s: DotCutSettings, cnc: CNCSettings) -> MarkerJob? {
        let centres = m.dotCentres(L)
        guard !centres.isEmpty, validate(dots: s, markers: m).isEmpty else { return nil }
        let T = cnc.stockThickness
        let op = CutOperation.dotPocket
        var mv = Mover(pos: SIMD3(0, 0, s.safeZ), rapidFeed: cnc.rapidFeed, zFeed: s.plungeFeed, safeZ: s.safeZ)
        let r = s.cutterDiameter / 2
        let ringR = m.dotDiameter / 2 - r
        let step = s.cutterDiameter * s.stepover
        // Heel to nut; at a double dot do both before moving on.
        for c in centres.sorted(by: { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }) {
            let surf = L.topZ(x: c.x, y: c.y) - T
            let floor = surf - m.dotDepth
            mv.rapid(SIMD3(mv.pos.x, mv.pos.y, s.safeZ), op)
            mv.rapid(SIMD3(c.x, c.y, s.safeZ), op)
            mv.rapid(SIMD3(c.x, c.y, surf + 1), op)
            var z = surf
            while z > floor + 1e-9 {
                let prev = z
                z = max(z - s.peckDepth, floor)
                if mv.pos.z > prev + 0.25 { mv.rapid(SIMD3(c.x, c.y, prev + 0.2), op) }
                mv.cut(SIMD3(c.x, c.y, z), op, feed: s.xyFeed)
                if ringR > 1e-6 {
                    // Spiral out in circles; climb milling in a pocket goes clockwise.
                    var radii: [Double] = []
                    var rr = min(step, ringR)
                    while rr < ringR - 1e-9 { radii.append(rr); rr += step }
                    radii.append(ringR)
                    for rad in radii {
                        mv.cut(SIMD3(c.x + rad, c.y, z), op, feed: s.xyFeed)
                        for k in 1...72 {
                            let a = -2 * Double.pi * Double(k) / 72
                            mv.cut(SIMD3(c.x + rad * cos(a), c.y + rad * sin(a), z), op, feed: s.xyFeed)
                        }
                    }
                    mv.cut(SIMD3(c.x, c.y, z), op, feed: s.xyFeed)
                }
                if z > floor + 1e-9 { mv.rapid(SIMD3(c.x, c.y, surf + 0.5), op) }   // clear chips
            }
            mv.retract(s.safeZ, op)
        }
        mv.retract(s.safeZ, op)
        mv.rapid(SIMD3(0, 0, s.safeZ), op)
        let ms = machineSettings(cnc, cutter: s.cutterDiameter, xy: s.xyFeed, z: s.plungeFeed, safeZ: s.safeZ, rpm: s.spindleRPM)
        let tp = Toolpath(start: SIMD3(0, 0, s.safeZ), moves: mv.moves, settings: ms)
        var h: [String] = []
        h.append("; Fretboard Modeller - fret marker dots - WorkBee Z1+ (Duet / RepRapFirmware)")
        h.append("; Work origin: SAME AS THE BOARD JOB - X0 = heel edge of board, Y0 = board centre line, Z0 = TOP of original stock")
        h.append(String(format: "; Stock %.2f mm thick (from the board job). Run after surfacing, before the board is released from its tabs.", T))
        h.append(String(format: "; Cutter: %.2f mm flat end mill. %d dots, %.2f mm diameter, %.2f mm deep below the surface at each centre (flat floor).",
                        s.cutterDiameter, centres.count, m.dotDiameter, m.dotDepth))
        h.append(String(format: "; Pecks of %.2f mm. Feeds: plunge %.0f, X/Y %.0f, rapid %.0f mm/min", s.peckDepth, s.plungeFeed, s.xyFeed, cnc.rapidFeed))
        h.append("; Estimated run time: " + GCodeWriter.formatTime(tp.totalTime))
        return MarkerJob(toolpath: tp, header: h, warnings: [], originOffset: .zero)
    }

    // MARK: Inlay

    public static func validate(inlay s: InlayCutSettings, markers m: MarkerSettings) -> [String] {
        var e: [String] = []
        if s.cutterDiameter <= 0 || s.depthPerLayer <= 0 || s.xyFeed <= 0 || s.plungeFeed <= 0 { e.append("Inlay cutter settings must be positive.") }
        if !(0.05...0.9).contains(s.stepover) { e.append("Inlay stepover must be between 5% and 90%.") }
        if !(0.5...30).contains(s.rampAngle) { e.append("Ramp angle must be between 0.5° and 30°.") }
        if s.wallAllowance < 0 || s.wallAllowance > s.cutterDiameter { e.append("Wall allowance is not valid.") }
        if !(0.1...1).contains(s.slotFeedFactor) { e.append("Slot feed factor must be between 10% and 100%.") }
        if !(0.005...0.2).contains(s.resolution) { e.append("Planning resolution must be between 0.005 and 0.2 mm.") }
        if m.inlay.depth > s.fluteLength - 0.5 { e.append("The pocket is deeper than the cutter's flutes allow.") }
        return e
    }

    /// Clears the inlay pocket with offset loops (inside out) on each depth layer, entering every loop on a ramp,
    /// then a light finishing loop on the walls. The floor follows the board surface.
    public static func inlay(layout L: FretboardLayout, markers m: MarkerSettings, settings s: InlayCutSettings, cnc: CNCSettings) -> MarkerJob? {
        let rings = m.inlayRings(L)
        guard !rings.isEmpty, validate(inlay: s, markers: m).isEmpty else { return nil }
        let r = s.cutterDiameter / 2
        let step = s.cutterDiameter * s.stepover
        let h = s.resolution
        let mask = Raster.rasterize(rings, cell: h, pad: Int(ceil(r / h)) + 4)
        let dist = Raster.distanceInside(mask)
        let dmax = Double(dist.values.max() ?? 0)
        var warnings: [String] = []

        // Origin and surface (machine Z of the finished board top).
        let centre = m.inlayCentre(L)
        let off = s.origin == .board ? SIMD2<Double>.zero : centre
        let T = cnc.stockThickness
        let z0 = s.origin == .board ? T : L.topZ(x: centre.x, y: centre.y)
        func surf(_ p: SIMD2<Double>) -> Double { L.topZ(x: p.x, y: p.y) - z0 }
        func out(_ p: SIMD2<Double>, _ depth: Double) -> SIMD3<Double> { SIMD3(p.x - off.x, p.y - off.y, surf(p) - depth) }
        var clear = -Double.infinity
        for ring in rings { for p in ring { clear = max(clear, surf(p)) } }
        clear += 1.0

        // What the cutter cannot reach: farther than r from every point where its centre fits.
        let reach = Raster.edt(dist) { Double($0) >= r - 1e-9 }
        var uncutGrid = Grid2D(w: mask.w, h: mask.h, origin: mask.origin, cell: h)
        var uncutCells = 0, maskCells = 0
        for k in 0..<mask.values.count where mask.values[k] > 0.5 {
            maskCells += 1
            if Double(reach.values[k]) > r + h { uncutGrid.values[k] = 1; uncutCells += 1 }
        }
        let uncutArea = Double(uncutCells) * h * h, pocketArea = Double(maskCells) * h * h
        let uncutLoops = uncutCells > 0 ? Raster.contours(uncutGrid, level: 0.5) : []
        if dmax < r - 1e-9 {
            warnings.append(String(format: "The whole inlay is narrower than the %.2f mm cutter; nothing can be cut.", s.cutterDiameter))
        } else if uncutArea > 0.01 {
            warnings.append(String(format: "%.1f mm² (%.1f%%) of the inlay is narrower than the cutter and will be left uncut (red in the preview).",
                                   uncutArea, 100 * uncutArea / max(pocketArea, 1e-9)))
        }

        // Offset loops, inside out. Clearing loops leave the wall allowance; the finishing loop is at the cutter radius.
        let label = Raster.label(mask)
        struct Loop { var pts: [SIMD2<Double>]; var offset: Double; var region: Int32; var finish: Bool }
        func loops(at level: Double, finish: Bool) -> [Loop] {
            Raster.contours(dist, level: Float(level)).compactMap { raw in
                // 10 µm is well inside wood movement; points every 2 mm keep the floor within ~2 µm of the radius.
                var pts = Geometry2D.simplify(ring: raw, tol: max(0.01, h / 3))
                pts = Geometry2D.densify(ring: pts, maxLen: 2.0)
                guard pts.count >= 3 else { return nil }
                // Material (lower distance) on the left for climb milling with a clockwise spindle.
                let a = pts[0], b = pts[1]
                let dir = simd_normalize(b - a)
                let left = (a + b) / 2 + SIMD2(-dir.y, dir.x) * (h * 2)
                let materialLeft = Double(dist.sample(left)) < level
                if materialLeft != s.climb { pts.reverse() }
                let g = (pts[0] - dist.origin) / h
                let i = min(max(Int(g.x.rounded()), 0), mask.w - 1), j = min(max(Int(g.y.rounded()), 0), mask.h - 1)
                return Loop(pts: pts, offset: level, region: label[j * mask.w + i], finish: finish)
            }
        }
        var all: [Loop] = []
        if dmax >= r + s.wallAllowance {
            var levels: [Double] = []
            var t = r + s.wallAllowance
            while t <= dmax + 1e-9 { levels.append(t); t += step }
            for lv in levels.reversed() { all += loops(at: lv, finish: false) }
        }
        if dmax >= r { all += loops(at: r, finish: true) }

        // Regions in nearest-neighbour order from the origin.
        var regionCentre: [Int32: SIMD2<Double>] = [:]
        for l in all where regionCentre[l.region] == nil { regionCentre[l.region] = l.pts.reduce(.zero, +) / Double(l.pts.count) }
        var regions: [Int32] = []
        var here = centre
        var left = Set(regionCentre.keys)
        while let nxt = left.min(by: { simd_distance(regionCentre[$0]!, here) < simd_distance(regionCentre[$1]!, here) }) {
            regions.append(nxt); left.remove(nxt); here = regionCentre[nxt]!
        }

        let layers = max(1, Int(ceil(m.inlay.depth / s.depthPerLayer - 1e-9)))
        let depths = (1...layers).map { min(m.inlay.depth, Double($0) * s.depthPerLayer) }
        var mv = Mover(pos: SIMD3(0, 0, s.safeZ), rapidFeed: cnc.rapidFeed, zFeed: s.plungeFeed, safeZ: s.safeZ)
        let tanA = tan(s.rampAngle * Double.pi / 180)
        let slotFeed = s.xyFeed * s.slotFeedFactor

        /// True when the straight move a→b keeps the cutter inside the pocket.
        func safeLink(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
            let n = max(2, Int(ceil(simd_distance(a, b) / (h / 2))))
            for k in 0...n where Double(dist.sample(a + (b - a) * (Double(k) / Double(n)))) < r - h { return false }
            return true
        }

        for reg in regions {
            let regLoops = all.filter { $0.region == reg }
            let ordered = regLoops.filter { !$0.finish }.sorted { $0.offset > $1.offset } + regLoops.filter(\.finish)
            for (li, depth) in depths.enumerated() {
                let prevDepth = li == 0 ? 0.0 : depths[li - 1]
                var linkedFrom: Loop?
                for loop in ordered {
                    let op: CutOperation = loop.finish ? .inlayFinish : .inlayClear
                    // Start where the cutter already is.
                    let cur = mv.moves.isEmpty ? centre : SIMD2(mv.pos.x, mv.pos.y) + off
                    let si = loop.pts.indices.min { simd_distance(loop.pts[$0], cur) < simd_distance(loop.pts[$1], cur) }!
                    let pts = Array(loop.pts[si...] + loop.pts[..<si])
                    var p = pts + [pts[0]]
                    let canLink = linkedFrom != nil && simd_distance(cur, pts[0]) <= max(1.6 * step, s.wallAllowance + 2 * h)
                        && safeLink(cur, pts[0]) && abs(mv.pos.z - out(cur, depth).z) < 0.05
                    if canLink {
                        mv.cut(out(pts[0], depth), op, feed: s.xyFeed)
                        for q in p.dropFirst() { mv.cut(out(q, depth), op, feed: s.xyFeed) }
                    } else {
                        // Enter: lift, move over, drop to just above the last floor, ramp down along the loop.
                        mv.retract(clear, op)
                        mv.rapid(SIMD3(pts[0].x - off.x, pts[0].y - off.y, clear), op)
                        let above = out(pts[0], prevDepth - 0.2)
                        mv.rapid(above, op)
                        mv.cut(out(pts[0], prevDepth), op, feed: slotFeed)
                        let rampLen = (depth - prevDepth) / tanA
                        var travelled = 0.0
                        var k = 0
                        var last = pts[0]
                        while travelled < rampLen - 1e-9 {
                            let q = p[(k % pts.count) + 1]
                            let seg = simd_distance(last, q)
                            if travelled + seg >= rampLen {
                                let t = (rampLen - travelled) / max(seg, 1e-12)
                                let e = last + (q - last) * t
                                mv.cut(out(e, depth), op, feed: slotFeed)
                                // Finish the lap at depth from the ramp's end point.
                                let idx = (k % pts.count) + 1
                                p = [e] + Array(p[idx...]) + Array(p[1..<idx]) + [e]
                                travelled = rampLen
                                break
                            }
                            travelled += seg
                            mv.cut(out(q, prevDepth + (depth - prevDepth) * travelled / rampLen), op, feed: slotFeed)
                            last = q; k += 1
                        }
                        for q in p.dropFirst() { mv.cut(out(q, depth), op, feed: slotFeed) }
                    }
                    linkedFrom = loop
                }
            }
            mv.retract(clear, .inlayFinish)
        }
        mv.retract(s.safeZ, .inlayFinish)
        mv.rapid(SIMD3(0, 0, s.safeZ), .inlayFinish)

        let ms = machineSettings(cnc, cutter: s.cutterDiameter, xy: s.xyFeed, z: s.plungeFeed, safeZ: s.safeZ, rpm: s.spindleRPM)
        let tp = Toolpath(start: SIMD3(0, 0, s.safeZ), moves: mv.moves, settings: ms)
        var hd: [String] = []
        hd.append("; Fretboard Modeller - fret \(m.inlay.fret) inlay pocket - WorkBee Z1+ (Duet / RepRapFirmware)")
        if s.origin == .board {
            hd.append("; Work origin: SAME AS THE BOARD JOB - X0 = heel edge of board, Y0 = board centre line, Z0 = TOP of original stock")
            hd.append(String(format: "; Stock %.2f mm thick (from the board job). Run after surfacing, before the board is released from its tabs.", T))
            hd.append(String(format: "; Inlay centre is at X%.3f Y%.3f; the board surface there is Z%.3f", centre.x, centre.y, surf(centre)))
        } else {
            hd.append("; Work origin: X0 Y0 = CENTRE OF THE INLAY (fret space centre plus offsets), Z0 = BOARD SURFACE at that point")
            hd.append(String(format: "; (In board coordinates the centre is X%.3f Y%.3f from the heel edge and centre line.)", centre.x, centre.y))
        }
        hd.append(String(format: "; Cutter: %.2f mm flat end mill (flute %.1f mm). Inside corners are rounded to %.2f mm radius.", s.cutterDiameter, s.fluteLength, r))
        hd.append(String(format: "; Pocket %.2f mm deep, floor follows the board radius. %d layers of %.2f mm; stepover %.0f%%; %.2f mm left for the finishing loop.",
                         m.inlay.depth, layers, s.depthPerLayer, s.stepover * 100, s.wallAllowance))
        hd.append(String(format: "; Entry: %.1f° ramps along the path. Feeds: X/Y %.0f (%.0f in full-width slots), plunge %.0f, rapid %.0f mm/min",
                         s.rampAngle, s.xyFeed, slotFeed, s.plungeFeed, cnc.rapidFeed))
        hd.append(String(format: "; Milling: %@", s.climb ? "climb (clockwise spindle)" : "conventional"))
        hd.append("; Estimated run time: " + GCodeWriter.formatTime(tp.totalTime))
        for w in warnings { hd.append("; WARNING: " + w) }
        return MarkerJob(toolpath: tp, header: hd, warnings: warnings, originOffset: off,
                         displayShift: SIMD3(off.x, off.y, z0 - T),
                         uncut: uncutLoops, uncutArea: uncutArea, pocketArea: pocketArea)
    }
}
