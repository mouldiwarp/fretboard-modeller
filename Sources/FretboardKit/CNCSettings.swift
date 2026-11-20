import Foundation
import simd

/// CNC job settings. Machine coordinates: X/Y match the model (X0 = heel edge, Y0 = board centre line),
/// Z0 = top of the stock, so cutting depths are negative.
public struct CNCSettings: Equatable, Sendable, Codable {
    /// Target machine: sets the G-code dialect (Duet/RRF or GRBL).
    public var machine = Machine.workbee
    /// Flat end mill diameter.
    public var cutterDiameter = 6.0
    /// Flutes on the board cutter, used to calculate feeds from chip load.
    public var cutterFlutes = 2

    // Blank (stock). Board X0 is its heel edge, Y0 its centre line; the blank is centred on Y0.
    /// Stock thickness. The bottom of the board is the bottom of the stock (Z = -stockThickness).
    public var stockThickness = 12.0
    public var stockLength = 520.0
    public var stockWidth = 80.0
    /// Distance from the blank's heel-side edge to the board's heel edge (X0).
    public var stockHeelMargin = 20.0

    // Machine limits. Cutting feeds are per cutter and per stage (see StageFeed), calculated within these.
    /// Fast travel: set it to the machine's configured maximum.
    public var rapidFeed = 2500.0
    /// Fastest cutting feed the machine sustains; calculated feeds are capped here.
    public var maxCuttingFeed = 2500.0
    /// Top spindle speed. 0 = the spindle is controlled by hand: no M3/M5 is written. A GRBL machine's spindle is
    /// always under G-code control, so there 0 means the preset's maximum instead (see `spindleLimitRPM`).
    public var maxSpindleRPM = 0

    /// X/Y and plunge feed for one stage of the board job.
    /// Where Z0 sits for every board-origin job (board, nut slot, dots, inlay): the top of the workpiece
    /// (probed on the stock) or the spoilboard surface (the bottom of the stock).
    public enum ZZero: String, CaseIterable, Codable, Sendable, Identifiable {
        case workpieceTop, spoilboard
        public var id: String { rawValue }
        public var title: String { self == .workpieceTop ? "Workpiece top" : "Spoilboard" }
    }
    public var zZero = ZZero.workpieceTop
    /// Added to every Z the writer outputs (the model works with Z0 at the top of the stock).
    public var zOffset: Double { zZero == .spoilboard ? stockThickness : 0 }
    /// For G-code headers.
    public var zZeroName: String { zZero == .spoilboard ? "SPOILBOARD surface (bottom of the stock)" : "TOP of stock" }

    public struct StageFeed: Equatable, Sendable, Codable {
        public var xy: Double
        public var z: Double
        public init(xy: Double, z: Double) { self.xy = xy; self.z = z }
    }
    public var roughFeed = StageFeed(xy: 2500, z: 1000)
    public var finishFeed = StageFeed(xy: 2000, z: 800)
    public var outlineFeed = StageFeed(xy: 2000, z: 800)

    public var roughDepthPerPass = 1.5
    /// Material left on the surface and outline by the roughing passes.
    public var roughAllowance = 0.5
    public var roughOverlap = 0.20       // stepover = diameter x (1 - overlap)
    public var finishOverlap = 0.50
    /// Clearance height above the stock top used for rapid moves.
    public var safeZ = 5.0
    /// How far past the board edge (beyond the cutter radius) the surface passes extend.
    public var edgeMargin = 1.0
    /// Floor left under the outline roughing trench so the board stays attached until the finishing cut.
    public var outlineFloorAllowance = 0.5
    /// How far the finishing outline cut goes into the spoilboard.
    public var throughCutExtra = 0.2
    /// Width of the roughing trench around the board, as a multiple of the cutter diameter. It is cut as
    /// several loops, outermost first, so the pass next to the board is the last one on each layer.
    public var trenchWidthFactor = 1.5
    /// Tabs left in the final outline cut to hold the board in the surrounding stock.
    public var tabCount = 4
    public var tabWidth = 5.0
    public var tabHeight = 1.5
    /// Climb milling (counter-clockwise around the board, clockwise spindle) or conventional (clockwise).
    public var climbOutline = true
    /// Moves the finishing outline cut this far into the board on every side (mm). Use it to correct a part that
    /// comes out slightly oversize from tool deflection or a cutter that measures under its nominal size.
    /// Positive cuts closer to the board (smaller part); negative leaves more.
    public var outlineTrim = 0.0
    /// Runs the finishing outline cut twice. The second lap removes what the tool pushed away on the first.
    public var outlineSpringPass = false
    /// The Fender-style nut channel, cut with its own bit as a second job.
    public var nutSlot = NutSlotSettings()
    /// Board cutter speed (0 = the machine's maximum). GRBL spindles use S as rpm.
    public var spindleRPM = 0

    public init() { calculateFeeds() }

    /// Feeds for a board-job operation.
    public func stageFeed(_ op: CutOperation) -> StageFeed {
        switch op {
        case .finishSurface: return finishFeed
        case .finishOutline: return outlineFeed
        default: return roughFeed
        }
    }

    /// The speed written with M3: the cutter's speed capped at the machine maximum, or the maximum when the cutter
    /// has none set. 0 when the spindle is manual.
    public var activeSpindleRPM: Int {
        let top = spindleLimitRPM
        return top <= 0 ? 0 : (spindleRPM > 0 ? min(spindleRPM, top) : top)
    }

    /// The top spindle speed in force. On a GRBL machine a file without M3 runs the cutter with the spindle off
    /// (GRBL's spindle button can't start it), so 0 there falls back to the preset's maximum: never a manual spindle.
    public var spindleLimitRPM: Int {
        maxSpindleRPM > 0 ? maxSpindleRPM : (machine.usesGRBL ? machine.defaults.maxSpindleRPM : 0)
    }

    /// Label for the max spindle field: what 0 means on this machine.
    public var maxSpindleTitle: String {
        machine.usesGRBL ? "Max spindle (0 = \(machine.defaults.maxSpindleRPM))" : "Max spindle (0 = manual)"
    }

    public var cutterRadius: Double { cutterDiameter / 2 }
    public var stockMinX: Double { -stockHeelMargin }
    public var stockMaxX: Double { -stockHeelMargin + stockLength }
    public var stockHalfWidth: Double { stockWidth / 2 }
    /// Width of the rough outline trench, measured from the 0.5 mm wall left on the board.
    public var trenchWidth: Double { trenchWidthFactor * cutterDiameter }
    /// Tool-centre offsets of the trench loops from the board outline, outermost first.
    public var trenchLoopOffsets: [Double] {
        let r = cutterRadius
        let dIn = roughAllowance + r
        let dOut = max(dIn, roughAllowance + trenchWidth - r)
        guard dOut - dIn > 1e-6 else { return [dIn] }
        let step = max(1e-3, cutterDiameter * (1 - roughOverlap))
        let n = 1 + Int(ceil((dOut - dIn) / step - 1e-9))
        return (0..<n).map { dOut - (dOut - dIn) * Double($0) / Double(n - 1) }
    }

    /// Thinnest blank that still needs a roughing pass: board thickness + material left + a 0.5 mm cut.
    public func minimumStockThickness(for params: FretboardParameters) -> Double {
        params.thickness + roughAllowance + 0.5
    }

    public func validate(for params: FretboardParameters) -> [String] {
        var e: [String] = []
        if cutterDiameter <= 0 { e.append("Cutter diameter must be positive.") }
        if rapidFeed <= 0 || maxCuttingFeed <= 0 || maxSpindleRPM < 0 { e.append("Machine limits must be positive.") }
        for f in [roughFeed, finishFeed, outlineFeed] where f.xy <= 0 || f.z <= 0 { e.append("Feed rates must be positive."); break }
        if roughDepthPerPass <= 0 { e.append("Roughing depth per pass must be positive.") }
        if roughAllowance < 0 { e.append("Roughing allowance cannot be negative.") }
        if !(0..<1).contains(roughOverlap) || !(0..<1).contains(finishOverlap) {
            e.append("Overlaps must be between 0% and 99%.")
        }
        if stockThickness < minimumStockThickness(for: params) - 1e-9 {
            e.append("Blank must be at least \(String(format: "%.1f", minimumStockThickness(for: params))) mm thick so there is a roughing pass to cut.")
        }
        if safeZ <= 0 { e.append("Safe Z must be above the stock top.") }
        if abs(outlineTrim) > 1 || cutterRadius - outlineTrim <= 0 { e.append("Outline trim must be within ±1 mm.") }
        if params.fenderNut { e.append(contentsOf: NutSlotToolpath.validate(nutSlot, params: params)) }
        if trenchWidthFactor < 1 { e.append("Trench width must be at least one cutter diameter.") }
        if tabCount < 0 || tabWidth <= 0 || tabHeight <= 0 || tabHeight >= stockThickness - 1 {
            e.append("Tab settings are not valid.")
        }
        // The blank must contain the board.
        let layout = FretboardLayout(params)
        let halfMax = layout.taperHalfWidth(at: layout.cornerTangentX)
        if stockLength <= 0 || stockWidth <= 0 { e.append("Blank size must be positive.") }
        if stockMinX > -1 || stockMaxX < layout.xEnd + 1 || stockHalfWidth < halfMax + 1 {
            e.append("The blank is too small for the board (needs at least 1 mm all round).")
        }
        if params.hasSpokeWheelTrussRod {
            let c = params.cutoutWidth / 2, nd = params.cutoutDepth
            for d in trenchLoopOffsets + [cutterRadius] {
                let room = d <= nd ? c - d : c - (2 * d * nd - nd * nd).squareRoot()
                if room <= 0.05 { e.append("The cutout is too narrow for the roughing trench / cutter."); break }
            }
        }
        return e
    }
}

extension CNCSettings {
    /// Non-blocking advice shown next to the settings.
    public func warnings(for params: FretboardParameters) -> [String] {
        var w: [String] = []
        let layout = FretboardLayout(params)
        let need = roughAllowance + trenchWidth
        let halfMax = layout.taperHalfWidth(at: layout.cornerTangentX)
        let sides = [("heel end", -stockMinX), ("nut end", stockMaxX - layout.xEnd), ("sides", stockHalfWidth - halfMax)]
        for (name, m) in sides where m < need {
            w.append(String(format: "Only %.1f mm of blank at the %@; the roughing trench needs %.1f mm and will run off the blank.", m, name, need))
        }
        if params.fenderNut { w.append(contentsOf: NutSlotToolpath.warnings(nutSlot, params: params, cnc: self)) }
        return w
    }
}

public enum CutOperation: Int, CaseIterable, Sendable, Identifiable {
    case roughSurface, roughOutline, finishSurface, finishOutline
    case dotPocket, inlayClear, inlayFinish
    case nutSlot
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .roughSurface: return "Rough surface"
        case .roughOutline: return "Rough outline"
        case .finishSurface: return "Finish surface"
        case .finishOutline: return "Finish outline"
        case .dotPocket: return "Dot pockets"
        case .inlayClear: return "Clear inlay pocket"
        case .inlayFinish: return "Finish inlay walls"
        case .nutSlot: return "Nut slot"
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
