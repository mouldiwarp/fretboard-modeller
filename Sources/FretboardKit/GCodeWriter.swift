import Foundation
import simd

/// G-code for the WorkBee Z1+ (Duet / RepRapFirmware) or the FoxAlien XE-Pro Ultra (GRBL). Units are mm, absolute positioning.
public enum GCodeWriter {
    public static func write(_ t: Toolpath, params: FretboardParameters? = nil) -> String {
        let s = t.settings
        var out: [String] = []
        out.append("; Fretboard Modeller - \(s.machine.title)")
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
        if s.outlineTrim != 0 || s.outlineSpringPass {
            out.append(String(format: "; Finish outline: trim %.3f mm per side, %@", s.outlineTrim, s.outlineSpringPass ? "with spring pass" : "single pass"))
        }
        out.append(String(format: "; Feeds: X/Y %.0f, Z %.0f, rapid %.0f mm/min", s.xyFeed, s.zFeed, s.rapidFeed))
        out.append(String(format: "; Estimated run time: %@", formatTime(t.totalTime)))
        return write(t, header: out)
    }

    /// Writes the moves with the given comment lines (each starting with "; ") as the header.
    /// GRBL machines get (parenthesis) comments on their own lines only, so offline controllers parse them safely.
    public static func write(_ t: Toolpath, header: [String]) -> String {
        let s = t.settings
        let grbl = s.machine.usesGRBL
        func cmt(_ text: String) -> String {
            guard grbl else { return "; " + text }
            let clean = text.replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "(", with: "[").replacingOccurrences(of: ")", with: "]")
            return "(" + String(clean.prefix(70)) + ")"
        }
        func code(_ line: String, _ note: String) -> String { grbl ? line : line.padding(toLength: 11, withPad: " ", startingAt: 0) + " ; " + note }
        var out = header.map { $0.hasPrefix("; ") ? cmt(String($0.dropFirst(2))) : $0 }
        out.append(code("G21", "millimetres"))
        out.append(code("G90", "absolute positioning"))
        out.append(code("G17", "XY plane"))
        if grbl { out.append("G94"); out.append("G54") }
        if s.spindleRPM > 0 {
            out.append("M3 S\(s.spindleRPM)")
            out.append(grbl ? "G4 P\(s.machine.spinUpSeconds)" : "G4 P3000   ; spindle spin-up")
        }
        func rapidZ() -> String { grbl ? "G0 Z" + n(s.safeZ) : String(format: "G0 Z%@ F%@", n(s.safeZ), n(s.rapidFeed)) }
        out.append(rapidZ())

        var cur: SIMD3<Double>? = SIMD3(0, 0, s.safeZ)
        var feed = grbl ? -1 : s.rapidFeed
        var op: CutOperation?
        for m in t.moves {
            if op != m.op {
                op = m.op
                out.append("")
                out.append(cmt("---- \(m.op.title.uppercased()) ----"))
            }
            var line = m.kind == .rapid ? "G0" : "G1"
            if cur == nil || abs(m.to.x - cur!.x) > 5e-4 { line += " X" + n(m.to.x) }
            if cur == nil || abs(m.to.y - cur!.y) > 5e-4 { line += " Y" + n(m.to.y) }
            if cur == nil || abs(m.to.z - cur!.z) > 5e-4 { line += " Z" + n(m.to.z) }
            if line.count <= 2 { continue }                 // no movement
            if grbl {
                // GRBL rapids run at the machine's configured maximum, so F is only for cutting moves.
                if m.kind == .cut && abs(m.feed - feed) > 0.5 { line += " F" + n(m.feed); feed = m.feed }
            } else if abs(m.feed - feed) > 0.5 || m.kind == .rapid { line += " F" + n(m.feed); feed = m.feed }
            out.append(line)
            cur = m.to
        }
        out.append("")
        out.append(cmt("---- END ----"))
        out.append(rapidZ())
        if s.spindleRPM > 0 { out.append("M5") }
        if grbl { out.append("M2") }
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
