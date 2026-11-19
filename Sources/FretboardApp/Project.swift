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
    /// Recently opened or saved projects, newest first (files that no longer exist are dropped).
    @Published private(set) var recents: [URL] = []

    private static let recentsKey = "recentProjectPaths"
    private static let recentsLimit = 12

    /// The app keeps its own list (macOS's recent-documents list is not reliably kept for apps without a document
    /// architecture). It is seeded from the system list the first time.
    private var storedRecents: [String] {
        get {
            if let s = UserDefaults.standard.stringArray(forKey: Self.recentsKey) { return s }
            return NSDocumentController.shared.recentDocumentURLs.map(\.path)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.recentsKey) }
    }

    func refreshRecents() {
        recents = storedRecents.map { URL(fileURLWithPath: $0) }.filter {
            $0.pathExtension == ProjectFile.fileExtension && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    func clearRecents() {
        storedRecents = []
        NSDocumentController.shared.clearRecentDocuments(nil)
        refreshRecents()
    }

    private func noteRecent(_ u: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(u)
        let path = u.standardizedFileURL.path
        storedRecents = Array(([path] + storedRecents.filter { $0 != path }).prefix(Self.recentsLimit))
        refreshRecents()
    }

    init() {
        markers.model = model
        saved = ProjectFile()
        apply(AppDefaults.shared.template)
        saved = snapshot()
        refreshRecents()
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
        // An inlay mode with no artwork would show nothing: start from the bundled default, which can be replaced.
        if p.markers.mode.hasInlay && p.image == nil && model.markers.inlay.artwork == nil { markers.useDefaultImage() }
    }

    /// Replaces every setting with the user's defaults, keeping the inlay image and artwork.
    func applyDefaultsKeepingInlay() {
        var p = AppDefaults.shared.template
        p.image = snapshot().image
        p.markers.inlay.artwork = model.markers.inlay.artwork
        apply(p)
    }

    // MARK: Commands

    func newProject() {
        guard confirmDiscard(action: "starting a new project") else { return }
        apply(AppDefaults.shared.template)
        url = nil
        saved = snapshot()
    }

    func openWithPanel() {
        guard confirmDiscard(action: "opening another project") else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.fretboardProject, .json]
        // A "Recent files" pop-up in the dialog: picking one opens it straight away.
        var chosen: URL?
        let picker = RecentPicker(urls: recents) { u in chosen = u; NSApp.stopModal(withCode: .OK) }
        if !recents.isEmpty { panel.accessoryView = picker.view; panel.isAccessoryViewDisclosed = true }
        guard panel.runModal() == .OK, let u = chosen ?? panel.url else { return }
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
            noteRecent(u)
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
            noteRecent(u)
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

/// The "Recent files" pop-up shown in the Open dialog.
@MainActor
final class RecentPicker: NSObject {
    let view: NSView
    private let urls: [URL]
    private let onPick: (URL) -> Void
    private let popup = NSPopUpButton(frame: .zero, pullsDown: true)

    init(urls: [URL], onPick: @escaping (URL) -> Void) {
        self.urls = urls; self.onPick = onPick
        let label = NSTextField(labelWithString: "Recent files:")
        popup.addItem(withTitle: "Choose a recent file…")
        for u in urls {
            let dir = u.deletingLastPathComponent().lastPathComponent
            popup.addItem(withTitle: "\(u.deletingPathExtension().lastPathComponent)  —  \(dir)")
        }
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view = stack
        super.init()
        popup.target = self; popup.action = #selector(picked(_:))
    }

    @objc private func picked(_ s: NSPopUpButton) {
        let i = s.indexOfSelectedItem - 1
        if urls.indices.contains(i) { onPick(urls[i]) }
    }
}
