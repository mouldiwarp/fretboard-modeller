import Foundation

/// Derived geometry: where things sit along X and the plan/profile functions.
///
/// Coordinates (mm): X along the board (0 = wide heel edge, + toward the nut),
/// Y across the width centred on 0, Z up (flat bottom at 0).
public struct FretboardLayout: Sendable {
    public let params: FretboardParameters
    public let extensionLength: Double
    public let xLastFret: Double
    public let xNut: Double
    public let xEnd: Double
    /// d(halfWidth)/dx of the straight taper (negative: board narrows toward the nut).
    public let slope: Double

    // Wide-end corner arc (identical on both sides, mirrored in Y).
    public let cornerRadius: Double
    public let cornerCenterY: Double
    public let cornerTangentX: Double
    public let cornerEndAngle: Double

    /// Distance from the nut to fret `n` along the scale.
    public static func fretDistance(scale: Double, fret n: Int) -> Double {
        scale - scale / pow(2.0, Double(n) / 12.0)
    }

    public init(_ p: FretboardParameters) {
        params = p
        extensionLength = p.hasSpokeWheelTrussRod ? max(p.trussRodExtension, FretboardParameters.minimumExtension)
                                                : FretboardParameters.minimumExtension
        let dN = Self.fretDistance(scale: p.scaleLength, fret: p.fretCount)
        xLastFret = extensionLength
        xNut = xLastFret + dN
        xEnd = xNut + p.nutThickness
        let s = dN > 0 ? (p.nutWidth - p.lastFretWidth) / 2 / dN : 0
        slope = s

        let a = p.lastFretWidth / 2 - s * extensionLength   // half-width of the taper at x = 0
        let r = p.cornerRadius
        let sq = (1 + s * s).squareRoot()
        cornerRadius = r
        cornerCenterY = a + s * r - r * sq
        cornerTangentX = r - r * s / sq
        cornerEndAngle = atan2(1, -s)
    }

    // MARK: Fret positions

    public func fretDistanceFromNut(_ n: Int) -> Double {
        Self.fretDistance(scale: params.scaleLength, fret: n)
    }

    /// X coordinate of fret `n` (fret 0 = nut).
    public func fretX(_ n: Int) -> Double { xNut - fretDistanceFromNut(n) }

    // MARK: Plan outline

    /// Half-width of the straight (unrounded) taper, extended through the extension and nut thickness.
    public func taperHalfWidth(at x: Double) -> Double {
        params.lastFretWidth / 2 + slope * (x - xLastFret)
    }

    /// Half-width of the actual outline including the wide-end corner rounding.
    public func outlineHalfWidth(at x: Double) -> Double {
        if cornerRadius > 0 && x < cornerTangentX {
            let dx = x - cornerRadius
            return cornerCenterY + max(0, cornerRadius * cornerRadius - dx * dx).squareRoot()
        }
        return taperHalfWidth(at: x)
    }

    // MARK: Top surface

    /// Radius of the top surface (mm) at `x`: linear between the last-fret and first-fret radii.
    public func surfaceRadius(at x: Double) -> Double {
        let rFirst = params.radiusFirstFret, rLast = params.radiusLastFret
        let x1 = fretX(1)
        guard x1 > xLastFret else { return rFirst }
        let t = min(1, max(0, (x - xLastFret) / (x1 - xLastFret)))
        return rLast + (rFirst - rLast) * t
    }

    /// Height of the top surface. Peaks at `thickness` on the centre line.
    public func topZ(x: Double, y: Double) -> Double {
        let r = surfaceRadius(at: x)
        return params.thickness - (r - (r * r - y * y).squareRoot())
    }

    /// Depth of the notch at the wide end (0 if no truss rod cutout).
    public var notchDepth: Double { params.hasSpokeWheelTrussRod ? params.cutoutDepth : 0 }
    public var notchHalfWidth: Double { params.cutoutWidth / 2 }
    /// Radius of the cutout's inside corners (0 when there is no cutout).
    public var notchFillet: Double {
        params.hasSpokeWheelTrussRod ? max(0, min(params.cutoutCornerRadius, params.cutoutDepth, notchHalfWidth - 0.01)) : 0
    }
    /// Half-width of the flat back wall of the cutout.
    public var notchBackHalfWidth: Double { notchHalfWidth - notchFillet }

    /// Half-width of the removed notch at `x`, following the rounded inside corners.
    /// Beyond the notch depth it stays at the back-wall half-width (the seam of the centre strip).
    public func notchHalfWidth(at x: Double) -> Double {
        let c = notchHalfWidth, r = notchFillet, d = notchDepth
        if x >= d { return c - r }
        if r > 0 && x > d - r {
            let dx = x - (d - r)
            return c - r + max(0, r * r - dx * dx).squareRoot()
        }
        return c
    }
}
