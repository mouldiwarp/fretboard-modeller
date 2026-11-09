import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FretboardKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct FretboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = ModelStore()

    var body: some Scene {
        WindowGroup("Fretboard Modeller") {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 1380, height: 880)
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
        task = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (FretboardLayout, IndexedMesh, Measurements) in
                let l = FretboardLayout(p)
                let m = MeshBuilder.build(l)
                return (l, m, Measurements(layout: l, mesh: m))
            }.value
            if Task.isCancelled { return }
            layout = result.0
            mesh = result.1
            measurements = result.2
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
