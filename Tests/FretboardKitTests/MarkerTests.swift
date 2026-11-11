import Testing
import Foundation
import simd
@testable import FretboardKit

func markers(_ mode: MarkerMode, _ edit: (inout MarkerSettings) -> Void = { _ in }) -> (FretboardLayout, MarkerSettings) {
    var m = MarkerSettings()
    m.mode = mode
    edit(&m)
    return (FretboardLayout(FretboardParameters()), m)
}

/// A test artwork: a filled rounded "ring" (annulus) with a separate dot, normalised to the unit box.
func testArtwork() -> InlayArtwork {
    let outer = Geometry2D.circle(center: SIMD2(-0.2, 0), radius: 0.3, segments: 90)
    let hole = Geometry2D.circle(center: SIMD2(-0.2, 0), radius: 0.15, segments: 60)
    let dot = Geometry2D.circle(center: SIMD2(0.38, 0), radius: 0.1, segments: 40)
    return InlayArtwork(rings: [outer, hole, dot], aspect: 2)
}

@Test func compensatedSpacingSpansTheOuterStrings() {
    let s = StringSpacing()
    let o = s.offsets(span: 52.4)
    #expect(o.count == 6)
    #expect(abs(o[0] - 26.2) < 1e-9 && abs(o[5] + 26.2) < 1e-9)
    // Equal gaps between string edges.
    let g = s.gauges.map { $0 * 25.4 }
    let gaps = (0..<5).map { (o[$0] - o[$0 + 1]) - g[$0] / 2 - g[$0 + 1] / 2 }
    for x in gaps { #expect(abs(x - gaps[0]) < 1e-9) }
}

@Test func dotsSitMidSpaceAndDoubleDotsUnderBAndA() {
    let (L, m) = markers(.dots)
    let dots = m.dotCentres(L)
    #expect(dots.count == 8 + 2)       // 3 5 7 9 15 17 19 21 single, 12 double (22 frets, so no 24)
    let x12 = MarkerSettings.spaceCentreX(L, 12)
    let twelve = dots.filter { abs($0.x - x12) < 1e-9 }
    #expect(twelve.count == 2)
    // B (treble side, +Y) and A (bass side), almost symmetric (string gauges shift them slightly).
    let ys = twelve.map(\.y).sorted()
    #expect(ys[0] < -5 && ys[1] > 5)
    // Compensated spacing pushes the pair toward the treble side by half the gauge differences.
    let g = m.strings.gauges.map { $0 * 25.4 }
    #expect(abs((ys[0] + ys[1]) - ((g[5] - g[0]) / 2 + (g[4] - g[1]) / 2)) < 1e-9)
    let x3 = MarkerSettings.spaceCentreX(L, 3)
    #expect(abs(x3 - (L.fretX(2) + L.fretX(3)) / 2) < 1e-12)
    #expect(dots.contains { abs($0.x - x3) < 1e-9 && $0.y == 0 })
    #expect(m.validate(L).isEmpty)
}

@Test(arguments: [false, true])
func dottedMeshIsWatertightAndLosesTheDotVolume(truss: Bool) {
    var p = FretboardParameters(); p.hasSpokeWheelTrussRod = truss
    let L = FretboardLayout(p)
    var m = MarkerSettings(); m.mode = .dots
    let plain = MeshBuilder.build(L)
    let mesh = MeshBuilder.build(L, pockets: m.pockets(L))
    #expect(mesh.isWatertight)
    let n = Double(m.dotCentres(L).count)
    // Polygonal dot (72 sides) of radius 3, 3 mm deep at the centre; the curved rim adds a little.
    let expected = n * 72 / 2 * 9 * sin(2 * Double.pi / 72) * 3
    let lost = plain.volume - mesh.volume
    #expect(abs(lost - expected) / expected < 0.02)
}

@Test func inlayMeshIsWatertightWithIslands() {
    let (L, m) = markers(.dotsAndInlay) { $0.inlay.artwork = testArtwork(); $0.inlay.width = 36; $0.inlay.height = 18 }
    #expect(m.validate(L).isEmpty)
    let mesh = MeshBuilder.build(L, pockets: m.pockets(L))
    #expect(mesh.isWatertight)
    // 12th double dot is replaced by the inlay.
    #expect(m.dotCentres(L).count == 8)
    // Inlay area: annulus + dot, scaled by 36 x 18; volume ≈ area × 3.
    let area = (Double.pi * (0.09 - 0.0225) + Double.pi * 0.01) * 36 * 18
    let lost = MeshBuilder.build(L, pockets: []).volume - mesh.volume
    let dots = 8 * 72 / 2 * 9 * sin(2 * Double.pi / 72) * 3
    #expect(abs((lost - dots) - area * 3) / (area * 3) < 0.03)
}

@Test func contouredFloorFollowsTheSurface() {
    let (L, m) = markers(.inlayOnly) { $0.inlay.artwork = testArtwork(); $0.inlay.width = 40; $0.inlay.height = 20 }
    let mesh = MeshBuilder.build(L, pockets: m.pockets(L))
    let rings = m.inlayRings(L)
    // Every vertex strictly inside the inlay is on the floor, 3 mm below the surface.
    var checked = 0
    for v in mesh.vertices where Geometry2D.contains(rings: rings, SIMD2(v.x, v.y)) && v.z > 0.5 && v.z < L.topZ(x: v.x, y: v.y) - 1 {
        #expect(abs(L.topZ(x: v.x, y: v.y) - 3 - v.z) < 1e-3)
        checked += 1
    }
    #expect(checked > 50)
}

@Test func surfaceStaysOnTheRadiusAroundPockets() {
    let (L, m) = markers(.dots)
    let mesh = MeshBuilder.build(L, pockets: m.pockets(L))
    // Centroids of upward-facing triangles near a dot lie on the radiused surface (within a few microns).
    let c = m.dotCentres(L)[0]
    var worst = 0.0
    for t in mesh.allTriangles where t.normal.z > 0.5 {
        let g = (t.a + t.b + t.c) / 3
        guard simd_distance(SIMD2(g.x, g.y), c) < 8, simd_distance(SIMD2(g.x, g.y), c) > 3.2 else { continue }
        worst = max(worst, abs(L.topZ(x: g.x, y: g.y) - g.z))
    }
    #expect(worst < 0.01)
}

@Test func markerValidationCatchesProblems() {
    let (L, m0) = markers(.dots) { $0.dotDiameter = 30 }
    #expect(!m0.validate(L).isEmpty)                       // too close to the edge / each other
    let (_, m1) = markers(.inlayOnly)
    #expect(!m1.validate(L).isEmpty)                       // no artwork
    let (_, m2) = markers(.inlayOnly) { $0.inlay.artwork = testArtwork(); $0.inlay.width = 60; $0.inlay.height = 90 }
    #expect(!m2.validate(L).isEmpty)                       // wider than the board
}


// MARK: - Tracing

/// A white image with a black ring (annulus) and a black square.
func syntheticImage() -> (gray: [UInt8], w: Int, h: Int) {
    let w = 400, h = 200
    var g = [UInt8](repeating: 255, count: w * h)
    for j in 0..<h { for i in 0..<w {
        let d = ((Double(i) - 100) * (Double(i) - 100) + (Double(j) - 100) * (Double(j) - 100)).squareRoot()
        if d <= 80 && d >= 40 { g[j * w + i] = 0 }
        if i >= 250 && i < 350 && j >= 50 && j < 150 { g[j * w + i] = 0 }
    } }
    return (g, w, h)
}

@Test func tracingFindsOutlinesHolesAndAspect() {
    let img = syntheticImage()
    var o = InlayTracer.Options(); o.smoothing = 0
    let art = InlayTracer.trace(gray: img.gray, width: img.w, height: img.h, options: o)!
    #expect(art.rings.count == 3)                         // ring outside, ring hole, square
    // Artwork spans x 20...350 (330 px) and y 20...180 (160 px).
    #expect(abs(art.aspect - 330.0 / 160.0) < 0.03)
    // Even-odd area in px²: annulus + square.
    let px = 330.0 * 160.0
    let area = art.rings.map { abs(Geometry2D.signedArea($0)) }.sorted(by: >)
    let ink = (area[0] + area[1] + area[2] - 2 * area.min()!) * px   // largest two are the outer circle/square; subtract hole twice
    let expected = Double.pi * (80 * 80 - 40 * 40) + 100 * 100
    #expect(abs(ink - expected) / expected < 0.03)
    var inv = o; inv.invert = true
    #expect(InlayTracer.trace(gray: img.gray, width: img.w, height: img.h, options: inv) != nil)
}

@Test func distanceTransformIsEuclidean() {
    let sq = [[SIMD2(0.0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]]
    let g = Raster.rasterize(sq, cell: 0.1)
    let d = Raster.distanceInside(g)
    #expect(abs(Double(d.sample(SIMD2(5, 5))) - 5) < 0.15)
    #expect(abs(Double(d.sample(SIMD2(2, 5))) - 2) < 0.15)
    let loops = Raster.contours(d, level: 1)
    #expect(loops.count == 1)
    #expect(abs(abs(Geometry2D.signedArea(loops[0])) - 64) < 1.5)
}

// MARK: - Marker toolpaths

func inlayJob(_ origin: InlayOrigin = .board, _ edit: (inout InlayCutSettings) -> Void = { _ in }) -> (FretboardLayout, MarkerSettings, MarkerJob) {
    let (L, m) = markers(.inlayOnly) { $0.inlay.artwork = testArtwork(); $0.inlay.width = 16; $0.inlay.height = 8; $0.inlay.depth = 1.2 }
    var s = InlayCutSettings(); s.origin = origin; s.resolution = 0.02; s.depthPerLayer = 0.4
    edit(&s)
    return (L, m, MarkerToolpath.inlay(layout: L, markers: m, settings: s, cnc: CNCSettings())!)
}

@Test func inlayToolpathStaysInsideThePocketAndAboveTheFloor() {
    let (L, m, job) = inlayJob()
    let s = InlayCutSettings()
    let T = CNCSettings().stockThickness
    let rings = m.inlayRings(L)
    let r = s.cutterDiameter / 2
    var p = job.toolpath.start
    var deepest = Double.infinity
    for mv in job.toolpath.moves {
        let q = mv.to
        let surf = L.topZ(x: q.x, y: q.y) - T
        if q.z < surf - 1e-6 {
            // Below the surface: inside the pocket, at least the cutter radius from the walls, not below the floor.
            let xy = SIMD2(q.x, q.y)
            #expect(Geometry2D.contains(rings: rings, xy))
            let wall = rings.map { Geometry2D.ringDistance($0, xy) }.min()!
            #expect(wall >= r - 0.03)
            #expect(q.z >= surf - m.inlay.depth - 1e-6)
            deepest = min(deepest, q.z - surf)
        }
        _ = p; p = q
    }
    #expect(abs(deepest + m.inlay.depth) < 1e-6)
    #expect(job.toolpath.moves.contains { $0.op == .inlayFinish } && job.toolpath.moves.contains { $0.op == .inlayClear })
}

@Test func inlayEntersOnRampsNotPlunges() {
    let (_, _, job) = inlayJob()
    let s = InlayCutSettings()
    let tanA = tan(s.rampAngle * Double.pi / 180)
    var p = job.toolpath.start
    for mv in job.toolpath.moves {
        let d = mv.to - p
        let xy = (d.x * d.x + d.y * d.y).squareRoot()
        if mv.kind == .cut && d.z < -1e-6 {
            if xy < 1e-6 {
                #expect(-d.z <= 0.2 + 1e-6)                   // only the short drop through already-cut air
            } else {
                // Descent along the path, allowing for the surface curve under the cutter.
                #expect(-d.z / xy <= tanA + 0.02)
            }
            #expect(mv.feed <= s.plungeFeed + 1e-6 || xy > 1e-6)
        }
        p = mv.to
    }
}

@Test func inlayToolpathClearsThePocket() {
    let (L, m, job) = inlayJob()
    let rings = m.inlayRings(L)
    let r = InlayCutSettings().cutterDiameter / 2
    let T = CNCSettings().stockThickness
    // Stamp the cutter along every move at full depth and check what is left inside the pocket.
    let cell = 0.04
    let mask = Raster.rasterize(rings, cell: cell)
    var cut = [Bool](repeating: false, count: mask.values.count)
    var p = job.toolpath.start
    for mv in job.toolpath.moves {
        let a = SIMD2(p.x, p.y), b = SIMD2(mv.to.x, mv.to.y)
        if mv.kind == .cut && mv.to.z < L.topZ(x: b.x, y: b.y) - T - m.inlay.depth + 1e-6 && p.z < L.topZ(x: a.x, y: a.y) - T - m.inlay.depth + 1e-6 {
            let n = max(1, Int(ceil(simd_distance(a, b) / cell)))
            for k in 0...n {
                let c = a + (b - a) * (Double(k) / Double(n))
                let g = (c - mask.origin) / cell
                let rr = Int(ceil(r / cell))
                for j in max(0, Int(g.y) - rr)...min(mask.h - 1, Int(g.y) + rr) {
                    for i in max(0, Int(g.x) - rr)...min(mask.w - 1, Int(g.x) + rr) {
                        if simd_distance(mask.point(Double(i), Double(j)), c) <= r { cut[j * mask.w + i] = true }
                    }
                }
            }
        }
        p = mv.to
    }
    var inside = 0, missed = 0
    for k in mask.values.indices where mask.values[k] > 0.5 {
        inside += 1
        if !cut[k] { missed += 1 }
    }
    let missedArea = Double(missed) * cell * cell
    // Only corner cusps (which the cutter radius can't reach) and raster noise remain.
    #expect(missedArea <= job.uncutArea + 0.04 * Double(inside) * cell * cell)
}

@Test func inlayCentreOriginShiftsTheSameJob() {
    let (L, m, a) = inlayJob(.board)
    let (_, _, b) = inlayJob(.inlayCentre)
    #expect(a.toolpath.moves.count == b.toolpath.moves.count)
    let c = m.inlayCentre(L)
    let dz = CNCSettings().stockThickness - L.topZ(x: c.x, y: c.y)
    var n = 0
    for (ma, mb) in zip(a.toolpath.moves, b.toolpath.moves) where ma.kind == .cut {
        #expect(simd_distance(ma.to - SIMD3(c.x, c.y, -dz), mb.to) < 1e-6)
        n += 1
    }
    #expect(n > 100)
    #expect(b.gcode.contains("CENTRE OF THE INLAY"))
}

@Test func dotJobPecksToTheFloorOfEveryDot() {
    let (L, m) = markers(.dots)
    let cnc = CNCSettings()
    let job = MarkerToolpath.dots(layout: L, markers: m, settings: DotCutSettings(), cnc: cnc)!
    for c in m.dotCentres(L) {
        let zs = job.toolpath.moves.filter { simd_distance(SIMD2($0.to.x, $0.to.y), c) < 1e-6 }.map(\.to.z)
        let floor = L.topZ(x: c.x, y: c.y) - cnc.stockThickness - m.dotDepth
        #expect(abs(zs.min()! - floor) < 1e-9)
    }
    #expect(job.toolpath.moves.allSatisfy { $0.kind == .rapid || $0.feed <= 600 + 1e-9 })
    let g = job.gcode
    #expect(g.contains("SAME AS THE BOARD JOB") && g.contains("G21"))
    // A dot wider than the cutter spirals out to its full size.
    var big = m; big.dotDiameter = 8
    let job2 = MarkerToolpath.dots(layout: L, markers: big, settings: DotCutSettings(), cnc: cnc)!
    let c = big.dotCentres(L)[0]
    let reach = job2.toolpath.moves.map { simd_distance(SIMD2($0.to.x, $0.to.y), c) }.filter { $0 < 5 }.max()!
    #expect(abs(reach - 1) < 1e-6)
    var small = m; small.dotDiameter = 5
    #expect(MarkerToolpath.dots(layout: L, markers: small, settings: DotCutSettings(), cnc: cnc) == nil)
}
