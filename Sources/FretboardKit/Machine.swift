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

    /// Machine limits loaded when this preset is chosen. Cutting feeds are not machine settings: each cutter and
    /// cut stage gets its own, calculated from chip load within these limits.
    public struct Defaults: Equatable, Sendable {
        public var rapidFeed: Double, maxCuttingFeed: Double, maxSpindleRPM: Int
    }

    public var defaults: Defaults {
        switch self {
        // Router on a manual speed dial: no spindle commands (max spindle 0).
        case .workbee: Defaults(rapidFeed: 2500, maxCuttingFeed: 2500, maxSpindleRPM: 0)
        // Linear rails and stiffer steppers; the 1.5 kW VFD spindle runs 6000-24000 rpm.
        case .foxalien: Defaults(rapidFeed: 5000, maxCuttingFeed: 5000, maxSpindleRPM: 24000)
        }
    }

    /// Spindle speed assumed for feed calculations when the spindle is controlled by hand.
    public var typicalRPM: Int { self == .foxalien ? 18000 : 16000 }
}

extension CNCSettings {
    /// Switches machine preset: loads its dialect and limits, then recalculates every cutter's feeds within them.
    public mutating func select(_ m: Machine) {
        machine = m
        let d = m.defaults
        rapidFeed = d.rapidFeed; maxCuttingFeed = d.maxCuttingFeed; maxSpindleRPM = d.maxSpindleRPM
        calculateFeeds()
        calculateNutSlotFeeds()
    }
}
