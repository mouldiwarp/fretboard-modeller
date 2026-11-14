import Foundation

public enum Units {
    public static let mmPerInch = 25.4
}

/// All user-editable inputs. Lengths are millimetres unless noted.
public struct FretboardParameters: Equatable, Sendable, Codable {
    /// The board always extends at least this far past the last fret, truss rod or not.
    public static let minimumExtension = 9.0

    public var scaleLength: Double = 647.7          // 25.5"
    public var nutWidth: Double = 43.0
    public var lastFretWidth: Double = 56.0
    public var fretCount: Int = 22
    public var hasSpokeWheelTrussRod: Bool = true
    /// Board length past the last fret when a spoke-wheel truss rod is used (at least `minimumExtension`).
    public var trussRodExtension: Double = 9.0
    /// Fender-style nut: the board runs this far past the zero fret so a Fender nut can sit on it. A Gibson-style
    /// board (false) stops at the zero fret.
    public var fenderNut: Bool = false
    public var radiusFirstFretInches: Double = 9.5
    public var radiusLastFretInches: Double = 14.0
    /// Thickest point of the board (on the centre line).
    public var thickness: Double = 7.0
    /// Diameter of the corner rounding on the wide end (9.5mm => 4.75mm radius).
    public var cornerDiameter: Double = 9.5
    public var cutoutWidth: Double = 20.0
    public var cutoutDepth: Double = 5.0
    /// Radius of the two inside corners where the cutout's back wall meets its side walls.
    public var cutoutCornerRadius: Double = 3.0

    public init() {}

    /// How far a Fender-style board extends past the zero fret.
    public static let fenderNutExtension = 10.0
    /// Where the Fender-style nut's second slot sits relative to the zero fret (negative = past it).
    public static let fenderSlotOffset = -4.0

    /// Board length past the zero fret (the nut end): 0 for Gibson, 10 mm for Fender.
    public var nutThickness: Double { fenderNut ? Self.fenderNutExtension : 0 }
    public var cornerRadius: Double { cornerDiameter / 2 }
    public var radiusFirstFret: Double { radiusFirstFretInches * Units.mmPerInch }
    public var radiusLastFret: Double { radiusLastFretInches * Units.mmPerInch }

    /// Human-readable problems; empty when the parameters can be modelled.
    public func validate() -> [String] {
        var e: [String] = []
        if scaleLength <= 0 { e.append("Scale length must be positive.") }
        if nutWidth <= 0 { e.append("Nut width must be positive.") }
        if lastFretWidth < nutWidth {
            e.append("Width at the last fret must be at least the nut width (widest end is at the origin).")
        }
        if !(1...40).contains(fretCount) { e.append("Fret count must be between 1 and 40.") }
        if thickness <= 0 { e.append("Thickness must be positive.") }
        if cornerDiameter < 0 { e.append("Corner diameter cannot be negative.") }
        if radiusFirstFretInches <= 0 || radiusLastFretInches <= 0 {
            e.append("Fretboard radii must be positive.")
        } else {
            let minR = min(radiusFirstFret, radiusLastFret)
            if minR <= lastFretWidth / 2 + 5 {
                e.append("Radius is too small for the board width.")
            } else {
                let sag = minR - (minR * minR - pow(lastFretWidth / 2 + 5, 2)).squareRoot()
                if sag >= thickness { e.append("Thickness is less than the surface drop-off at the edge.") }
            }
        }
        if scaleLength > 0, (1...40).contains(fretCount), FretboardLayout.fretDistance(scale: scaleLength, fret: fretCount) <= 0 {
            e.append("Invalid fret layout.")
        }
        if hasSpokeWheelTrussRod {
            if trussRodExtension < Self.minimumExtension { e.append("Extension past the last fret must be at least \(Int(Self.minimumExtension)) mm.") }
            if cutoutWidth <= 0 || cutoutDepth <= 0 { e.append("Cutout size must be positive.") }
            if cutoutCornerRadius < 0 { e.append("Cutout corner radius cannot be negative.") }
            if cutoutCornerRadius >= cutoutWidth / 2 { e.append("Cutout corner radius must be less than half the cutout width.") }
            if cutoutCornerRadius > cutoutDepth { e.append("Cutout corner radius cannot exceed the cutout depth.") }
            if cutoutWidth / 2 + cornerRadius >= lastFretWidth / 2 {
                e.append("Cutout is too wide for the corner radius and board width.")
            }
        }
        return e
    }
}
