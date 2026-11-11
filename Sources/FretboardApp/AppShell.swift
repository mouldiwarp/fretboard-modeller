import SwiftUI
import FretboardKit

extension Notification.Name {
    static let selectTab = Notification.Name("FretboardModeller.selectTab")
}

/// The app's tools. To add a tool, add a case here and fill in its title, icon, shortcut,
/// content and (optionally) status; the shell, tab bar and View menu pick it up automatically.
enum AppTab: String, CaseIterable, Identifiable {
    case designer, markers, toolpath, template

    var id: String { rawValue }

    var title: String {
        switch self {
        case .designer: "Designer"
        case .markers: "Markers"
        case .toolpath: "Toolpath"
        case .template: "Fret Template"
        }
    }

    var subtitle: String {
        switch self {
        case .designer: "Parametric fretboard STL"
        case .markers: "Fret dots & 12th fret inlay"
        case .toolpath: "WorkBee Z1+ · G-code"
        case .template: "Chop-saw jig · marker-hole G-code"
        }
    }

    var systemImage: String {
        switch self {
        case .designer: "cube.transparent"
        case .markers: "circle.grid.2x1"
        case .toolpath: "scope"
        case .template: "ruler"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .designer: "1"
        case .markers: "2"
        case .toolpath: "3"
        case .template: "4"
        }
    }

    /// Whether the tab can be opened for the current model.
    @MainActor func isEnabled(_ store: ModelStore) -> Bool {
        switch self {
        case .toolpath: store.errors.isEmpty
        default: true
        }
    }

    @ViewBuilder var content: some View {
        switch self {
        case .designer: DesignerView()
        case .markers: MarkersView()
        case .toolpath: ToolpathView()
        case .template: FretTemplateView()
        }
    }

    /// Live readouts shown at the right of the header while the tab is selected.
    @ViewBuilder var status: some View {
        switch self {
        case .designer: DesignerStatus()
        case .markers: MarkersStatus()
        case .toolpath: ToolpathStatus()
        case .template: EmptyView()
        }
    }
}

/// The single window: a header with the tab bar, and the selected tool below it.
/// Tabs are created the first time they are opened and then kept, so each keeps its
/// camera, settings and results while you work in another tab.
struct AppShell: View {
    @EnvironmentObject var store: ModelStore
    @EnvironmentObject var project: ProjectController
    // Observed so the unsaved-changes marker updates when their settings change.
    @EnvironmentObject var toolpathStore: ToolpathStore
    @EnvironmentObject var markerStore: MarkerStore
    @State private var selection: AppTab = AppShell.launchTab
    @State private var opened: Set<AppTab> = [AppShell.launchTab]

    /// `--toolpath` or `--inlay-image <file>` start on that tab (development aids).
    static var launchTab: AppTab {
        let a = CommandLine.arguments
        return a.contains("--toolpath") ? .toolpath : (a.contains("--inlay-image") ? .markers : .designer)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                ForEach(AppTab.allCases) { tab in
                    if opened.contains(tab) {
                        let active = tab == selection
                        tab.content
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                            .accessibilityHidden(!active)
                    }
                }
            }
        }
        .background(Backdrop())
        .background(WindowTint())
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .navigationTitle(project.title + (project.isDirty ? " — Edited" : ""))
        .frame(minWidth: 1500, minHeight: 760)
        .onReceive(NotificationCenter.default.publisher(for: .selectTab)) { n in
            if let tab = n.object as? AppTab { select(tab) }
        }
        .onChange(of: store.errors.isEmpty) { valid in
            // Don't strand the user on a tab that needs a valid model.
            if !valid, !selection.isEnabled(store) { select(.designer) }
        }
    }

    private func select(_ tab: AppTab) {
        guard tab.isEnabled(store) else { return }
        opened.insert(tab)
        selection = tab
    }

    private var header: some View {
        HStack(spacing: 14) {
            FretboardGlyph().frame(width: 20, height: 16)
            Text("FRETBOARD MODELLER").font(Theme.headingBold(15)).tracking(2.5).foregroundStyle(Theme.offwhite)
            HStack(spacing: 4) {
                Text(project.title).font(Theme.heading(11.5)).foregroundStyle(Theme.text.opacity(0.85)).lineLimit(1)
                if project.isDirty { LedDot(on: true, color: Theme.amber, size: 6).help("Unsaved changes (⌘S to save)") }
            }
            .frame(maxWidth: 160, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(AppTab.allCases) { tab in
                    TabButton(tab: tab, selected: tab == selection, enabled: tab.isEnabled(store)) { select(tab) }
                }
            }
            Text(selection.subtitle).font(Theme.heading(11.5)).foregroundStyle(Theme.dim)
            Spacer()
            selection.status
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Theme.obsidian.opacity(0.88))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.gold.opacity(0.4)).frame(height: 1) }
    }
}

private struct TabButton: View {
    let tab: AppTab
    let selected: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.systemImage).font(.system(size: 11))
                Text(tab.title.uppercased()).font(Theme.caption(10.5)).tracking(0.8).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 24)
            .foregroundStyle(selected ? Theme.obsidian : Theme.text.opacity(enabled ? 0.8 : 0.3))
            .background(LampFace(on: selected, tint: Theme.accent))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? tab.title : "\(tab.title) needs a valid model. Fix the Designer inputs first.")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MarkersStatus: View {
    @EnvironmentObject var store: ModelStore

    var body: some View {
        let ok = store.markerErrors.isEmpty
        HStack(spacing: 10) {
            LedDot(on: store.markers.mode != .none, color: ok ? Theme.ok : Theme.danger)
            Text(store.markers.mode == .none ? "NO MARKERS" : (ok ? store.markers.mode.title.uppercased() : "CHECK MARKERS"))
                .font(Theme.caption(10.5)).tracking(1).foregroundStyle(ok ? Theme.text.opacity(0.85) : Theme.danger)
            LedReadout(text: "\(store.pocketCount) POCKETS", color: Theme.haze)
        }
    }
}
