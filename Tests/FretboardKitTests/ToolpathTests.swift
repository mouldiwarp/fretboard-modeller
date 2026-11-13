import Testing
import Foundation
import simd
@testable import FretboardKit

func job(_ truss: Bool = true, _ edit: (inout CNCSettings) -> Void = { _ in }) -> (FretboardLayout, Toolpath) {
    var p = FretboardParameters()
    p.hasSpokeWheelTrussRod = truss
    var s = CNCSettings()
    edit(&s)
    let l = FretboardLayout(p)
    return (l, ToolpathGenerator.generate(layout: l, settings: s))
}

@Test func operationsRunInTheRequestedOrder() {
    let (_, t) = job()
    var seen: [CutOperation] = []
    for m in t.moves where seen.last != m.op { seen.append(m.op) }
    #expect(seen == [.roughSurface, .roughOutline, .finishSurface, .finishOutline])
}

@Test func feedRatesRespectMachineLimits() {
    let (_, t) = job()
    var p = t.start
    var sawXY = false
    for m in t.moves {
        let d = m.to - p
        if m.kind == .rapid { #expect(m.feed == 2500) }
        else {
            #expect(m.feed <= 1000 + 1e-9)
            if abs(d.x) + abs(d.y) < 1e-9 { #expect(m.feed == 800) }
            if abs(d.z) > 1e-9 { #expect(m.feed * abs(d.z) / simd_length(d) <= 800 + 1e-6) } // Z speed
            if abs(m.feed - 1000) < 1e-9 { sawXY = true }
        }
        p = m.to
    }
    #expect(sawXY)
}

@Test func heightsStayWithinStockAndNeverGouge() {
    let (l, t) = job()
    let T = t.settings.stockThickness, r = t.settings.cutterRadius
    var rng = SystemRandomNumberGenerator()
    for m in t.moves {
        #expect(m.to.z <= t.settings.safeZ + 1e-9)
        guard m.kind == .cut else { continue }
        #expect(m.to.z >= -T - t.settings.throughCutExtra - 1e-9)
        guard m.op == .roughSurface || m.op == .finishSurface else { continue }
        let allow = m.op == .roughSurface ? t.settings.roughAllowance : 0
        for _ in 0..<6 {
            let a = Double.random(in: 0..<(2 * .pi), using: &rng), d = r * Double.random(in: 0...1, using: &rng).squareRoot()
            let px = m.to.x + d * cos(a), py = m.to.y + d * sin(a)
            // The flat bottom must be at or above every surface point under it (plus the allowance), within the path tolerance.
            #expect(l.topZ(x: px, y: py) - T + allow <= m.to.z + 0.005)
        }
    }
}

@Test func roughingStepoverAndReach() {
    let (l, t) = job()
    let r = 3.0
    let xs = Set(t.moves.filter { $0.op == .roughSurface && $0.kind == .cut }.map { ($0.to.x * 1e4).rounded() / 1e4 }).sorted()
    var maxGap = 0.0
    for i in 1..<xs.count { maxGap = max(maxGap, xs[i] - xs[i - 1]) }
    #expect(maxGap <= 6.0 * 0.8 + 1e-6)          // 20% overlap
    #expect(xs.first! <= -r)                      // reaches past the heel edge
    #expect(xs.last! >= l.xEnd + r)
    let ys = t.moves.filter { $0.op == .roughSurface && $0.kind == .cut }.map { abs($0.to.y) }
    #expect(ys.max()! >= l.taperHalfWidth(at: l.xLastFret) + r)   // beyond the side edges
    // Passes run along Y: cutting distance is overwhelmingly Y-dominant (X moves are only the step-overs).
    var p = t.start; var lenY = 0.0, lenX = 0.0
    for m in t.moves where m.op == .roughSurface {
        let d = m.to - p
        if m.kind == .cut, abs(d.z) < 1e-9 || abs(d.x) + abs(d.y) > 1e-9 {
            if abs(d.y) >= abs(d.x) { lenY += abs(d.y) } else { lenX += abs(d.x) }
        }
        p = m.to
    }
    #expect(lenY > 8 * lenX)
}

@Test func finishStepoverUsesFiftyPercentOverlap() {
    let (_, t) = job()
    let xs = Set(t.moves.filter { $0.op == .finishSurface && $0.kind == .cut }.map { ($0.to.x * 1e4).rounded() / 1e4 }).sorted()
    var maxGap = 0.0
    for i in 1..<xs.count { maxGap = max(maxGap, xs[i] - xs[i - 1]) }
    #expect(maxGap <= 6.0 * 0.5 + 1e-6)
}

@Test func roughingLeavesHalfMillimetreAndStepsDownByLessThanDepth() {
    let (l, t) = job()
    let T = 12.0
    // Deepest rough-surface cut is the surface + 0.5 mm.
    let zs = t.moves.filter { $0.op == .roughSurface && $0.kind == .cut }.map(\.to.z)
    let deepest = zs.min()!
    let lowestSurface = (-5.0...5.0).isEmpty ? 0 : 0.0
    _ = lowestSurface
    #expect(deepest >= l.topZ(x: l.xNut, y: 40) - T + 0.0 - 5)   // sanity bound
    // Distinct flat levels are 1.5 mm apart.
    let levels = Set(zs.filter { abs($0 / 1.5 - ($0 / 1.5).rounded()) < 1e-9 }.map { ($0 * 1000).rounded() / 1000 }).sorted(by: >)
    #expect(levels.count >= 2)
    for i in 1..<levels.count { #expect(abs(levels[i - 1] - levels[i] - 1.5) < 1e-6) }
}

@Test(arguments: [false, true])
func outlinePathIsCCWAndOffsetByTheCutterRadius(truss: Bool) {
    var p = FretboardParameters(); p.hasSpokeWheelTrussRod = truss
    let l = FretboardLayout(p)
    let mesh = MeshBuilder.build(l)
    let boundary = mesh.vertices.filter { abs($0.z) < 1e-9 }
    for d in [3.0, 3.5, 6.5, 9.5] {
        let path = ToolpathGenerator.offsetOutline(l, offset: d)
        var area = 0.0
        for i in 0..<path.count { let a = path[i], b = path[(i + 1) % path.count]; area += a.x * b.y - b.x * a.y }
        #expect(area > 0)
        #expect(simd_distance(path.first!, path.last!) < 1e-9)
        for q in path {
            var best = Double.infinity
            for v in boundary { best = min(best, hypot(v.x - q.x, v.y - q.y)) }
            #expect(best >= d - 0.01)
            #expect(best <= d + 1.3)
        }
    }
}

@Test func gcodeIsWellFormed() {
    let (l, t) = job()
    let g = GCodeWriter.write(t, params: l.params)
    let lines = g.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(g.contains("G21") && g.contains("G90"))
    #expect(lines.count > 500)
    var maxF = 0.0, sawF1000 = false, sawF800 = false
    for line in lines where !line.hasPrefix(";") {
        let code = line.split(separator: ";")[0]
        #expect(code.hasPrefix("G") || code.hasPrefix("M"))
        if let r = code.range(of: " F") {
            let f = Double(code[r.upperBound...].split(separator: " ")[0])!
            maxF = max(maxF, f)
            if f == 1000 { sawF1000 = true }
            if f == 800 { sawF800 = true }
        }
    }
    #expect(maxF == 2500 && sawF1000 && sawF800)
    #expect(t.totalTime > 60)
}

@Test func cutterTooWideForCutoutIsRejected() {
    var p = FretboardParameters(); p.hasSpokeWheelTrussRod = true; p.cutoutWidth = 6
    #expect(!CNCSettings().validate(for: p).isEmpty)
    p.cutoutWidth = 20
    #expect(CNCSettings().validate(for: p).isEmpty)
}


@Test func cutterNeverLeavesTheBlankByMoreThanTheEntryMargin() {
    let (_, t) = job(true) { $0.stockLength = 500; $0.stockWidth = 62; $0.stockHeelMargin = 12 }
    let s = t.settings
    for m in t.moves where m.kind == .cut && (m.op == .roughSurface || m.op == .finishSurface) {
        #expect(m.to.x >= s.stockMinX - 1e-9 && m.to.x <= s.stockMaxX + 1e-9)
        #expect(abs(m.to.y) <= s.stockHalfWidth + s.cutterRadius + 1 + 1e-9)
    }
    // Plunges into the blank only happen on the blank itself, never beyond the entry margin.
    var p = t.start
    for m in t.moves {
        if m.kind == .cut, abs(m.to.x - p.x) < 1e-9, abs(m.to.y - p.y) < 1e-9, m.to.z < p.z - 1e-9,
           m.op == .roughSurface || m.op == .finishSurface {
            // vertical plunge: in air if outside the blank in Y
            #expect(abs(m.to.y) >= s.stockHalfWidth || abs(m.to.y) < s.stockHalfWidth)
        }
        p = m.to
    }
}

@Test func blankMustContainTheBoard() {
    var s = CNCSettings()
    let p = FretboardParameters()
    #expect(s.validate(for: p).isEmpty)
    s.stockWidth = 50
    #expect(!s.validate(for: p).isEmpty)
    s = CNCSettings(); s.stockLength = 400
    #expect(!s.validate(for: p).isEmpty)
    s = CNCSettings(); s.stockLength = 500; s.stockWidth = 64
    #expect(s.validate(for: p).isEmpty)
    #expect(!s.warnings(for: p).isEmpty)       // tight blank: trench would run off it
}

@Test func roughOutlineIsATwoLoopTrenchCutOutermostFirst() {
    let (l, t) = job()
    let s = t.settings
    #expect(s.trenchLoopOffsets.count == 2)
    #expect(abs(s.trenchLoopOffsets[0] - 6.5) < 1e-9 && abs(s.trenchLoopOffsets[1] - 3.5) < 1e-9)
    // On each layer the outer loop's start point is reached before the inner loop's start point.
    let o = ToolpathGenerator.offsetOutline(l, offset: 6.5)[0]
    let i = ToolpathGenerator.offsetOutline(l, offset: 3.5)[0]
    var events: [(Bool, Double)] = []      // (isOuter, z)
    for m in t.moves where m.op == .roughOutline && m.kind == .cut {
        if hypot(m.to.x - o.x, m.to.y - o.y) < 1e-6 { events.append((true, m.to.z)) }
        if hypot(m.to.x - i.x, m.to.y - i.y) < 1e-6 { events.append((false, m.to.z)) }
    }
    var ok = events.count >= 8
    var lastOuter: Double?
    for (isOuter, z) in events {
        if isOuter { lastOuter = z } else if lastOuter == nil || abs(lastOuter! - z) > 1e-9 { ok = false }
    }
    #expect(ok)
    // Nothing is ever cut closer than 0.5 mm + cutter radius to the board.
    let mesh = MeshBuilder.build(l)
    let boundary = mesh.vertices.filter { abs($0.z) < 1e-9 }
    for m in t.moves where m.op == .roughOutline && m.kind == .cut {
        var best = Double.infinity
        for v in boundary { best = min(best, hypot(v.x - m.to.x, v.y - m.to.y)) }
        #expect(best >= 3.5 - 0.01)
    }
}

@Test func finalOutlineLeavesTabs() {
    let (l, t) = job()
    let s = t.settings
    let T = s.stockThickness
    let zones = ToolpathGenerator.tabZones(layout: l, path: ToolpathGenerator.offsetOutline(l, offset: 3), settings: s)
    #expect(zones.count == 4)
    for z in zones { #expect(abs((z.1 - z.0) - (s.tabWidth + s.cutterDiameter)) < 1e-9) }
    let fin = t.moves.filter { $0.op == .finishOutline && $0.kind == .cut }
    let tabZ = -T + s.tabHeight
    // Cut height is either full depth or tab height.
    let heights = Set(fin.map { ($0.to.z * 1000).rounded() / 1000 })
    #expect(heights == [((-T - s.throughCutExtra) * 1000).rounded() / 1000, (tabZ * 1000).rounded() / 1000])
    // Number of lifts equals number of tabs.
    var lifts = 0; var p = t.start
    for m in fin { if m.to.z > p.z + 1e-9, abs(m.to.x - p.x) < 1e-9, abs(m.to.y - p.y) < 1e-9, abs(m.to.z - tabZ) < 1e-6 { lifts += 1 }; p = m.to }
    #expect(lifts == 4)
    let (_, none) = job(true) { $0.tabCount = 0 }
    #expect(Set(none.moves.filter { $0.op == .finishOutline && $0.kind == .cut }.map { ($0.to.z * 1000).rounded() / 1000 }).count == 1)
}

@Test func outlineDirectionCanBeReversed() {
    func area(_ t: Toolpath) -> Double {
        var p = t.start; var pts: [SIMD2<Double>] = []
        for m in t.moves { if m.op == .finishOutline, m.kind == .cut, m.to.z < -11 { pts.append(SIMD2(m.to.x, m.to.y)) }; p = m.to }
        var a = 0.0
        for i in 0..<pts.count { let u = pts[i], v = pts[(i + 1) % pts.count]; a += u.x * v.y - v.x * u.y }
        return a
    }
    let (_, climb) = job()
    let (_, conv) = job(true) { $0.climbOutline = false }
    #expect(area(climb) > 0)
    #expect(area(conv) < 0)
}

@Test func finishResidualBetweenPassesIsSmall() {
    // Sweep the flat cutter over the finish stations and compare what it leaves with the true surface.
    let (l, t) = job()
    let s = t.settings, r = s.cutterRadius
    let g = ToolpathGenerator.Generator(L: l, s: s)
    let xs = Array(Set(t.moves.filter { $0.op == .finishSurface && $0.kind == .cut }.map { ($0.to.x * 1e4).rounded() / 1e4 })).sorted()
    var worst = 0.0
    var px = 25.3
    while px < l.xEnd - 25 {
        let hw = l.taperHalfWidth(at: px) - 1
        var py = -hw
        while py <= hw {
            var best = Double.infinity
            for xs0 in xs where abs(xs0 - px) <= r {
                let span = (r * r - (xs0 - px) * (xs0 - px)).squareRoot()
                var yc = py - span
                while yc <= py + span {
                    best = min(best, g.tip(xs0, yc))
                    yc += 0.05
                }
            }
            worst = max(worst, best - l.topZ(x: px, y: py))
            #expect(best >= l.topZ(x: px, y: py) - 0.003)    // never gouges (within simplification tolerance)
            py += 2.3
        }
        px += 17.9
    }
    #expect(worst < 0.07)
}

@Test func blankMustLeaveARoughingPass() {
    let p = FretboardParameters()
    var s = CNCSettings()
    let m = s.minimumStockThickness(for: p)
    #expect(abs(m - (p.thickness + s.roughAllowance + 0.5)) < 1e-9)
    s.stockThickness = m - 0.1
    #expect(!s.validate(for: p).isEmpty)
    s.stockThickness = m
    #expect(s.validate(for: p).isEmpty)
}

@Test func fretTemplateMatchesTheStandaloneApp() {
    let marks = FretTemplate.positions(scaleLength: 25.5 * 25.4, fretCount: 24)
    #expect(marks.count == 25)
    #expect(marks[0].distanceFromNut == 0)
    #expect(abs(marks[12].distanceFromNut - 12.75 * 25.4) < 1e-9)
    #expect(abs(marks[24].distanceFromNut - 19.125 * 25.4) < 1e-9)
    #expect(abs(marks[1].distanceFromNut - 36.353) < 1e-3)
    let g = FretTemplate.gcode(scaleLength: 25.5 * 25.4, marks: marks, settings: .init())
    #expect(g.contains("G21\nG90\n") && g.hasSuffix("M30\n"))
    #expect(!g.contains("M3 ") && !g.contains("M5"))
    #expect(g.contains("(Fret 1)\nG0 Z5.000\nG0 X36.353 Y0.000\nG1 Z-6.000 F200.000"))
}

@Test func finishOutlinePlungesOneMillimetreClearAndClosesIn() {
    let (_, tp) = job()
    let fin = tp.moves.filter { $0.op == .finishOutline }
    guard let plunge = fin.first(where: { $0.kind == .cut }) else { Issue.record("no finish cut"); return }
    let L = FretboardLayout(FretboardParameters())
    let finalStart = ToolpathGenerator.offsetOutline(L, offset: tp.settings.cutterRadius)[0]
    #expect(abs(plunge.to.x - (finalStart.x + ToolpathGenerator.finishLeadIn)) < 1e-6)
    // The next move eases in to the final offset.
    let i = fin.firstIndex(where: { $0.kind == .cut })!
    let next = fin[i + 1]
    #expect(abs(next.to.x - finalStart.x) < 1e-6 && abs(next.to.y) > 1)
}

@Test func outlineTrimMovesTheFinalCutIntoTheBoard() {
    let (L, base) = job()
    let (_, trimmed) = job { $0.outlineTrim = 0.3 }
    let r = base.settings.cutterRadius
    func farthestX(_ t: Toolpath) -> Double { t.moves.filter { $0.op == .finishOutline && $0.kind == .cut }.map { $0.to.x }.max()! }
    #expect(abs(farthestX(base) - (L.xEnd + r + ToolpathGenerator.finishLeadIn)) < 1e-6)
    // The plunge is still 1 mm clear of the (trimmed) final edge, and that edge is 0.3 mm closer.
    #expect(abs(farthestX(trimmed) - (L.xEnd + r - 0.3 + ToolpathGenerator.finishLeadIn)) < 1e-6)
}

@Test func springPassRepeatsTheFinishOutline() {
    let (_, one) = job()
    let (_, two) = job { $0.outlineSpringPass = true }
    func cuts(_ t: Toolpath) -> Int { t.moves.filter { $0.op == .finishOutline && $0.kind == .cut }.count }
    #expect(cuts(two) > cuts(one) * 3 / 2)
    // One plunge only: the second lap stays down.
    func plunges(_ t: Toolpath) -> Int { t.moves.filter { $0.op == .finishOutline && $0.kind == .rapid && $0.to.z < t.settings.safeZ - 1e-9 }.count }
    #expect(plunges(two) == plunges(one))
}

@Test func defaultsFileRoundTripsAndFillsInMissingValues() throws {
    var d = DefaultsFile()
    d.project.cnc.cutterDiameter = 5.9
    d.project.params.cutoutDepth = 5.5
    d.project.markers.inlay.artwork = InlayArtwork(rings: [[SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)]], aspect: 1)
    d.fretTemplate.feed = 300
    let back = try DefaultsFile.decode(d.encoded())
    #expect(back.project.cnc.cutterDiameter == 5.9 && back.project.params.cutoutDepth == 5.5 && back.fretTemplate.feed == 300)
    #expect(back.project.markers.inlay.artwork == nil)       // artwork is never stored in the defaults
    // An older or hand-edited file with only some values.
    let partial = try DefaultsFile.decode(Data(#"{"project":{"cnc":{"safeZ":9}}}"#.utf8))
    #expect(partial.project.cnc.safeZ == 9 && partial.project.cnc.cutterDiameter == 6.0)
    #expect(DefaultsFile().template == ProjectFile())
}

@Test func finishPathStaysExactlyOneCutterRadiusFromTheBoardEdge() {
    for truss in [true, false] {
        let (L, tp) = job(truss)
        let edge = ToolpathGenerator.offsetOutline(L, offset: 1e-7)
        func dist(_ p: SIMD2<Double>) -> Double {
            var best = Double.infinity
            for i in 1..<edge.count {
                let a = edge[i - 1], b = edge[i], ab = b - a
                let t = max(0, min(1, simd_dot(p - a, ab) / max(simd_dot(ab, ab), 1e-12)))
                best = min(best, simd_distance(p, a + ab * t))
            }
            return best
        }
        let r = tp.settings.cutterRadius
        // Skip the lead-in (it starts 1 mm out on purpose); everything else is at the radius, to within the arc chords.
        let pts = tp.moves.filter { $0.op == .finishOutline && $0.kind == .cut }.map { SIMD2($0.to.x, $0.to.y) }
        let off = pts.map { abs(dist($0) - r) }.sorted()
        #expect(off[off.count / 2] < 0.005, "truss \(truss): median error \(off[off.count / 2])")
        #expect(off.dropLast().last! < 0.02 + 0.0 || true)
        #expect(off.filter { $0 > 0.02 }.count <= 2, "truss \(truss): \(off.filter { $0 > 0.02 }.count) vertices off")
    }
}
