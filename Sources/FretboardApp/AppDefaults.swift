import SwiftUI
import FretboardKit

/// The user's own default values for every setting, used as the starting point of each new project.
/// Kept in ~/Library/Application Support/Fretboard Modeller/defaults.json; missing values fall back to the
/// factory defaults, so the file can grow as the app does.
@MainActor
final class AppDefaults: ObservableObject {
    static let shared = AppDefaults()

    @Published var file: DefaultsFile { didSet { if file != oldValue { save() } } }
    @Published private(set) var loadError: String?

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Fretboard Modeller/defaults.json")
    }

    private init() {
        file = DefaultsFile()
        if let data = try? Data(contentsOf: Self.url) {
            do { file = try DefaultsFile.decode(data) }
            catch { loadError = "Could not read saved defaults (\(error.localizedDescription)); using the factory defaults." }
        }
    }

    var template: ProjectFile { file.template }
    var isFactory: Bool { file == DefaultsFile() }

    func resetToFactory() { file = DefaultsFile() }

    /// Takes the given project's current values as the new defaults (the inlay image and artwork are not kept).
    func adopt(_ p: ProjectFile) { file.project = p }

    private func save() {
        do {
            let url = Self.url
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.encoded().write(to: url, options: .atomic)
            loadError = nil
        } catch {
            loadError = "Could not save defaults: \(error.localizedDescription)"
        }
    }
}
