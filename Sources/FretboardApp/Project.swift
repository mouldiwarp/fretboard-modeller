import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FretboardKit

extension UTType {
    static let fretboardProject = UTType(filenameExtension: ProjectFile.fileExtension, conformingTo: .json) ?? .json
}

/// Owns the app's stores and saves/opens them as a project file.
@MainActor
final class ProjectController: ObservableObject {
    let model = ModelStore()
    let toolpath = ToolpathStore()
    let markers = MarkerStore()
    @Published private(set) var url: URL?
    @Published private(set) var saved: ProjectFile

    init() {
        markers.model = model
        saved = ProjectFile()
        saved = snapshot()
    }

    var title: String { url?.deletingPathExtension().lastPathComponent ?? "Untitled" }
    var isDirty: Bool { snapshot() != saved }

    func snapshot() -> ProjectFile {
        var p = ProjectFile()
        p.params = model.params
        p.cnc = toolpath.settings
        p.markers = model.markers
        p.dots = markers.dots
        p.inlay = markers.inlay
        p.trace = markers.trace
        p.image = markers.imageData.map { .init(name: markers.sourceName, png: $0) }
        return p
    }

    private func apply(_ p: ProjectFile) {
        markers.restore(image: p.image, trace: p.trace, dots: p.dots, inlay: p.inlay)
        model.params = p.params
        model.markers = p.markers
        toolpath.settings = p.cnc
        toolpath.clear()
    }

    // MARK: Commands

    func newProject() {
        guard confirmDiscard(action: "starting a new project") else { return }
        apply(ProjectFile())
        url = nil
        saved = snapshot()
    }

    func openWithPanel() {
        guard confirmDiscard(action: "opening another project") else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.fretboardProject, .json]
        guard panel.runModal() == .OK, let u = panel.url else { return }
        load(u)
    }

    /// Opened from Finder: asks about unsaved changes first.
    func open(url u: URL) {
        guard confirmDiscard(action: "opening another project") else { return }
        load(u)
    }

    private func load(_ u: URL) {
        do {
            let p = try ProjectFile.decode(Data(contentsOf: u))
            apply(p)
            url = u
            saved = snapshot()
            NSDocumentController.shared.noteNewRecentDocumentURL(u)
        } catch {
            alert("Could not open \(u.lastPathComponent)", error)
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let u = url else { return saveAs() }
        return write(to: u)
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.fretboardProject]
        panel.nameFieldStringValue = url?.lastPathComponent
            ?? String(format: "Fretboard %.0fmm %d frets.%@", model.params.scaleLength, model.params.fretCount, ProjectFile.fileExtension)
        guard panel.runModal() == .OK, let u = panel.url else { return false }
        return write(to: u)
    }

    private func write(to u: URL) -> Bool {
        let p = snapshot()
        do {
            try p.encoded().write(to: u, options: .atomic)
            url = u; saved = p
            NSDocumentController.shared.noteNewRecentDocumentURL(u)
            return true
        } catch {
            alert("Could not save \(u.lastPathComponent)", error)
            return false
        }
    }

    /// Asks to save unsaved changes. Returns false if the user cancels.
    func confirmDiscard(action: String) -> Bool {
        guard isDirty else { return true }
        let a = NSAlert()
        a.messageText = "Save changes to “\(title)” before \(action)?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Don't Save")
        switch a.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func alert(_ title: String, _ error: Error) {
        let a = NSAlert(error: error)
        a.messageText = title
        a.informativeText = error.localizedDescription
        a.runModal()
    }
}
