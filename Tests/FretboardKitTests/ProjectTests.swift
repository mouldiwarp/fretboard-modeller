import Testing
import Foundation
import simd
@testable import FretboardKit

@Test func projectRoundTripsEverything() throws {
    var p = ProjectFile()
    p.params.scaleLength = 628.65; p.params.fretCount = 24; p.params.hasSpokeWheelTrussRod = false
    p.cnc.stockThickness = 10.5; p.cnc.climbOutline = false
    p.markers.mode = .dotsAndInlay
    p.markers.dotFrets = [3, 5, 7, 9, 12, 24]
    p.markers.strings.gauges = [0.009, 0.011, 0.016, 0.024, 0.032, 0.042]
    p.markers.inlay.artwork = testArtwork()
    p.markers.inlay.rotation = 12.5; p.markers.inlay.mirror = true
    p.dots.peckDepth = 0.75
    p.inlay.origin = .inlayCentre; p.inlay.cutterDiameter = 1.0
    p.trace.invert = true; p.trace.threshold = 0.3
    p.image = .init(name: "logo.png", png: Data([1, 2, 3, 4]))
    let back = try ProjectFile.decode(p.encoded())
    #expect(back == p)
}

@Test func olderProjectsFillInMissingSettings() throws {
    // A file written before some settings existed: only a few keys present.
    let json = #"{"version": 1, "params": {"scaleLength": 610, "fretCount": 21}, "markers": {"mode": 1, "inlay": {"width": 30}}}"#
    let p = try ProjectFile.decode(Data(json.utf8))
    #expect(p.params.scaleLength == 610 && p.params.fretCount == 21)
    #expect(p.params.nutWidth == FretboardParameters().nutWidth)
    #expect(p.markers.mode == .dots && p.markers.inlay.width == 30)
    #expect(p.markers.inlay.depth == 3 && p.markers.dotDiameter == 6)
    #expect(p.cnc == CNCSettings() && p.inlay == InlayCutSettings())
}

@Test func newerProjectsAreRefused() {
    #expect(throws: (any Error).self) { try ProjectFile.decode(Data(#"{"version": 99}"#.utf8)) }
    #expect(throws: (any Error).self) { try ProjectFile.decode(Data("not json".utf8)) }
}

@Test func centreOriginJobDisplaysOnTheBoard() {
    let (L, m, board) = inlayJob(.board)
    let (_, _, centre) = inlayJob(.inlayCentre)
    _ = L; _ = m
    let a = board.displayToolpath.moves, b = centre.displayToolpath.moves
    #expect(a.count == b.count)
    for (x, y) in zip(a, b) where x.kind == .cut { #expect(simd_distance(x.to, y.to) < 1e-6) }
}
