import SwiftUI
import simd
import FretboardKit

struct ContentView: View {
    @EnvironmentObject var store: ModelStore
    @Environment(\.openWindow) private var openWindow
    @State private var preset: ViewPreset = .iso
    @State private var presetToken = 0
    @State private var showFrets = true
    @State private var showDimensions = true
    @State private var picks: [SIMD3<Double>] = []

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            HStack(alignment: .top, spacing: 10) {
                SetupPanel().frame(width: 304)
                ViewerPanel(preset: $preset, presetToken: $presetToken, picks: $picks,
                            showFrets: showFrets, showDimensions: showDimensions)
                MeasurementsPanel(picks: $picks).frame(width: 272)
            }
            .padding(10)
            BottomBar(preset: $preset, presetToken: $presetToken,
                      showFrets: $showFrets, showDimensions: $showDimensions)
        }
        .background(Backdrop())
        .background(WindowTint())
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1180, minHeight: 760)
        .onAppear { if CommandLine.arguments.contains("--toolpath") { openWindow(id: "toolpath") } }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var store: ModelStore

    var body: some View {
        let ok = store.errors.isEmpty
        HStack(spacing: 10) {
            FretboardGlyph().frame(width: 20, height: 16)
            Text("FRETBOARD MODELLER").font(Theme.headingBold(15)).tracking(2.5).foregroundStyle(Theme.offwhite)
            Text("Parametric fretboard STL").font(Theme.heading(11.5)).foregroundStyle(Theme.dim)
            Spacer()
            LedDot(on: true, color: ok ? Theme.ok : Theme.danger)
            Text(ok ? "MODEL VALID" : "CHECK INPUTS")
                .font(Theme.caption(10.5)).tracking(1)
                .foregroundStyle(ok ? Theme.text.opacity(0.85) : Theme.danger)
            LedReadout(text: String(format: "%.1f mm", store.measurements.overallLength))
            LedReadout(text: "\(store.params.fretCount) FRETS", color: Theme.haze)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Theme.obsidian.opacity(0.88))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.gold.opacity(0.4)).frame(height: 1) }
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @EnvironmentObject var store: ModelStore
    @Environment(\.openWindow) private var openWindow
    @Binding var preset: ViewPreset
    @Binding var presetToken: Int
    @Binding var showFrets: Bool
    @Binding var showDimensions: Bool

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(ViewPreset.allCases) { p in
                    LatchButton(title: p.title.uppercased(), on: p == preset) { preset = p; presetToken += 1 }
                        .frame(width: 66)
                }
            }
            Rectangle().fill(Theme.gold.opacity(0.25)).frame(width: 1, height: 20)
            HStack(spacing: 4) {
                LatchButton(title: "FRETS", on: showFrets, tint: Theme.haze) { showFrets.toggle() }.frame(width: 62)
                LatchButton(title: "DIMENSIONS", on: showDimensions, tint: Theme.haze) { showDimensions.toggle() }.frame(width: 92)
            }
            Spacer()
            Text("Drag to orbit · ⌘ + scroll or pinch to zoom · click two points to measure")
                .font(Theme.heading(10.5)).foregroundStyle(Theme.dim)
            BigLampButton(title: "TOOLPATH", systemImage: "scope", tint: Theme.haze, lit: false,
                          enabled: store.errors.isEmpty) { openWindow(id: "toolpath") }
            BigLampButton(title: "EXPORT STL", systemImage: "square.and.arrow.up",
                          enabled: store.errors.isEmpty) { store.exportSTL() }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Theme.obsidian.opacity(0.88))
        .overlay(alignment: .top) { Rectangle().fill(Theme.gold.opacity(0.4)).frame(height: 1) }
    }
}

// MARK: - Viewer

struct ViewerPanel: View {
    @EnvironmentObject var store: ModelStore
    @Binding var preset: ViewPreset
    @Binding var presetToken: Int
    @Binding var picks: [SIMD3<Double>]
    let showFrets: Bool
    let showDimensions: Bool

    var body: some View {
        ModelViewer(
            mesh: store.mesh,
            layout: store.layout,
            meshVersion: store.meshVersion,
            preset: preset,
            presetToken: presetToken,
            showFrets: showFrets,
            showDimensions: showDimensions,
            picks: $picks
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(1)
        .gmCard()
    }
}

// MARK: - Setup panel

struct SetupPanel: View {
    @EnvironmentObject var store: ModelStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Scale & frets")
                NumberField(title: "Scale length", value: $store.params.scaleLength)
                HStack {
                    Text(String(format: "= %.3f in", store.params.scaleLength / 25.4))
                        .font(Theme.heading(10.5)).foregroundStyle(Theme.dim)
                    Spacer()
                    Menu {
                        Button("25.5\" (Fender)") { store.params.scaleLength = 25.5 * 25.4 }
                        Button("24.75\" (Gibson)") { store.params.scaleLength = 24.75 * 25.4 }
                        Button("25\"") { store.params.scaleLength = 25 * 25.4 }
                        Button("26.5\"") { store.params.scaleLength = 26.5 * 25.4 }
                        Button("27\"") { store.params.scaleLength = 27 * 25.4 }
                    } label: {
                        HStack(spacing: 6) {
                            Text("PRESETS").font(Theme.caption(10)).tracking(0.8)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(Theme.gold)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .gmWell()
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
                LampStepper(title: "Frets", value: $store.params.fretCount, range: 1...40)

                SectionLabel("Width").padding(.top, 4)
                NumberField(title: "At nut (narrow)", value: $store.params.nutWidth)
                NumberField(title: "At last fret (wide)", value: $store.params.lastFretWidth)
                NumberField(title: "Nut thickness", value: $store.params.nutThickness)

                SectionLabel("Surface radius").padding(.top, 4)
                NumberField(title: "At first fret", value: $store.params.radiusFirstFretInches, unit: "in")
                NumberField(title: "At last fret", value: $store.params.radiusLastFretInches, unit: "in")
                HStack(spacing: 6) {
                    let compound = store.params.radiusFirstFretInches != store.params.radiusLastFretInches
                    LedDot(on: true, color: compound ? Theme.haze : Theme.gold, size: 6)
                    Text(compound ? "COMPOUND RADIUS" : "CONSTANT RADIUS")
                        .font(Theme.caption(9.5)).tracking(0.8).foregroundStyle(Theme.dim)
                }
                NumberField(title: "Max thickness", value: $store.params.thickness)

                SectionLabel("Wide end").padding(.top, 4)
                NumberField(title: "Corner diameter", value: $store.params.cornerDiameter)
                Text("Board always extends at least 9 mm past the last fret.")
                    .font(Theme.heading(10.5)).foregroundStyle(Theme.dim)
                LampCheck(text: "Spoke-wheel truss rod", on: $store.params.hasSpokeWheelTrussRod)
                if store.params.hasSpokeWheelTrussRod {
                    NumberField(title: "Extension past last fret", value: $store.params.trussRodExtension)
                    NumberField(title: "Cutout width", value: $store.params.cutoutWidth)
                    NumberField(title: "Cutout depth", value: $store.params.cutoutDepth)
                    NumberField(title: "Cutout corner radius", value: $store.params.cutoutCornerRadius)
                }

                if !store.errors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.errors, id: \.self) { err in
                            HStack(alignment: .top, spacing: 6) {
                                LedDot(on: true, color: Theme.danger, size: 6).padding(.top, 3)
                                Text(err).font(Theme.heading(10.5)).foregroundStyle(Theme.danger)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(14)
        }
        .gmCard()
    }
}

// MARK: - Measurements panel

struct MeasurementsPanel: View {
    @EnvironmentObject var store: ModelStore
    @Binding var picks: [SIMD3<Double>]
    @State private var showFrets = false

    private func row(_ k: String, _ v: String, lit: Bool = false) -> some View {
        HStack(spacing: 6) {
            FieldCaption(k)
            Spacer(minLength: 4)
            Text(v)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(lit ? Theme.amber : Theme.offwhite)
                .shadow(color: lit ? Theme.amber.opacity(0.6) : .clear, radius: 2.5)
                .lineLimit(1)
        }
    }
    private func mm(_ v: Double) -> String { String(format: "%.2f mm", v) }

    var body: some View {
        let m = store.measurements
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Point to point")
                if picks.count == 2 {
                    let d = picks[1] - picks[0]
                    row("Distance", mm(simd_length(d)), lit: true)
                    row("ΔX (length)", mm(abs(d.x)))
                    row("ΔY (width)", mm(abs(d.y)))
                    row("ΔZ (height)", mm(abs(d.z)))
                } else {
                    Text(picks.isEmpty ? "Click a first point on the board." : "Click a second point.")
                        .font(Theme.heading(10.5)).foregroundStyle(Theme.dim)
                }
                if !picks.isEmpty {
                    LatchButton(title: "CLEAR", on: false, tint: Theme.amber) { picks = [] }.frame(width: 70)
                }

                SectionLabel("Board").padding(.top, 6)
                row("Overall length", mm(m.overallLength), lit: true)
                row("Width at heel (x=0)", mm(m.heelWidth))
                row("Width at last fret", mm(m.lastFretWidth), lit: true)
                row("Width at nut", mm(m.nutWidth), lit: true)
                row("Width at narrow end", mm(m.endWidth))
                row("Max thickness", mm(m.maxThickness))
                row("Edge, last fret", mm(m.edgeThicknessLastFret))
                row("Edge, nut", mm(m.edgeThicknessNut))
                row("Radius, first fret", String(format: "%.2f in", m.radiusFirstFretInches))
                row("Radius, last fret", String(format: "%.2f in", m.radiusLastFretInches))
                row("Last fret at x", mm(m.xLastFret))
                row("Nut at x", mm(m.xNut))

                SectionLabel("Model").padding(.top, 6)
                row("Volume", String(format: "%.2f cm³", m.volumeMM3 / 1000))
                row("Bounding box", String(format: "%.1f × %.1f × %.1f", m.boundsSize.x, m.boundsSize.y, m.boundsSize.z))
                row("Triangles", "\(m.triangleCount)")

                SectionLabel("Fret positions").padding(.top, 6)
                LatchButton(title: showFrets ? "HIDE TABLE" : "SHOW TABLE", on: showFrets, tint: Theme.haze) { showFrets.toggle() }
                    .frame(width: 100)
                if showFrets {
                    HStack {
                        FieldCaption("#").frame(width: 26, alignment: .leading)
                        Spacer(); FieldCaption("from nut"); Spacer(); FieldCaption("model x")
                    }
                    ForEach(m.frets) { f in
                        HStack {
                            Text("\(f.number)").frame(width: 26, alignment: .leading)
                            Spacer(); Text(String(format: "%.2f", f.fromNut))
                            Spacer(); Text(String(format: "%.2f", f.x))
                        }
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.offwhite.opacity(0.9))
                    }
                }
            }
            .padding(14)
        }
        .gmCard()
    }
}
