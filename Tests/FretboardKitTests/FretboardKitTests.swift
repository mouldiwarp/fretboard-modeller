import Testing
import Foundation
import simd
@testable import FretboardKit

func make(_ edit: (inout FretboardParameters) -> Void = { _ in }) -> (FretboardLayout, IndexedMesh) {
    var p = FretboardParameters()
    edit(&p)
    let l = FretboardLayout(p)
    return (l, MeshBuilder.build(l))
}

@Test func fretPositions() {
    let L = 647.7
    #expect(abs(FretboardLayout.fretDistance(scale: L, fret: 12) - L / 2) < 1e-9)
    #expect(abs(FretboardLayout.fretDistance(scale: 648, fret: 1) - 36.37) < 0.02)
}

@Test func layoutWithAndWithoutTrussRod() {
    var p = FretboardParameters()
    p.hasSpokeWheelTrussRod = true
    let a = FretboardLayout(p)
    #expect(a.xLastFret == 9)
    p.hasSpokeWheelTrussRod = false
    let b = FretboardLayout(p)
    #expect(b.xLastFret == 9)   // minimum extension applies without a truss rod
    #expect(abs(a.xNut - b.xNut) < 1e-9)
    p.hasSpokeWheelTrussRod = true
    p.trussRodExtension = 12
    #expect(FretboardLayout(p).xLastFret == 12)
    p.trussRodExtension = 5
    #expect(!p.validate().isEmpty)
}

@Test func widthsMatchInputs() {
    let (l, _) = make { $0.hasSpokeWheelTrussRod = true }
    #expect(abs(2 * l.taperHalfWidth(at: l.xLastFret) - 56) < 1e-9)
    #expect(abs(2 * l.taperHalfWidth(at: l.xNut) - 43) < 1e-9)
}

@Test func profileThicknessAndCompoundRadius() {
    let (l, _) = make()
    #expect(abs(l.topZ(x: 100, y: 0) - 7) < 1e-12)
    let r = 9.5 * 25.4
    #expect(abs(l.surfaceRadius(at: l.fretX(1)) - r) < 1e-9)
    #expect(abs(l.surfaceRadius(at: l.xLastFret) - 14 * 25.4) < 1e-9)
    let y = 20.0
    let sag = r - (r * r - y * y).squareRoot()
    #expect(abs(l.topZ(x: l.fretX(1), y: y) - (7 - sag)) < 1e-9)
}

@Test(arguments: [false, true])
func meshIsWatertightWithPositiveVolume(truss: Bool) {
    let (_, m) = make { $0.hasSpokeWheelTrussRod = truss }
    #expect(m.isWatertight)
    #expect(m.volume > 0)
}

@Test func constantRadiusAndFewFrets() {
    let (_, m) = make { $0.radiusLastFretInches = 9.5; $0.fretCount = 1; $0.hasSpokeWheelTrussRod = true }
    #expect(m.isWatertight)
}

@Test func boundsAndOrientation() {
    let (l, m) = make { $0.hasSpokeWheelTrussRod = true }
    #expect(abs(m.boundsMin.x) < 1e-9)
    #expect(abs(m.boundsMax.x - l.xEnd) < 1e-6)
    #expect(abs(m.boundsMax.z - 7) < 1e-9)
    #expect(abs(m.boundsMin.z) < 1e-9)
    // widest at origin end, narrowest at +X
    #expect(l.outlineHalfWidth(at: 20) > l.outlineHalfWidth(at: l.xEnd))
    // max Y extent is where the corner arc meets the taper
    #expect(m.boundsMax.y <= l.taperHalfWidth(at: 0) + 1e-6)
    #expect(m.boundsMax.y > l.taperHalfWidth(at: l.xLastFret))
}

@Test func cornerRadiusIsDiameterHalf() {
    let (l, _) = make()
    // On the heel edge the outline is inset from the straight taper by r(1 - ...) ≈ r-ish.
    let inset = l.taperHalfWidth(at: 0) - l.outlineHalfWidth(at: 0)
    #expect(inset > 4.0 && inset < 5.0)
}

@Test func cutoutHasRoundedInsideCorners() {
    let (l, m) = make { $0.hasSpokeWheelTrussRod = true }
    #expect(l.params.cutoutWidth == 20 && l.params.cutoutDepth == 5 && l.params.cutoutCornerRadius == 3)
    // Nothing on the heel edge inside the cutout width.
    #expect(!m.vertices.contains { abs($0.x) < 1e-9 && abs($0.y) < 10 - 1e-6 })
    // Flat back wall at x = 5 spans only |y| <= 7 (10 - 3).
    #expect(m.vertices.contains { abs($0.x - 5) < 1e-9 && abs($0.y - 7) < 1e-9 })
    #expect(!m.vertices.contains { abs($0.x - 5) < 1e-9 && abs($0.y - 9) < 1e-6 })
    // Side walls run straight at |y| = 10 until x = 2, then arc round to the back wall.
    #expect(m.vertices.contains { abs($0.x - 2) < 1e-9 && abs($0.y - 10) < 1e-9 })
    let s = 3 * (0.5).squareRoot()
    #expect(m.vertices.contains { abs($0.x - (2 + s)) < 1e-6 && abs($0.y - (7 + s)) < 1e-6 })
    #expect(m.isWatertight)
}

@Test func cutoutCornerRadiusZeroGivesSharpCorners() {
    let (_, m) = make { $0.hasSpokeWheelTrussRod = true; $0.cutoutCornerRadius = 0 }
    #expect(m.isWatertight)
    #expect(m.vertices.contains { abs($0.x - 5) < 1e-9 && abs($0.y - 10) < 1e-9 })
}

@Test func invalidCutoutCornerRadiusIsRejected() {
    var p = FretboardParameters()
    p.hasSpokeWheelTrussRod = true
    p.cutoutCornerRadius = 12
    #expect(!p.validate().isEmpty)
}

@Test func stlSize() {
    let (_, m) = make()
    let d = STLWriter.binary(m)
    #expect(d.count == 84 + 50 * m.triangleCount)
}
