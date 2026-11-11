import Foundation
import simd

/// A recess cut into the top surface. Rings are in model X/Y (mm), even-odd: the first nesting level is
/// pocket, the next is an island left at the surface, and so on.
public struct Pocket: Sendable, Equatable {
    public enum Floor: Sendable, Equatable {
        /// Flat floor at this model Z.
        case flat(z: Double)
        /// Floor follows the top surface, this far below it.
        case contoured(depth: Double)
    }
    public var rings: [[SIMD2<Double>]]
    public var floor: Floor

    public init(rings: [[SIMD2<Double>]], floor: Floor) {
        self.rings = rings; self.floor = floor
    }

    public func floorZ(_ L: FretboardLayout, _ x: Double, _ y: Double) -> Double {
        switch floor {
        case .flat(let z): return z
        case .contoured(let d): return L.topZ(x: x, y: y) - d
        }
    }
}

/// String positions for locating the double dots: straight lines from the nut to the bridge with
/// compensated spacing (equal gaps between the strings' edges).
public struct StringSpacing: Sendable, Equatable, Codable {
    /// Distance from each board edge at the nut to the centre of the outer E strings.
    public var nutEdgeInset = 3.0
    /// Centre-to-centre span of the outer E strings at the bridge (Les Paul tune-o-matic).
    public var bridgeSpan = 52.4
    /// Gauges in inches, high E (1st) to low E (6th).
    public var gauges: [Double] = [0.010, 0.013, 0.017, 0.026, 0.036, 0.046]
    /// The treble (high E) side is +Y in the model. False (bass at +Y) is a right-handed board: in the
    /// Designer's view (heel left, nut right, +Y at the back) the bass side is at the top, as an audience sees it.
    public var trebleOnPlusY = false

    public init() {}

    /// Centre offsets of strings 1...n across a span measured between the outer string centres.
    /// String 1 (high E) is on the treble side.
    public func offsets(span: Double) -> [Double] {
        let g = gauges.map { $0 * Units.mmPerInch }
        guard g.count >= 2 else { return [0] }
        let metal = g.dropFirst().dropLast().reduce(0, +) + g[0] / 2 + g[g.count - 1] / 2
        let gap = (span - metal) / Double(g.count - 1)
        var c = [span / 2]
        for i in 1..<g.count { c.append(c[i - 1] - g[i - 1] / 2 - gap - g[i] / 2) }
        let sign = trebleOnPlusY ? 1.0 : -1.0
        return c.map { $0 * sign }
    }

    /// Y of string `n` (1-based) at distance `fromNut` along the scale.
    public func y(string n: Int, fromNut d: Double, layout L: FretboardLayout) -> Double {
        let nut = offsets(span: 2 * L.taperHalfWidth(at: L.xNut) - 2 * nutEdgeInset)
        let bridge = offsets(span: bridgeSpan)
        guard n >= 1, n <= nut.count else { return 0 }
        let t = d / L.params.scaleLength
        return nut[n - 1] + (bridge[n - 1] - nut[n - 1]) * t
    }
}

public enum MarkerMode: Int, CaseIterable, Sendable, Identifiable, Codable {
    case none, dots, dotsAndInlay, inlayOnly
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .none: return "None"
        case .dots: return "Dots"
        case .dotsAndInlay: return "Dots + 12th inlay"
        case .inlayOnly: return "12th inlay only"
        }
    }
    public var hasDots: Bool { self == .dots || self == .dotsAndInlay }
    public var hasInlay: Bool { self == .dotsAndInlay || self == .inlayOnly }
}

/// Traced artwork, normalised to its bounding box: x and y run from -0.5 to 0.5 (y up).
public struct InlayArtwork: Sendable, Equatable, Codable {
    public var rings: [[SIMD2<Double>]]
    /// Width / height of the traced artwork.
    public var aspect: Double
    public init(rings: [[SIMD2<Double>]], aspect: Double) { self.rings = rings; self.aspect = aspect }
}

public struct InlayPlacement: Sendable, Equatable, Codable {
    public var artwork: InlayArtwork?
    public var width = 40.0
    public var height = 20.0
    public var lockAspect = true
    /// Fret space the inlay is centred on (the 12th).
    public var fret = 12
    /// Shift from the centre of the fret space: + toward the body.
    public var offsetAlong = 0.0
    /// Shift across the board: + toward the bass side.
    public var offsetAcross = 0.0
    /// Rotation in degrees, counter-clockwise in the plan view (see `MarkerSettings.viewSign`).
    public var rotation = 0.0
    public var mirror = false
    public var depth = 3.0
    public init() {}
}

/// Everything about fret markers that changes the model.
public struct MarkerSettings: Sendable, Equatable, Codable {
    public var mode: MarkerMode = .none
    public var dotDiameter = 6.0
    public var dotDepth = 3.0
    public var dotFrets: [Int] = [3, 5, 7, 9, 12, 15, 17, 19, 21, 24]
    public var doubleDotFrets: [Int] = [12, 24]
    /// Strings the double dots sit under (B and A).
    public var doubleDotStrings = [2, 5]
    public var strings = StringSpacing()
    public var inlay = InlayPlacement()
    /// Minimum material between a pocket and the board edge or another pocket.
    public var edgeMargin = 2.0

    public init() {}

    // MARK: Positions

    /// X of the middle of fret space `n` (between fret wires n-1 and n).
    public static func spaceCentreX(_ L: FretboardLayout, _ n: Int) -> Double {
        (L.fretX(n - 1) + L.fretX(n)) / 2
    }

    /// Dot centres in model coordinates.
    public func dotCentres(_ L: FretboardLayout) -> [SIMD2<Double>] {
        guard mode.hasDots else { return [] }
        var out: [SIMD2<Double>] = []
        for f in dotFrets.sorted() where f >= 1 && f <= L.params.fretCount {
            if mode.hasInlay && f == inlay.fret { continue }
            let x = Self.spaceCentreX(L, f)
            if doubleDotFrets.contains(f) {
                let d = L.fretDistanceFromNut(f - 1) / 2 + L.fretDistanceFromNut(f) / 2
                for s in doubleDotStrings { out.append(SIMD2(x, strings.y(string: s, fromNut: d, layout: L))) }
            } else {
                out.append(SIMD2(x, 0))
            }
        }
        return out
    }

    /// The plan view the inlay is drawn and read in: the board seen from above with the bass side at the top,
    /// as an audience sees it. +1 when bass is +Y (right-handed): the Designer's top view, heel left, nut right.
    /// -1 (left-handed): that view turned half a turn, nut left. View right = viewSign * X, view up = viewSign * Y.
    public var viewSign: Double { strings.trebleOnPlusY ? -1 : 1 }

    /// Centre of the inlay in model coordinates.
    public func inlayCentre(_ L: FretboardLayout) -> SIMD2<Double> {
        // The body is toward -X; the bass side is viewSign * Y.
        SIMD2(Self.spaceCentreX(L, inlay.fret) - inlay.offsetAlong, viewSign * inlay.offsetAcross)
    }

    /// The artwork rings placed on the board (model coordinates, mm).
    public func inlayRings(_ L: FretboardLayout) -> [[SIMD2<Double>]] {
        guard mode.hasInlay, let art = inlay.artwork, inlay.fret >= 1, inlay.fret <= L.params.fretCount else { return [] }
        let c = inlayCentre(L)
        let v = viewSign
        let th = inlay.rotation * Double.pi / 180
        let cs = cos(th), sn = sin(th)
        return art.rings.map { ring in
            ring.map { u -> SIMD2<Double> in
                let a0 = u.x * inlay.width * (inlay.mirror ? -1 : 1), b0 = u.y * inlay.height
                let a = a0 * cs - b0 * sn, b = a0 * sn + b0 * cs     // view coordinates: a right, b up
                return SIMD2(c.x + v * a, c.y + v * b)
            }
        }
    }

    public func dotRing(_ c: SIMD2<Double>) -> [SIMD2<Double>] {
        Geometry2D.circle(center: c, radius: dotDiameter / 2, segments: 72)
    }

    /// All pockets for the model.
    public func pockets(_ L: FretboardLayout) -> [Pocket] {
        var out: [Pocket] = []
        for c in dotCentres(L) {
            out.append(Pocket(rings: [dotRing(c)], floor: .flat(z: L.topZ(x: c.x, y: c.y) - dotDepth)))
        }
        let rings = inlayRings(L)
        if !rings.isEmpty { out.append(Pocket(rings: rings, floor: .contoured(depth: inlay.depth))) }
        return out
    }

    // MARK: Checks

    /// `inlayCutter`: diameter of the inlay cutter. When given, the inlay's clearances are measured on what that
    /// cutter actually removes, so sharp tips it can't reach don't count as being too close to the edge.
    public func validate(_ L: FretboardLayout, inlayCutter: Double? = nil) -> [String] {
        var e: [String] = []
        if mode == .none { return e }
        if mode.hasDots {
            if dotDiameter <= 0 || dotDepth <= 0 { e.append("Dot size and depth must be positive.") }
        }
        if mode.hasInlay {
            if inlay.artwork == nil { e.append("Import or capture an image for the inlay.") }
            if inlay.width <= 0 || inlay.height <= 0 || inlay.depth <= 0 { e.append("Inlay size and depth must be positive.") }
            if inlay.fret < 1 || inlay.fret > L.params.fretCount { e.append("The inlay fret is not on the board.") }
        }
        guard e.isEmpty else { return e }
        var ps = pockets(L)
        if let d = inlayCutter, d > 0, mode.hasInlay, let i = ps.lastIndex(where: { if case .contoured = $0.floor { return true }; return false }) {
            let cut = Raster.cutRegion(ps[i].rings, radius: d / 2, cell: min(0.05, d / 8))
            if cut.isEmpty { ps.remove(at: i) } else { ps[i].rings = cut }
        }
        let minX = L.notchDepth + edgeMargin, maxX = L.xNut - edgeMargin
        var outside = false, tooDeep = false
        for p in ps {
            for r in p.rings { for q in r {
                let hw = L.taperHalfWidth(at: q.x)
                if q.x < minX || q.x > maxX || abs(q.y) > hw - edgeMargin { outside = true }
                if p.floorZ(L, q.x, q.y) < 1.0 { tooDeep = true }
            } }
        }
        if outside { e.append(String(format: "A marker is closer than %.1f mm to the edge of the board.", edgeMargin)) }
        if tooDeep { e.append("A pocket leaves less than 1 mm of board under it.") }
        // Pockets must not touch each other.
        for i in ps.indices {
            for j in ps.indices where j > i {
                if Self.ringsGap(ps[i].rings, ps[j].rings) < edgeMargin {
                    e.append(String(format: "Markers are closer than %.1f mm to each other.", edgeMargin)); return e
                }
            }
        }
        return e
    }

    /// Smallest distance between two sets of rings (0 if they overlap).
    static func ringsGap(_ a: [[SIMD2<Double>]], _ b: [[SIMD2<Double>]]) -> Double {
        let ba = Geometry2D.bounds(a), bb = Geometry2D.bounds(b)
        let gx = max(0, max(ba.min.x - bb.max.x, bb.min.x - ba.max.x))
        let gy = max(0, max(ba.min.y - bb.max.y, bb.min.y - ba.max.y))
        if gx > 10 || gy > 10 { return max(gx, gy) }
        if let p = b.first?.first, Geometry2D.contains(rings: a, p) { return 0 }
        if let p = a.first?.first, Geometry2D.contains(rings: b, p) { return 0 }
        var d = Double.infinity
        for ra in a { for p in ra { for rb in b { d = min(d, Geometry2D.ringDistance(rb, p)) } } }
        return d
    }

    /// Non-blocking advice.
    public func warnings(_ L: FretboardLayout) -> [String] {
        var w: [String] = []
        let rings = inlayRings(L)
        if !rings.isEmpty {
            let b = Geometry2D.bounds(rings)
            let lo = L.fretX(min(L.params.fretCount, inlay.fret + 1)), hi = L.fretX(max(0, inlay.fret - 2))
            if b.min.x < lo - 1e-6 || b.max.x > hi + 1e-6 {
                w.append("The inlay reaches beyond the 11th to 13th fret spaces.")
            }
            let crossed = (0...L.params.fretCount).filter { n in
                let x = L.fretX(n)
                return x > b.min.x && x < b.max.x
            }
            if !crossed.isEmpty {
                w.append("Fret slots \(crossed.map(String.init).joined(separator: ", ")) cross the inlay; the slots will cut through it.")
            }
        }
        return w
    }
}
