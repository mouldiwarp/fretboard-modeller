import Foundation

/// Chip-load based feed calculator, tuned for hardwood fretboards (ebony, rosewood, maple).
/// feed = chip load x flutes x rpm. The chip load that suits a cutter scales with its diameter.
public enum FeedCalculator {
    /// Target chip load per tooth as a fraction of the cutter diameter (0.084 mm for a 6 mm cutter).
    public static let chipLoadPerDiameter = 0.014
    /// Below this fraction of the target the cutter rubs instead of cutting: heat, burning and a dull edge.
    public static let lowLimit = 0.5
    /// Above this multiple of the target the cutter is overloaded: deflection, heat and breakage.
    public static let highLimit = 1.5
    /// Plunge feed as a fraction of the cutting feed.
    public static let plungeFraction = 0.4
    /// Roughing passes deeper than this fraction of the diameter overload the cutter.
    public static let maxDepthFraction = 0.5

    public static func idealChipLoad(diameter: Double) -> Double { chipLoadPerDiameter * diameter }

    /// Spindle speed to calculate with: the cutter's speed (0 = machine maximum), or the machine's typical speed
    /// when the spindle is manual.
    public static func effectiveRPM(cutterRPM: Int, cnc: CNCSettings) -> (rpm: Int, assumed: Bool) {
        var s = cnc; s.spindleRPM = cutterRPM
        let r = s.activeSpindleRPM
        return r > 0 ? (r, false) : (cnc.machine.typicalRPM, true)
    }

    /// Feed that gives the target chip load, held to what the machine can cut at.
    /// `loadFactor` below 1 backs off for full-width cuts.
    public static func feed(diameter: Double, flutes: Int, cutterRPM: Int, cnc: CNCSettings, loadFactor: Double = 1) -> Double {
        let rpm = effectiveRPM(cutterRPM: cutterRPM, cnc: cnc).rpm
        let raw = idealChipLoad(diameter: diameter) * loadFactor * Double(max(1, flutes)) * Double(rpm)
        return min(cnc.maxCuttingFeed, max(10, (raw / 10).rounded() * 10))
    }

    public static func plunge(forFeed f: Double) -> Double { max(50, (f * plungeFraction / 10).rounded() * 10) }

    public struct Check: Equatable, Sendable {
        public enum Level: Sendable { case ok, low, high }
        public var tool: String
        public var chipLoad: Double
        public var ideal: Double
        public var level: Level
        public var rpm: Int
        public var assumedRPM: Bool

        public var summary: String {
            String(format: "Chip load %.3f mm/tooth (target %.3f) at %d rpm%@", chipLoad, ideal, rpm, assumedRPM ? " (assumed)" : "")
        }

        /// Set only when the chip load is outside the safe range.
        public var alert: String? {
            let tail = assumedRPM ? " Spindle speed is manual, so \(rpm) rpm is assumed; enter the real speed to be sure." : ""
            switch level {
            case .ok: return nil
            case .low:
                return String(format: "%@: chip load %.3f mm/tooth is far below the %.3f target. The cutter will rub rather than cut, building heat, burning the wood and dulling the edge. Raise the feed or lower the spindle speed.", tool, chipLoad, ideal) + tail
            case .high:
                return String(format: "%@: chip load %.3f mm/tooth is far above the %.3f target. Excess load overheats and can deflect or snap the cutter. Lower the feed or raise the spindle speed.", tool, chipLoad, ideal) + tail
            }
        }
    }

    public static func check(tool: String, diameter: Double, flutes: Int, feed: Double, cutterRPM: Int, cnc: CNCSettings) -> Check? {
        guard diameter > 0, flutes > 0, feed > 0 else { return nil }
        let r = effectiveRPM(cutterRPM: cutterRPM, cnc: cnc)
        let chip = feed / (Double(flutes) * Double(r.rpm))
        let ideal = idealChipLoad(diameter: diameter)
        let level: Check.Level = chip < ideal * lowLimit ? .low : (chip > ideal * highLimit ? .high : .ok)
        return Check(tool: tool, chipLoad: chip, ideal: ideal, level: level, rpm: r.rpm, assumedRPM: r.assumed)
    }
}

// MARK: Per-section calculators

extension CNCSettings {

    public var stageFeeds: [(name: String, feed: StageFeed)] {
        [("Roughing", roughFeed), ("Finishing", finishFeed), ("Outline", outlineFeed)]
    }

    /// Chip-load check for each board stage.
    public var boardChecks: [FeedCalculator.Check] {
        stageFeeds.compactMap {
            FeedCalculator.check(tool: "Board cutter, \($0.name.lowercased())", diameter: cutterDiameter, flutes: cutterFlutes,
                                 feed: $0.feed.xy, cutterRPM: spindleRPM, cnc: self)
        }
    }

    /// Cut-depth alerts for the board job (shown in red, alongside the chip-load alerts).
    public var depthAlerts: [String] {
        guard roughDepthPerPass > cutterDiameter * FeedCalculator.maxDepthFraction else { return [] }
        return [String(format: "Board cutter: roughing passes of %.1f mm are deeper than half the %.1f mm cutter, which overloads it and risks deflection and breakage.", roughDepthPerPass, cutterDiameter)]
    }

    /// Sets every board stage's feeds and the roughing depth from the cutter, flutes and spindle speed.
    public mutating func calculateFeeds() {
        func f(_ k: Double) -> StageFeed {
            let xy = FeedCalculator.feed(diameter: cutterDiameter, flutes: cutterFlutes, cutterRPM: spindleRPM, cnc: self, loadFactor: k)
            return StageFeed(xy: xy, z: FeedCalculator.plunge(forFeed: xy))
        }
        roughFeed = f(1.0); finishFeed = f(0.8); outlineFeed = f(0.8)
        roughDepthPerPass = max(0.1, (cutterDiameter * 0.25 * 10).rounded() / 10)
    }

    public var nutCheck: FeedCalculator.Check? {
        FeedCalculator.check(tool: "Nut slot bit", diameter: nutSlot.bitDiameter, flutes: nutSlot.flutes, feed: nutSlot.feed,
                             cutterRPM: nutSlot.spindleRPM > 0 ? nutSlot.spindleRPM : spindleRPM, cnc: self)
    }

    public mutating func calculateNutSlotFeeds() {
        // Full-width slotting: back the load off by 20%, and keep to light passes to avoid lips and splits.
        nutSlot.feed = FeedCalculator.feed(diameter: nutSlot.bitDiameter, flutes: nutSlot.flutes,
                                           cutterRPM: nutSlot.spindleRPM > 0 ? nutSlot.spindleRPM : spindleRPM, cnc: self, loadFactor: 0.8)
        nutSlot.plungeFeed = FeedCalculator.plunge(forFeed: nutSlot.feed)
        nutSlot.depthPerPass = min(0.5, max(0.1, (nutSlot.bitDiameter * 0.25 * 10).rounded() / 10))
    }
}

extension DotCutSettings {
    public func check(_ cnc: CNCSettings) -> FeedCalculator.Check? {
        FeedCalculator.check(tool: "Dot cutter", diameter: cutterDiameter, flutes: flutes, feed: xyFeed, cutterRPM: spindleRPM, cnc: cnc)
    }
    public mutating func calculateFeeds(_ cnc: CNCSettings) {
        xyFeed = FeedCalculator.feed(diameter: cutterDiameter, flutes: flutes, cutterRPM: spindleRPM, cnc: cnc)
        plungeFeed = FeedCalculator.plunge(forFeed: xyFeed)
    }
}

extension InlayCutSettings {
    public func check(_ cnc: CNCSettings) -> FeedCalculator.Check? {
        FeedCalculator.check(tool: "Inlay cutter", diameter: cutterDiameter, flutes: flutes, feed: xyFeed, cutterRPM: spindleRPM, cnc: cnc)
    }
    public mutating func calculateFeeds(_ cnc: CNCSettings) {
        xyFeed = FeedCalculator.feed(diameter: cutterDiameter, flutes: flutes, cutterRPM: spindleRPM, cnc: cnc)
        plungeFeed = FeedCalculator.plunge(forFeed: xyFeed)
    }
}
