import Foundation
import simd

/// G-code for the Ooznest WorkBee Z1+ (Duet / RepRapFirmware dialect). Units are mm, absolute positioning.
public enum GCodeWriter {
    public static func write(_ t: Toolpath, params: FretboardParameters? = nil) -> String {
        let s = t.settings
        var out: [String] = []
        out.append("; Fretboard Modeller - WorkBee Z1+ (Duet / RepRapFirmware)")
        if let p = params {
            out.append(String(format: "; Scale %.1f mm, %d frets, nut %.2f mm, last fret %.2f mm, thickness %.2f mm",
                              p.scaleLength, p.fretCount, p.nutWidth, p.lastFretWidth, p.thickness))
        }
        out.append("; Work origin: X0 = heel edge of board, Y0 = board centre line, Z0 = TOP of stock")
        out.append(String(format: "; Stock %.2f mm thick. Board bottom is the stock bottom (Z%.2f)", s.stockThickness, -s.stockThickness))
        out.append(String(format: "; Cutter: %.2f mm flat end mill", s.cutterDiameter))
        out.append(String(format: "; Blank: %.1f x %.1f mm, heel edge of board is %.1f mm in from the blank's end; blank centred on Y0",
                          s.stockLength, s.stockWidth, s.stockHeelMargin))
        out.append(String(format: "; Outline direction: %@; %d tabs", s.climbOutline ? "climb (counter-clockwise)" : "conventional (clockwise)", s.tabCount))
        out.append(String(format: "; Feeds: X/Y %.0f, Z %.0f, rapid %.0f mm/min", s.xyFeed, s.zFeed, s.rapidFeed))
        out.append(String(format: "; Estimated run time: %@", formatTime(t.totalTime)))
        return write(t, header: out)
    }

    /// Writes the moves with the given comment lines (each starting with "; ") as the header.
    public static func write(_ t: Toolpath, header: [String]) -> String {
        let s = t.settings
        var out = header
        out.append("G21        ; millimetres")
        out.append("G90        ; absolute positioning")
        out.append("G17        ; XY plane")
        if s.spindleRPM > 0 {
            out.append("M3 S\(s.spindleRPM)")
            out.append("G4 P3000   ; spindle spin-up")
        }
        out.append(String(format: "G0 Z%@ F%@", n(s.safeZ), n(s.rapidFeed)))

        var cur: SIMD3<Double>? = SIMD3(0, 0, s.safeZ)
        var feed = s.rapidFeed
        var op: CutOperation?
        for m in t.moves {
            if op != m.op {
                op = m.op
                out.append("")
                out.append("; ---- \(m.op.title.uppercased()) ----")
            }
            var line = m.kind == .rapid ? "G0" : "G1"
            if cur == nil || abs(m.to.x - cur!.x) > 5e-4 { line += " X" + n(m.to.x) }
            if cur == nil || abs(m.to.y - cur!.y) > 5e-4 { line += " Y" + n(m.to.y) }
            if cur == nil || abs(m.to.z - cur!.z) > 5e-4 { line += " Z" + n(m.to.z) }
            if line.count <= 2 { continue }                 // no movement
            if abs(m.feed - feed) > 0.5 || m.kind == .rapid { line += " F" + n(m.feed); feed = m.feed }
            out.append(line)
            cur = m.to
        }
        out.append("")
        out.append("; ---- END ----")
        out.append(String(format: "G0 Z%@ F%@", n(s.safeZ), n(s.rapidFeed)))
        if s.spindleRPM > 0 { out.append("M5") }
        return out.joined(separator: "\n") + "\n"
    }

    static func n(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    public static func formatTime(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return t >= 3600 ? String(format: "%dh %02dm %02ds", t / 3600, (t % 3600) / 60, t % 60)
                         : String(format: "%dm %02ds", t / 60, t % 60)
    }
}
