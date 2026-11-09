import Foundation
import simd

public struct FretInfo: Sendable, Identifiable {
    public var id: Int { number }
    public let number: Int
    /// Distance from the nut along the board.
    public let fromNut: Double
    /// X coordinate in the model.
    public let x: Double
}

public struct Measurements: Sendable {
    public let overallLength: Double
    public let xNut: Double
    public let xLastFret: Double
    public let heelWidth: Double          // straight taper extrapolated to x = 0
    public let lastFretWidth: Double
    public let nutWidth: Double
    public let endWidth: Double           // at the very end including nut thickness
    public let maxThickness: Double
    public let edgeThicknessLastFret: Double
    public let edgeThicknessNut: Double
    public let radiusFirstFretInches: Double
    public let radiusLastFretInches: Double
    public let volumeMM3: Double
    public let boundsSize: SIMD3<Double>
    public let triangleCount: Int
    public let frets: [FretInfo]

    public init(layout L: FretboardLayout, mesh: IndexedMesh) {
        let p = L.params
        overallLength = L.xEnd
        xNut = L.xNut
        xLastFret = L.xLastFret
        heelWidth = 2 * L.taperHalfWidth(at: 0)
        lastFretWidth = 2 * L.taperHalfWidth(at: L.xLastFret)
        nutWidth = 2 * L.taperHalfWidth(at: L.xNut)
        endWidth = 2 * L.taperHalfWidth(at: L.xEnd)
        maxThickness = p.thickness
        edgeThicknessLastFret = L.topZ(x: L.xLastFret, y: L.taperHalfWidth(at: L.xLastFret))
        edgeThicknessNut = L.topZ(x: L.xNut, y: L.taperHalfWidth(at: L.xNut))
        radiusFirstFretInches = p.radiusFirstFretInches
        radiusLastFretInches = p.radiusLastFretInches
        volumeMM3 = mesh.volume
        boundsSize = mesh.boundsMax - mesh.boundsMin
        triangleCount = mesh.triangleCount
        frets = (1...p.fretCount).map {
            FretInfo(number: $0, fromNut: L.fretDistanceFromNut($0), x: L.fretX($0))
        }
    }
}
