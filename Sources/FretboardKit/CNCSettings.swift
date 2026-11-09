import Foundation
import simd

public enum CutterType: String, CaseIterable, Sendable, Identifiable {
    case flat, ball
    public var id: String { rawValue }
    public var title: String { self == .flat ? "Flat end mill" : "Ball nose" }
}

/// CNC job settings. Machine coordinates: X/Y match the model (X0 = heel edge, Y0 = board centre line),
/// Z0 = top of the stock, so cutting depths are negative.
public struct CNCSettings: Equatable, Sendable {
    public var cutter: CutterType = .flat
    public var cutterDiameter = 6.0
    /// Stock thickness. The bottom of the board is the bottom of the stock (Z = -stockThickness).
    public var stockThickness = 12.0

    // WorkBee Z1+ motion limits
    public var xyFeed = 1000.0           // mm/min, X/Y cutting
    public var zFeed = 800.0             // mm/min, Z cutting (plunges)
    /// Fast travel. Default is Ooznest's documented maximum feed rate; set it to your machine's configured maximum.
    public var rapidFeed = 2500.0

    public var roughDepthPerPass = 1.5
    /// Material left on the surface and outline by the roughing passes.
    public var roughAllowance = 0.5
    public var roughOverlap = 0.20       // stepover = diameter x (1 - overlap)
    public var finishOverlap = 0.30
    /// Clearance height above the stock top used for rapid moves.
    public var safeZ = 5.0
    /// How far past the board edge (beyond the cutter radius) the surface passes extend.
    public var edgeMargin = 1.0
    /// Floor left under the outline roughing trench so the board stays attached until the finishing cut.
    public var outlineFloorAllowance = 0.5
    /// How far the finishing outline cut goes into the spoilboard.
    public var throughCutExtra = 0.2
    /// Spindle speed for M3 (0 = no spindle commands, e.g. a manually controlled router).
    public var spindleRPM = 0

    public init() {}

    public var cutterRadius: Double { cutterDiameter / 2 }

    public func validate(for params: FretboardParameters) -> [String] {
        var e: [String] = []
        if cutterDiameter <= 0 { e.append("Cutter diameter must be positive.") }
        if xyFeed <= 0 || zFeed <= 0 || rapidFeed <= 0 { e.append("Feed rates must be positive.") }
        if roughDepthPerPass <= 0 { e.append("Roughing depth per pass must be positive.") }
        if roughAllowance < 0 { e.append("Roughing allowance cannot be negative.") }
        if !(0..<1).contains(roughOverlap) || !(0..<1).contains(finishOverlap) {
            e.append("Overlaps must be between 0% and 99%.")
        }
        if stockThickness < params.thickness + roughAllowance + 0.5 {
            e.append("Stock must be at least \(String(format: "%.1f", params.thickness + roughAllowance + 0.5)) mm thick.")
        }
        if safeZ <= 0 { e.append("Safe Z must be above the stock top.") }
        if params.hasSpokeWheelTrussRod, params.cutoutWidth / 2 <= cutterRadius + roughAllowance {
            e.append("Cutter is too wide for the truss rod cutout.")
        }
        return e
    }
}

public enum CutOperation: Int, CaseIterable, Sendable, Identifiable {
    case roughSurface, roughOutline, finishSurface, finishOutline
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .roughSurface: return "Rough surface"
        case .roughOutline: return "Rough outline"
        case .finishSurface: return "Finish surface"
        case .finishOutline: return "Finish outline"
        }
    }
}

public enum MoveKind: Sendable { case rapid, cut }

public struct Move: Sendable {
    public var kind: MoveKind
    public var op: CutOperation
    public var to: SIMD3<Double>
    /// mm/min
    public var feed: Double
}

public struct Toolpath: Sendable {
    public var start: SIMD3<Double>
    public var moves: [Move]
    public var settings: CNCSettings

    /// Time at the end of each move in seconds, assuming the programmed feed rate throughout.
    public func cumulativeTimes() -> [Double] {
        var t = 0.0
        var p = start
        var out: [Double] = []
        out.reserveCapacity(moves.count)
        for m in moves {
            t += simd_length(m.to - p) / m.feed * 60
            out.append(t)
            p = m.to
        }
        return out
    }

    public var totalTime: Double { cumulativeTimes().last ?? 0 }
    public var cutLength: Double {
        var p = start, l = 0.0
        for m in moves { if m.kind == .cut { l += simd_length(m.to - p) }; p = m.to }
        return l
    }
}
