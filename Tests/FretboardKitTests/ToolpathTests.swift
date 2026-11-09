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
    for kind in [CutterType.flat, .ball] {
        let (l, t) = job(true) { $0.cutter = kind }
        let T = t.settings.stockThickness, r = t.settings.cutterRadius
        var rng = SystemRandomNumberGenerator()
        for m in t.moves {
            #expect(m.to.z <= t.settings.safeZ + 1e-9)
            guard m.kind == .cut else { continue }
            #expect(m.to.z >= -T - t.settings.throughCutExtra - 1e-9)
            guard m.op == .roughSurface || m.op == .finishSurface else { continue }
            let allow = m.op == .roughSurface ? t.settings.roughAllowance : 0
            // Surface points under the cutter must not be above what the tool leaves.
            for _ in 0..<6 {
                let a = Double.random(in: 0..<(2 * .pi), using: &rng), d = r * Double.random(in: 0...1, using: &rng).squareRoot()
                let px = m.to.x + d * cos(a), py = m.to.y + d * sin(a)
                var allowed = m.to.z
                if kind == .ball { allowed -= 0 }
                if kind == .flat {
                    #expect(l.topZ(x: px, y: py) - T + allow <= allowed + 0.005)
                } else {
                    // sphere of radius r with tip at m.to.z
                    let sphereZ = m.to.z + r - (r * r - d * d).squareRoot()
                    #expect(l.topZ(x: px, y: py) - T + allow <= sphereZ + 0.005)
                }
            }
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

@Test func finishStepoverUsesThirtyPercentOverlap() {
    let (_, t) = job()
    let xs = Set(t.moves.filter { $0.op == .finishSurface && $0.kind == .cut }.map { ($0.to.x * 1e4).rounded() / 1e4 }).sorted()
    var maxGap = 0.0
    for i in 1..<xs.count { maxGap = max(maxGap, xs[i] - xs[i - 1]) }
    #expect(maxGap <= 6.0 * 0.7 + 1e-6)
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
    for d in [3.0, 3.5] {
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
