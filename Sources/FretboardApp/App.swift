import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FretboardKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var project: ProjectController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { project?.confirmDiscard(action: "quitting") ?? true } ? .terminateNow : .terminateCancel
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        MainActor.assumeIsolated { project?.open(url: url) }
    }
}

@main
struct FretboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var project = ProjectController()

    var body: some Scene {
        // A single window: the tools are tabs inside it (see AppShell.swift).
        Window("Fretboard Modeller", id: "main") {
            AppShell()
                .environmentObject(project)
                .environmentObject(project.model)
                .environmentObject(project.toolpath)
                .environmentObject(project.markers)
                .onAppear { delegate.project = project }
        }
        .defaultSize(width: 1560, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { project.newProject() }.keyboardShortcut("n")
                Button("Open…") { project.openWithPanel() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { project.save() }.keyboardShortcut("s")
                Button("Save As…") { project.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                ForEach(AppTab.allCases) { tab in
                    Button(tab.title) { NotificationCenter.default.post(name: .selectTab, object: tab) }
                        .keyboardShortcut(tab.shortcut, modifiers: .command)
                }
            }
        }
    }
}

/// Owns the parameters and the generated model; rebuilds off the main thread, debounced.
@MainActor
final class ModelStore: ObservableObject {
    @Published var params = FretboardParameters() { didSet { if params != oldValue { scheduleRebuild() } } }
    @Published private(set) var layout: FretboardLayout
    @Published private(set) var mesh: IndexedMesh
    @Published private(set) var measurements: Measurements
    @Published private(set) var errors: [String] = []
    /// Fret markers. Valid markers are cut into the model and its STL.
    @Published var markers = MarkerSettings() { didSet { if markers != oldValue { scheduleRebuild() } } }
    @Published private(set) var markerErrors: [String] = []
    @Published private(set) var markerWarnings: [String] = []
    /// Diameter of the inlay cutter: the inlay's clearance checks use what it can actually cut.
    @Published var inlayCutter: Double? { didSet { if inlayCutter != oldValue { scheduleRebuild() } } }
    /// Number of pockets in the current mesh.
    @Published private(set) var pocketCount = 0
    /// Increments each time a new mesh is applied, so the viewer knows to rebuild.
    @Published private(set) var meshVersion = 0

    private var task: Task<Void, Never>?

    init() {
        let p = FretboardParameters()
        let l = FretboardLayout(p)
        let m = MeshBuilder.build(l)
        layout = l
        mesh = m
        measurements = Measurements(layout: l, mesh: m)
    }

    private func scheduleRebuild() {
        task?.cancel()
        let p = params
        let errs = p.validate()
        errors = errs
        guard errs.isEmpty else { return }
        let mk = markers, cutter = inlayCutter
        markerWarnings = mk.warnings(FretboardLayout(p))
        task = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            // The inlay pocket is what the inlay cutter actually removes (tracing it takes a moment), so the
            // checks and the mesh are both worked out off the main thread.
            let result = await Task.detached(priority: .userInitiated) { () -> (FretboardLayout, IndexedMesh, Measurements, [String], Int) in
                let l = FretboardLayout(p)
                let all = mk.mode == .none ? [] : mk.pockets(l, inlayCutter: cutter)
                let errs = mk.validate(l, inlayCutter: cutter, pockets: all)
                let pockets = errs.isEmpty ? all : []
                let m = MeshBuilder.build(l, pockets: pockets)
                return (l, m, Measurements(layout: l, mesh: m), errs, pockets.count)
            }.value
            if Task.isCancelled { return }
            layout = result.0
            mesh = result.1
            measurements = result.2
            markerErrors = result.3
            pocketCount = result.4
            meshVersion += 1
        }
    }

    func exportSTL() {
        guard errors.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "stl") ?? .data]
        panel.nameFieldStringValue = String(format: "fretboard_%.0fmm_%dfrets.stl", params.scaleLength, params.fretCount)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try STLWriter.binary(mesh).write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
