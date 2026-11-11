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
        let merged = merge(defaults, savedObject)
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
