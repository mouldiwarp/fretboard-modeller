import Foundation

/// The CNC the G-code is written for. Each machine fixes the G-code dialect and supplies starting feeds and
/// spindle speed; all of them can still be changed per project (and in the Defaults page).
public enum Machine: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Ooznest WorkBee Z1+, Duet / RepRapFirmware.
    case workbee
    /// FoxAlien XE-Pro Ultra (800 x 800), GRBL, 1.5 kW air-cooled VFD spindle, run from USB or the offline controller.
    case foxalien

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .workbee: "Ooznest WorkBee Z1+"
        case .foxalien: "FoxAlien XE-Pro Ultra"
        }
    }

    public var controller: String {
        switch self {
        case .workbee: "Duet / RepRapFirmware"
        case .foxalien: "GRBL"
        }
    }

    /// One-line title used in G-code headers and the UI.
    public var title: String { "\(name) (\(controller))" }

    public var usesGRBL: Bool { self == .foxalien }

    /// Seconds to wait after M3 for the spindle to reach speed. A 1.5 kW VFD spindle takes a few seconds.
    public var spinUpSeconds: Int { self == .foxalien ? 5 : 3 }

    /// Starting values applied when this machine is chosen. The user can change every one of them afterwards.
    public struct Defaults: Equatable, Sendable {
        public var xyFeed: Double, zFeed: Double, rapidFeed: Double, spindleRPM: Int
    }

    public var defaults: Defaults {
        switch self {
        case .workbee: Defaults(xyFeed: 1000, zFeed: 800, rapidFeed: 2500, spindleRPM: 0)
        // Linear rails, stiffer steppers and a VFD spindle allow more than the WorkBee. These are conservative
        // starting points for a 6 mm flat end mill in hardwood; the spindle runs 6000-24000 rpm.
        case .foxalien: Defaults(xyFeed: 2000, zFeed: 800, rapidFeed: 5000, spindleRPM: 18000)
        }
    }
}

extension CNCSettings {
    /// Switches machine and loads that machine's feeds and spindle speed.
    public mutating func select(_ m: Machine) {
        machine = m
        let d = m.defaults
        xyFeed = d.xyFeed; zFeed = d.zFeed; rapidFeed = d.rapidFeed; spindleRPM = d.spindleRPM
    }
}
