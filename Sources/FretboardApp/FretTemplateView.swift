import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FretboardKit

/// The fret-slot jig template tool: marker-hole G-code for locating fret slots on a chop saw jig.
struct FretTemplateView: View {
    @EnvironmentObject var store: ModelStore
    @State private var scaleLength = FretboardParameters().scaleLength
    @State private var fretCount = FretboardParameters().fretCount
    @State private var settings = FretTemplate.Settings()
    @State private var synced = false

    private var marks: [FretMark] { FretTemplate.positions(scaleLength: scaleLength, fretCount: fretCount) }
    private var gcode: String { FretTemplate.gcode(scaleLength: scaleLength, marks: marks, settings: settings) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                settingsPanel.frame(width: 290)
                tablePanel.frame(width: 330)
                previewPanel
            }
            .padding(10)
        }
        .onAppear { if !synced { syncFromDesigner(); synced = true } }
    }

    private func syncFromDesigner() {
        scaleLength = store.params.scaleLength
        fretCount = store.params.fretCount
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Scale & frets")
            NumberField(title: "Scale length", value: $scaleLength)
            Text(String(format: "= %.3f in", scaleLength / 25.4)).font(Theme.heading(10.5)).foregroundStyle(Theme.dim)
            LampStepper(title: "Frets", value: $fretCount, range: 1...36)
            LatchButton(title: "USE DESIGNER VALUES", on: false, height: 22) { syncFromDesigner() }
            SectionLabel("Marker holes").padding(.top, 4)
            NumberField(title: "Hole diameter", value: $settings.holeDiameter)
            NumberField(title: "Plunge depth", value: $settings.plungeDepth)
            NumberField(title: "Safe Z", value: $settings.safeZ)
            NumberField(title: "Feed", value: $settings.feed, unit: "mm/min")
            HStack(spacing: 4) {
                LatchButton(title: "( COMMENTS )", on: settings.commentStyle == .parentheses) { settings.commentStyle = .parentheses }
                LatchButton(title: "; COMMENTS", on: settings.commentStyle == .semicolon) { settings.commentStyle = .semicolon }
            }
            Text("Fret 0 (the nut) is X0; holes run along Y0. No spindle commands, so run the drill by hand. Hole diameter is documentation only.")
                .font(Theme.heading(10.5)).foregroundStyle(Theme.dim)
            Spacer(minLength: 0)
            BigLampButton(title: "EXPORT G-CODE", systemImage: "square.and.arrow.up", enabled: !marks.isEmpty) { export() }
        }
        .padding(12).frame(maxHeight: .infinity, alignment: .top).gmCard()
    }

    private var tablePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Fret positions")
            HStack {
                FieldCaption("Fret").frame(width: 40, alignment: .leading)
                FieldCaption("From nut (mm)").frame(maxWidth: .infinity, alignment: .trailing)
                FieldCaption("Spacing (mm)").frame(maxWidth: .infinity, alignment: .trailing)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(marks) { m in
                        HStack {
                            Text("\(m.id)").frame(width: 40, alignment: .leading)
                            Text(String(format: "%.2f", m.distanceFromNut)).foregroundStyle(Theme.amber).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(m.id == 0 ? "–" : String(format: "%.2f", m.spacingFromPrevious)).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(.system(size: 12, design: .monospaced))
                    }
                }
            }
        }
        .padding(12).frame(maxHeight: .infinity, alignment: .top).gmCard()
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("G-code preview")
            ScrollView {
                Text(gcode).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).gmCard()
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "nc") ?? .plainText]
        panel.nameFieldStringValue = String(format: "fret-slot-template-%.1f-%d.nc", scaleLength / 25.4, fretCount)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try gcode.write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
    }
}
