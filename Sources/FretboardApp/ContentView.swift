import SwiftUI
import simd
import FretboardKit

struct ContentView: View {
    @EnvironmentObject var store: ModelStore
    @State private var preset: ViewPreset = .iso
    @State private var presetToken = 0
    @State private var showFrets = true
    @State private var showDimensions = true
    @State private var picks: [SIMD3<Double>] = []

    var body: some View {
        HStack(spacing: 0) {
            ParameterForm()
                .frame(width: 300)
            Divider()
            ZStack(alignment: .topLeading) {
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
                viewerControls
                    .padding(10)
            }
            Divider()
            MeasurementsPanel(picks: $picks)
                .frame(width: 290)
        }
    }

    private var viewerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ForEach(ViewPreset.allCases) { p in
                    Button(p.title) { preset = p; presetToken += 1 }
                }
            }
            HStack {
                Toggle("Frets", isOn: $showFrets)
                Toggle("Dimensions", isOn: $showDimensions)
            }
            .toggleStyle(.checkbox)
            Text("Drag to orbit · ⌘ + scroll or pinch to zoom · click two points on the board to measure")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct NumberField: View {
    let title: String
    @Binding var value: Double
    var unit: String = "mm"

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: $value, format: .number.precision(.fractionLength(0...3)))
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            Text(unit).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
        }
    }
}

struct ParameterForm: View {
    @EnvironmentObject var store: ModelStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Fretboard").font(.title2.bold())

                GroupBox("Scale & frets") {
                    VStack(spacing: 8) {
                        NumberField(title: "Scale length", value: $store.params.scaleLength)
                        HStack {
                            Text(String(format: "= %.3f in", store.params.scaleLength / 25.4))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu("Presets") {
                                Button("25.5\" (Fender)") { store.params.scaleLength = 25.5 * 25.4 }
                                Button("24.75\" (Gibson)") { store.params.scaleLength = 24.75 * 25.4 }
                                Button("25\"") { store.params.scaleLength = 25 * 25.4 }
                                Button("26.5\"") { store.params.scaleLength = 26.5 * 25.4 }
                                Button("27\"") { store.params.scaleLength = 27 * 25.4 }
                            }.fixedSize()
                        }
                        Stepper(value: $store.params.fretCount, in: 1...40) {
                            Text("Frets: \(store.params.fretCount)")
                        }
                    }
                }

                GroupBox("Width") {
                    VStack(spacing: 8) {
                        NumberField(title: "At nut (narrow)", value: $store.params.nutWidth)
                        NumberField(title: "At last fret (wide)", value: $store.params.lastFretWidth)
                        NumberField(title: "Nut thickness", value: $store.params.nutThickness)
                    }
                }

                GroupBox("Surface radius") {
                    VStack(spacing: 8) {
                        NumberField(title: "At first fret", value: $store.params.radiusFirstFretInches, unit: "in")
                        NumberField(title: "At last fret", value: $store.params.radiusLastFretInches, unit: "in")
                        Text(store.params.radiusFirstFretInches == store.params.radiusLastFretInches
                             ? "Constant radius" : "Compound radius")
                            .font(.caption).foregroundStyle(.secondary)
                        NumberField(title: "Max thickness", value: $store.params.thickness)
                    }
                }

                GroupBox("Wide end") {
                    VStack(spacing: 8) {
                        NumberField(title: "Corner diameter", value: $store.params.cornerDiameter)
                        Text("Board always extends at least 9 mm past the last fret.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Spoke-wheel truss rod", isOn: $store.params.hasSpokeWheelTrussRod)
                        if store.params.hasSpokeWheelTrussRod {
                            NumberField(title: "Extension past last fret", value: $store.params.trussRodExtension)
                            NumberField(title: "Cutout width", value: $store.params.cutoutWidth)
                            NumberField(title: "Cutout depth", value: $store.params.cutoutDepth)
                            NumberField(title: "Cutout corner radius", value: $store.params.cutoutCornerRadius)
                        }
                    }
                }

                if !store.errors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.errors, id: \.self) { Text("⚠︎ " + $0).font(.caption).foregroundStyle(.red) }
                    }
                }

                Button {
                    store.exportSTL()
                } label: {
                    Label("Export STL…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!store.errors.isEmpty)
            }
            .padding(14)
        }
    }
}

struct MeasurementsPanel: View {
    @EnvironmentObject var store: ModelStore
    @Binding var picks: [SIMD3<Double>]

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).monospacedDigit() }.font(.callout)
    }
    private func mm(_ v: Double) -> String { String(format: "%.2f mm", v) }

    var body: some View {
        let m = store.measurements
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Measurements").font(.title3.bold())
                GroupBox("Point-to-point") {
                    VStack(alignment: .leading, spacing: 4) {
                        if picks.count == 2 {
                            let d = picks[1] - picks[0]
                            row("Distance", mm(simd_length(d)))
                            row("ΔX (length)", mm(abs(d.x)))
                            row("ΔY (width)", mm(abs(d.y)))
                            row("ΔZ (height)", mm(abs(d.z)))
                        } else {
                            Text(picks.isEmpty ? "Click a first point on the board."
                                               : "Click a second point.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !picks.isEmpty { Button("Clear") { picks = [] } }
                    }
                }
                GroupBox("Board") {
                    VStack(spacing: 4) {
                        row("Overall length", mm(m.overallLength))
                        row("Width at heel (x=0)", mm(m.heelWidth))
                        row("Width at last fret", mm(m.lastFretWidth))
                        row("Width at nut", mm(m.nutWidth))
                        row("Width at narrow end", mm(m.endWidth))
                        row("Max thickness", mm(m.maxThickness))
                        row("Edge thickness, last fret", mm(m.edgeThicknessLastFret))
                        row("Edge thickness, nut", mm(m.edgeThicknessNut))
                        row("Radius, first fret", String(format: "%.2f in", m.radiusFirstFretInches))
                        row("Radius, last fret", String(format: "%.2f in", m.radiusLastFretInches))
                        row("Last fret at x", mm(m.xLastFret))
                        row("Nut at x", mm(m.xNut))
                        row("Volume", String(format: "%.2f cm³", m.volumeMM3 / 1000))
                        row("Bounding box", String(format: "%.1f × %.1f × %.1f", m.boundsSize.x, m.boundsSize.y, m.boundsSize.z))
                        row("Triangles", "\(m.triangleCount)")
                    }
                }
                DisclosureGroup("Fret positions") {
                    VStack(spacing: 2) {
                        HStack {
                            Text("#").frame(width: 26, alignment: .leading)
                            Spacer(); Text("from nut"); Spacer(); Text("model x")
                        }.font(.caption.bold())
                        ForEach(m.frets) { f in
                            HStack {
                                Text("\(f.number)").frame(width: 26, alignment: .leading)
                                Spacer(); Text(String(format: "%.2f", f.fromNut))
                                Spacer(); Text(String(format: "%.2f", f.x))
                            }.font(.caption).monospacedDigit()
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}
