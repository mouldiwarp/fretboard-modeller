import Foundation

/// Fret-slot jig template: marker holes drilled on the centre line at each fret position, measured from the nut.
/// Ported from the standalone "Fret Template Builder" (GRBL-format G-code). Starts the spindle with M3 when the
/// machine settings give a speed (always on a GRBL machine, which can't run its spindle by hand).
public struct FretMark: Identifiable, Equatable {
    public let id: Int
    public let distanceFromNut: Double      // mm
    public let spacingFromPrevious: Double  // mm
}

public enum FretTemplate {
    public enum CommentStyle: String, CaseIterable, Codable, Sendable { case parentheses, semicolon }

    public struct Settings: Equatable, Codable, Sendable {
        public var plungeDepth = 6.0
        public var feed = 200.0
        public var commentStyle = CommentStyle.parentheses
        public init() {}
    }

    /// Positions of fret 0 (nut) ... fretCount, in mm: d(n) = L (1 - 1 / 2^(n/12)).
    public static func positions(scaleLength: Double, fretCount: Int) -> [FretMark] {
        guard scaleLength > 0, fretCount > 0 else { return [] }
        var out: [FretMark] = []
        var previous = 0.0
        for n in 0...fretCount {
            let d = scaleLength * (1 - 1 / pow(2, Double(n) / 12))
            out.append(FretMark(id: n, distanceFromNut: d, spacingFromPrevious: n == 0 ? 0 : d - previous))
            previous = d
        }
        return out
    }

    /// `spindleRPM` 0 = the spindle is run by hand: no M3/M5.
    public static func gcode(scaleLength: Double, marks: [FretMark], settings s: Settings, safeZ: Double,
                             spindleRPM: Int = 0, spinUpSeconds: Int = 3) -> String {
        func c(_ t: String) -> String { s.commentStyle == .parentheses ? "(\(t))" : "; \(t)" }
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        var g = ""
        g += c("Fret Template Builder - GRBL G-code") + "\n"
        g += c("Scale Length: \(f(scaleLength / 25.4)) in / \(f(scaleLength)) mm") + "\n"
        g += c("Fret Count: \(marks.filter { $0.id >= 1 }.count)") + "\n"
        g += "\n"
        g += "G21\nG90\n"
        if spindleRPM > 0 {
            g += "G0 Z\(f(safeZ))\n"
            g += "M3 S\(spindleRPM)\n"
            g += "G4 P\(spinUpSeconds)\n"
        }
        for m in marks {
            g += c("Fret \(m.id)") + "\n"
            g += "G0 Z\(f(safeZ))\n"
            g += "G0 X\(f(m.distanceFromNut)) Y0.000\n"
            g += "G1 Z-\(f(s.plungeDepth)) F\(f(s.feed))\n"
            g += "G0 Z\(f(safeZ))\n"
        }
        g += "G0 Z\(f(safeZ))\n"
        if spindleRPM > 0 { g += "M5\n" }
        g += "M30\n"
        return g
    }
}
