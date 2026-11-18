import Foundation
import simd

/// The Fender-style nut channel, cut with its own bit (a compression bit) after a tool change.
public struct NutSlotSettings: Equatable, Codable, Sendable {
    /// Bit diameter = channel width. The channel runs from the zero fret toward the end of the board.
    public var bitDiameter = 4.0
    /// Channel depth below the top of the board on its centre line (the floor is flat).
    public var depth = 3.0
    /// Light passes leave a clean edge and avoid lips and splits where the bit exits the board sides.
    public var depthPerPass = 0.5
    /// X/Y feed while slotting.
    public var feed = 1200.0
    public var plungeFeed = 400.0
    /// 0 = the same spindle speed as the board job.
    public var spindleRPM = 0
    public init() {}
}

/// The nut channel as its own job: its own G-code file, run after the board job.
public struct NutSlotJob: Sendable {
    public var toolpath: Toolpath
    public var header: [String]
    public var gcode: String { GCodeWriter.write(toolpath, header: header) }
}

public enum NutSlotToolpath {
    /// The bit centre runs this many bit diameters past each board edge, so the bit is fully clear of the board
    /// (a full diameter plus its radius beyond the edge) before it reverses. That avoids lips and splits at the edges.
    static let overtravelDiameters = 1.0

    /// Heaviest pass the warnings accept.
    static let lightPassLimit = 1.0

    /// Distance from the board edge to the bit centre at the end of each pass.
    static func overtravel(_ n: NutSlotSettings) -> Double { n.bitDiameter * overtravelDiameters }

    public static func validate(_ n: NutSlotSettings, params: FretboardParameters) -> [String] {
        var e: [String] = []
        if n.bitDiameter <= 0 || n.depth <= 0 || n.depthPerPass <= 0 || n.feed <= 0 || n.plungeFeed <= 0 {
            e.append("Nut slot settings must be positive.")
        }
        if n.bitDiameter > FretboardParameters.fenderNutExtension - 1 {
            e.append("The nut slot bit is too wide for the 10 mm board extension.")
        }
        if n.depth >= params.thickness - 0.5 { e.append("The nut slot must be at least 0.5 mm shallower than the board is thick.") }
        return e
    }

    /// Advice that does not stop the job.
    public static func warnings(_ n: NutSlotSettings, params: FretboardParameters, cnc: CNCSettings) -> [String] {
        guard n.depth > 0 else { return [] }
        var w: [String] = []
        if n.depthPerPass > lightPassLimit {
            w.append(String(format: "Nut slot passes of %.2f mm are heavy; use %.1f mm or less to avoid lips and splits at the board edges.", n.depthPerPass, lightPassLimit))
        }
        // The bit runs past the board edges at the channel floor. A tab there is at the bottom of the board.
        let floorAboveBottom = params.thickness - n.depth
        if cnc.tabCount > 0, floorAboveBottom <= cnc.tabHeight + 0.2 {
            w.append("The nut slot floor is \(String(format: "%.1f", floorAboveBottom)) mm above the board bottom, so the bit runs through the holding tabs.")
        }
        // The bit ends each pass in the cleared trench (and the blank) beyond the board edge.
        let L = FretboardLayout(params)
        let hw = L.taperHalfWidth(at: L.xNut)
        let room = min(cnc.roughAllowance + cnc.trenchWidth, cnc.stockHalfWidth - hw)
        if overtravel(n) + n.bitDiameter / 2 > room {
            w.append(String(format: "The nut slot bit runs %.1f mm past the board edge but only %.1f mm is cleared there; widen the trench or blank, or use a smaller overtravel bit.", overtravel(n) + n.bitDiameter / 2, room))
        }
        return w
    }

    /// Nil unless the board is Fender-style and the settings are valid.
    public static func generate(layout L: FretboardLayout, settings cnc: CNCSettings) -> NutSlotJob? {
        let n = cnc.nutSlot
        guard L.params.fenderNut, validate(n, params: L.params).isEmpty else { return nil }
        let op = CutOperation.nutSlot
        let r = n.bitDiameter / 2
        let xc = L.xNut + r                                    // channel spans the zero fret to bitDiameter beyond it
        let top = L.params.thickness - cnc.stockThickness      // board top on the centre line, Z0 = stock top
        let floor = top - n.depth
        let yEnd = L.taperHalfWidth(at: L.xNut) + overtravel(n)    // bit fully clear of the board edge, in the cleared trench

        var levels: [Double] = []
        var z = top
        while z > floor + 1e-9 { z = max(floor, z - n.depthPerPass); levels.append(z) }

        let safeZ = cnc.safeZ
        var mv = MarkerToolpath.Mover(pos: SIMD3(0, 0, safeZ), rapidFeed: cnc.rapidFeed, zFeed: n.plungeFeed, safeZ: safeZ)
        var y = -yEnd
        mv.rapid(SIMD3(xc, y, safeZ), op)
        for lz in levels {
            mv.cut(SIMD3(xc, y, lz), op, feed: n.feed)          // plunge in the air beyond the board edge
            y = -y
            mv.cut(SIMD3(xc, y, lz), op, feed: n.feed)          // full-width slotting pass
        }
        mv.retract(safeZ, op)
        mv.rapid(SIMD3(0, 0, safeZ), op)

        let ms = MarkerToolpath.machineSettings(cnc, cutter: n.bitDiameter, xy: n.feed, z: n.plungeFeed, safeZ: safeZ,
                                                rpm: n.spindleRPM > 0 ? n.spindleRPM : cnc.spindleRPM)
        let tp = Toolpath(start: SIMD3(0, 0, safeZ), moves: mv.moves, settings: ms)
        var h: [String] = []
        h.append("; Fretboard Modeller - Fender nut slot - \(cnc.machine.title)")
        h.append("; TOOL CHANGE: fit the \(String(format: "%.1f", n.bitDiameter)) mm compression bit. Same X/Y zero as the board job; re-probe Z0 on the top of the stock.")
        h.append("; Run AFTER the board job so the bit runs out into the cleared trench at both ends.")
        h.append(String(format: "; Channel: X%.3f to X%.3f (zero fret to %.1f mm beyond), bit centre runs to Y -%.1f / +%.1f (at least one bit width past the board edge), floor Z%.3f (%.2f mm below the board top on the centre line)",
                        L.xNut, L.xNut + n.bitDiameter, n.bitDiameter, yEnd, yEnd, floor, n.depth))
        h.append(String(format: "; %d passes of up to %.2f mm. Feeds: X/Y %.0f, plunge %.0f mm/min", levels.count, n.depthPerPass, n.feed, n.plungeFeed))
        h.append("; Estimated run time: " + GCodeWriter.formatTime(tp.totalTime))
        return NutSlotJob(toolpath: tp, header: h)
    }
}
