import Foundation
import simd

/// The Fender-style nut channel, cut with its own bit (a compression bit) after a tool change.
public struct NutSlotSettings: Equatable, Codable, Sendable {
    /// Bit diameter = channel width. The channel runs from the zero fret toward the end of the board.
    public var bitDiameter = 4.0
    /// Channel depth below the top of the board on its centre line (the floor is flat).
    public var depth = 3.0
    public var depthPerPass = 1.0
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
    /// Distance the bit runs past each board edge (beyond its own radius), in the cleared trench around the board.
    static let overtravel = 0.5

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
        guard cnc.tabCount > 0, n.depth > 0 else { return [] }
        // The bit runs past the board edges at the channel floor. A tab there is at the bottom of the board.
        let floorAboveBottom = params.thickness - n.depth
        return floorAboveBottom <= cnc.tabHeight + 0.2
            ? ["The nut slot floor is \(String(format: "%.1f", floorAboveBottom)) mm above the board bottom, so the bit runs through the holding tabs."] : []
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
        let yEnd = L.taperHalfWidth(at: L.xNut) + r + overtravel   // clear of the board edge, in the cleared trench

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
        h.append(String(format: "; Channel: X%.3f to X%.3f (zero fret to %.1f mm beyond), Y -%.1f to +%.1f, floor Z%.3f (%.2f mm below the board top on the centre line)",
                        L.xNut, L.xNut + n.bitDiameter, n.bitDiameter, yEnd, yEnd, floor, n.depth))
        h.append(String(format: "; %d passes of up to %.2f mm. Feeds: X/Y %.0f, plunge %.0f mm/min", levels.count, n.depthPerPass, n.feed, n.plungeFeed))
        h.append("; Estimated run time: " + GCodeWriter.formatTime(tp.totalTime))
        return NutSlotJob(toolpath: tp, header: h)
    }
}
