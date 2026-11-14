import Foundation

/// Everything the app saves: the board, the board job, the markers and their jobs, and the inlay source image.
public struct ProjectFile: Codable, Equatable, Sendable {
    public struct SourceImage: Codable, Equatable, Sendable {
        public var name: String
        /// PNG data of the grayscale image the inlay was traced from.
        public var png: Data
        public init(name: String, png: Data) { self.name = name; self.png = png }
    }

    public static let currentVersion = 1
    public static let fileExtension = "fretboard"

    public var version = ProjectFile.currentVersion
    public var params = FretboardParameters()
    public var cnc = CNCSettings()
    public var markers = MarkerSettings()
    public var dots = DotCutSettings()
    public var inlay = InlayCutSettings()
    public var trace = InlayTracer.Options()
    public var image: SourceImage?

    public init() {}

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    /// Decodes a project. Settings missing from the file (saved by an older version) take their defaults.
    public static func decode(_ data: Data) throws -> ProjectFile {
        let saved = try JSONSerialization.jsonObject(with: data)
        guard let savedObject = saved as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let v = savedObject["version"] as? Int, v > currentVersion {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "This project was saved by a newer version of Fretboard Modeller."])
        }
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectFile())) as! [String: Any]
        var merged = merge(defaults, savedObject)
        // Projects saved before the Gibson/Fender choice had a free "nut thickness": any extension means Fender.
        if var params = merged["params"] as? [String: Any],
           (savedObject["params"] as? [String: Any])?["fenderNut"] == nil,
           let t = (savedObject["params"] as? [String: Any])?["nutThickness"] as? Double, t > 0 {
            params["fenderNut"] = true
            merged["params"] = params
        }
        return try JSONDecoder().decode(ProjectFile.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    /// Values from `over` replace those in `base`; nested objects are merged key by key.
    static func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let b = base[k] as? [String: Any], let o = v as? [String: Any] { out[k] = merge(b, o) } else { out[k] = v }
        }
        return out
    }
}

/// The user's own starting values for new projects: everything in a project that has a default, plus the
/// Fret Template tool's settings. Saved separately from projects; anything missing takes the factory default.
public struct DefaultsFile: Codable, Equatable, Sendable {
    public var project = ProjectFile()
    public var fretTemplate = FretTemplate.Settings()
    public init() {}

    /// A project's starting point: the defaults, with no image or traced artwork.
    public var template: ProjectFile {
        var p = project
        p.image = nil
        p.markers.inlay.artwork = nil
        return p
    }

    public func encoded() throws -> Data {
        var d = self
        d.project = template
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(d)
    }

    public static func decode(_ data: Data) throws -> DefaultsFile {
        guard let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DefaultsFile())) as! [String: Any]
        let merged = ProjectFile.merge(base, saved)
        return try JSONDecoder().decode(DefaultsFile.self, from: JSONSerialization.data(withJSONObject: merged))
    }
}
