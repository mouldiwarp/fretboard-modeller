import Testing
import Foundation
import simd
@testable import FretboardKit

/// The cut region of a shape wide enough everywhere is the shape itself; a needle disappears.
@Test func cutRegionKeepsWideShapesAndDropsNeedles() {
    let sq: [[SIMD2<Double>]] = [[SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 6), SIMD2(0, 6)]]
    let t0 = Date()
    let cut = Raster.cutRegion(sq, radius: 0.45, cell: 0.025)
    print("cutRegion square:", Date().timeIntervalSince(t0), "s")
    #expect(cut.count == 1)
    let a = abs(Geometry2D.signedArea(cut[0]))
    // Rectangle minus what the round cutter leaves in each corner, (1 - pi/4) r^2.
    let expected = 60 - 4 * (1 - Double.pi / 4) * 0.45 * 0.45
    // Walls within about 0.01 mm of the outline (32 mm of perimeter).
    #expect(abs(a - expected) < 0.32 * 0.03 * 32 / 0.32, "area \(a) vs \(expected)")
    let b = Geometry2D.bounds(cut)
    #expect(abs(b.min.x) < 0.03 && abs(b.max.x - 10) < 0.03 && abs(b.max.y - 6) < 0.03)
    // A 0.5 mm-wide needle is narrower than a 0.9 mm cutter.
    let needle: [[SIMD2<Double>]] = [[SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 0.5), SIMD2(0, 0.5)]]
    #expect(Raster.cutRegion(needle, radius: 0.45, cell: 0.025).isEmpty)
}

/// Timing for a full-size inlay (47 x 15 mm box) at the model's resolution (debug build).
@Test func cutRegionIsQuickEnoughForTheModel() {
    let box: [[SIMD2<Double>]] = [[SIMD2(0, 0), SIMD2(15, 0), SIMD2(15, 47), SIMD2(0, 47)]]
    let t0 = Date()
    _ = Raster.cutRegion(box, radius: 0.45, cell: MarkerSettings.modelCutCell)
    let dt = Date().timeIntervalSince(t0)
    print("cutRegion 47x15:", dt, "s")
    #expect(dt < 3)
}
