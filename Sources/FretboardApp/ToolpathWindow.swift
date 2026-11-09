import SwiftUI
import simd
import FretboardKit

struct ToolpathWindow: View {
    @EnvironmentObject var store: ModelStore
    @EnvironmentObject var tp: ToolpathStore
    @State private var preset: ViewPreset = .iso
    @State private var presetToken = 0
    @State private var showRapids = true
    @State private var showBoard = true

    var body: some View {
        VStack(spacing: 0) {
            ToolpathTopBar()
            HStack(alignment: .top, spacing: 10) {
                CNCSettingsPanel().frame(width: 304)
                ZStack {
                    if let path = tp.toolpath {
                        ToolpathViewerHost(toolpath: path, preset: preset, presetToken: presetToken,
                                           showRapids: showRapids, showBoard: showBoard)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(1)
                    } else {
                        VStack(spacing: 8) {
                            Text(tp.isGenerating ? "GENERATING TOOLPATH…" : "NO TOOLPATH YET")
                                .font(Theme.caption(12)).tracking(1.4).foregroundStyle(Theme.dim)
                            if !tp.isGenerating {
                                Text("Press GENERATE in the settings panel.").font(Theme.heading(11)).foregroundStyle(Theme.dim)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gmCard()
                SummaryPanel().frame(width: 272)
            }
            .padding(10)
            PlaybackBar(playback: tp.playback, preset: $preset, presetToken: $presetToken, showRapids: $showRapids, showBoard: $showBoard)
        }
        .background(Backdrop())
        .background(WindowTint())
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1180, minHeight: 720)
        .onAppear { if tp.toolpath == nil { tp.generate(params: store.params) } }
    }
}

/// Passes the playback object down so only the viewer redraws as time advances.
struct ToolpathViewerHost: View {
    @EnvironmentObject var tp: ToolpathStore
    let toolpath: Toolpath
    let preset: ViewPreset
    let presetToken: Int
    let showRapids: Bool
    let showBoard: Bool

    var body: some View {
        ToolpathViewerInner(playback: tp.playback, toolpath: toolpath, preset: preset, presetToken: presetToken,
                            showRapids: showRapids, showBoard: showBoard)
    }
}

struct ToolpathViewerInner: View {
    @EnvironmentObject var store: ModelStore
    @EnvironmentObject var tp: ToolpathStore
    @ObservedObject var playback: Playback
    let toolpath: Toolpath
    let preset: ViewPreset
    let presetToken: Int
    let showRapids: Bool
    let showBoard: Bool

    var body: some View {
        // Layout/mesh come from the parameters the toolpath was generated for.
        let params = tp.generatedParams ?? store.params
        let layout = FretboardLayout(params)
        ZStack(alignment: .topLeading) {
            ToolpathViewer(toolpath: toolpath, layout: layout, mesh: MeshCache.mesh(for: params, layout: layout),
                           version: tp.version, showRapids: showRapids, showBoard: showBoard,
                           preset: preset, presetToken: presetToken, state: tp.state(at: playback.time))
            HUD(playback: playback, toolpath: toolpath).padding(10)
        }
    }
}

/// Caches the most recent mesh so playback redraws don't rebuild it.
@MainActor
enum MeshCache {
    private static var params: FretboardParameters?
    private static var cached: IndexedMesh?
    static func mesh(for p: FretboardParameters, layout: FretboardLayout) -> IndexedMesh {
        if p == params, let m = cached { return m }
        let m = MeshBuilder.build(layout)
        params = p; cached = m
        return m
    }
}

struct HUD: View {
    @EnvironmentObject var tp: ToolpathStore
    @ObservedObject var playback: Playback
    let toolpath: Toolpath

    var body: some View {
        let s = tp.state(at: playback.time)
        let move = s.map { toolpath.moves[$0.index] }
        VStack(alignment: .leading, spacing: 6) {
            if let move, let s {
                HStack(spacing: 6) {
                    LedDot(on: true, color: Color(nsColor: opColor(move.op)), size: 7)
                    Text(move.op.title.uppercased()).font(Theme.caption(11)).tracking(1.2)
                    if move.kind == .rapid { LedReadout(text: "RAPID", color: Theme.steel, size: 10) }
                }
                HStack(spacing: 6) {
                    LedReadout(text: String(format: "X %8.2f", s.pos.x), size: 10)
                    LedReadout(text: String(format: "Y %8.2f", s.pos.y), size: 10)
                    LedReadout(text: String(format: "Z %7.2f", s.pos.z), size: 10)
                    LedReadout(text: String(format: "F %4.0f", move.feed), color: Theme.haze, size: 10)
                }
            }
        }
        .padding(8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Top bar

struct ToolpathTopBar: View {
    @EnvironmentObject var store: ModelStore
    @EnvironmentObject var tp: ToolpathStore

    var body: some View {
        let stale = tp.isStale(for: store.params)
        HStack(spacing: 10) {
            FretboardGlyph().frame(width: 20, height: 16)
            Text("TOOLPATH SIMULATION").font(Theme.headingBold(15)).tracking(2.5).foregroundStyle(Theme.offwhite)
            Text("WorkBee Z1+ · G-code").font(Theme.heading(11.5)).foregroundStyle(Theme.dim)
            Spacer()
            LedDot(on: true, color: tp.isGenerating ? Theme.warn : (stale ? Theme.warn : (tp.toolpath == nil ? Theme.danger : Theme.ok)))
            Text(tp.isGenerating ? "GENERATING" : (stale ? "OUT OF DATE" : (tp.toolpath == nil ? "NO TOOLPATH" : "TOOLPATH READY")))
                .font(Theme.caption(10.5)).tracking(1).foregroundStyle(Theme.text.opacity(0.85))
            if let path = tp.toolpath {
                LedReadout(text: GCodeWriter.formatTime(path.totalTime))
                LedReadout(text: "\(path.moves.count) MOVES", color: Theme.haze)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Theme.obsidian.opacity(0.88))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.gold.opacity(0.4)).frame(height: 1) }
    }
}

// MARK: - Settings

struct CNCSettingsPanel: View {
    @EnvironmentObject var store: ModelStore
    @EnvironmentObject var tp: ToolpathStore

    private func pct(_ b: Binding<Double>) -> Binding<Double> {
        Binding(get: { (b.wrappedValue * 100).rounded() }, set: { b.wrappedValue = $0 / 100 })
    }

    var body: some View {
        let errors = store.params.validate().isEmpty ? tp.settings.validate(for: store.params) : ["Fix the board parameters first."]
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Cutter & stock")
                HStack(spacing: 4) {
                    ForEach(CutterType.allCases) { c in
                        LatchButton(title: c.title.uppercased(), on: tp.settings.cutter == c) { tp.settings.cutter = c }
                    }
                }
                NumberField(title: "Cutter diameter", value: $tp.settings.cutterDiameter)
                NumberField(title: "Stock thickness", value: $tp.settings.stockThickness)
                Text("Z0 is the top of the stock. The board bottom is the stock bottom.")
                    .font(Theme.heading(10.5)).foregroundStyle(Theme.dim)

                SectionLabel("Feeds (WorkBee Z1+)").padding(.top, 4)
                NumberField(title: "X/Y cutting", value: $tp.settings.xyFeed, unit: "mm/min")
                NumberField(title: "Z cutting", value: $tp.settings.zFeed, unit: "mm/min")
                NumberField(title: "Fast travel", value: $tp.settings.rapidFeed, unit: "mm/min")

                SectionLabel("Roughing").padding(.top, 4)
                NumberField(title: "Depth per pass", value: $tp.settings.roughDepthPerPass)
                NumberField(title: "Material left", value: $tp.settings.roughAllowance)
                NumberField(title: "Surface overlap", value: pct($tp.settings.roughOverlap), unit: "%")

                SectionLabel("Finishing").padding(.top, 4)
                NumberField(title: "Surface overlap", value: pct($tp.settings.finishOverlap), unit: "%")
                NumberField(title: "Cut into spoilboard", value: $tp.settings.throughCutExtra)

                SectionLabel("Other").padding(.top, 4)
                NumberField(title: "Safe Z above stock", value: $tp.settings.safeZ)
                NumberField(title: "Edge margin", value: $tp.settings.edgeMargin)
                NumberField(title: "Outline floor left", value: $tp.settings.outlineFloorAllowance)
                NumberField(title: "Spindle (0 = manual)", value: Binding(get: { Double(tp.settings.spindleRPM) },
                                                                          set: { tp.settings.spindleRPM = max(0, Int($0)) }),
                            unit: "rpm")

                if !errors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(errors, id: \.self) { err in
                            HStack(alignment: .top, spacing: 6) {
                                LedDot(on: true, color: Theme.danger, size: 6).padding(.top, 3)
                                Text(err).font(Theme.heading(10.5)).foregroundStyle(Theme.danger)
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    BigLampButton(title: tp.isGenerating ? "WORKING…" : "GENERATE", systemImage: "gearshape.2",
                                  enabled: errors.isEmpty && !tp.isGenerating) { tp.generate(params: store.params) }
                    BigLampButton(title: "EXPORT", systemImage: "square.and.arrow.up", tint: Theme.haze,
                                  lit: false, enabled: tp.toolpath != nil && !tp.isStale(for: store.params)) {
                        tp.exportGCode(params: tp.generatedParams ?? store.params)
                    }
                }
                .padding(.top, 4)
            }
            .padding(14)
        }
        .gmCard()
    }
}

// MARK: - Summary

struct SummaryPanel: View {
    @EnvironmentObject var tp: ToolpathStore

    private func row(_ k: String, _ v: String, lit: Bool = false) -> some View {
        HStack(spacing: 6) {
            FieldCaption(k)
            Spacer(minLength: 4)
            Text(v).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(lit ? Theme.amber : Theme.offwhite)
                .shadow(color: lit ? Theme.amber.opacity(0.6) : .clear, radius: 2.5)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Job")
                if let path = tp.toolpath {
                    row("Run time", GCodeWriter.formatTime(path.totalTime), lit: true)
                    row("Cutting length", String(format: "%.1f m", path.cutLength / 1000))
                    row("Moves", "\(path.moves.count)")
                    row("G-code lines", "\(tp.gcode.split(separator: "\n").count)")
                    SectionLabel("Operations").padding(.top, 6)
                    ForEach(tp.summary) { s in
                        HStack(spacing: 8) {
                            LedDot(on: true, color: Color(nsColor: opColor(s.op)), size: 7)
                            Text(s.op.title.uppercased()).font(Theme.caption(10)).tracking(0.8)
                            Spacer()
                            Text(GCodeWriter.formatTime(s.seconds))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.offwhite)
                        }
                    }
                    SectionLabel("Sequence").padding(.top, 6)
                    Text("1  Rough the top surface in passes across the board width, extending past the edges, leaving 0.5 mm.\n2  Rough the outline, leaving 0.5 mm on the edge and the floor.\n3  Finish the surface at 30% overlap.\n4  Cut the outline at full depth for a clean edge.")
                        .font(Theme.heading(10.5)).foregroundStyle(Theme.dim)
                } else {
                    Text("Generate a toolpath to see the job summary.")
                        .font(Theme.heading(10.5)).foregroundStyle(Theme.dim)
                }
            }
            .padding(14)
        }
        .gmCard()
    }
}

// MARK: - Playback bar

struct PlaybackBar: View {
    @EnvironmentObject var tp: ToolpathStore
    @ObservedObject var playback: Playback
    @Binding var preset: ViewPreset
    @Binding var presetToken: Int
    @Binding var showRapids: Bool
    @Binding var showBoard: Bool

    var body: some View {
        let enabled = tp.toolpath != nil
        HStack(spacing: 12) {
            BigLampButton(title: playback.isPlaying ? "PAUSE" : "PLAY",
                          systemImage: playback.isPlaying ? "pause.fill" : "play.fill",
                          enabled: enabled) { playback.toggle() }
            LatchButton(title: "RESTART", on: false) { playback.time = 0 }.frame(width: 70).disabled(!enabled)
            HStack(spacing: 4) {
                ForEach([1.0, 10.0, 50.0, 200.0, 1000.0], id: \.self) { sp in
                    LatchButton(title: "\(Int(sp))×", on: playback.speed == sp, tint: Theme.haze) { playback.speed = sp }
                        .frame(width: 48)
                }
            }
            LevelSlider(value: Binding(get: { playback.time }, set: { playback.time = $0 }),
                        range: 0...max(playback.total, 0.001))
                .frame(minWidth: 160)
            Text("\(GCodeWriter.formatTime(playback.time)) / \(GCodeWriter.formatTime(playback.total))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.amber)
                .frame(width: 150, alignment: .trailing)
            Rectangle().fill(Theme.gold.opacity(0.25)).frame(width: 1, height: 20)
            HStack(spacing: 4) {
                ForEach([ViewPreset.iso, .top, .side]) { p in
                    LatchButton(title: p.title.uppercased(), on: p == preset) { preset = p; presetToken += 1 }.frame(width: 50)
                }
                LatchButton(title: "RAPIDS", on: showRapids, tint: Theme.steel) { showRapids.toggle() }.frame(width: 60)
                LatchButton(title: "BOARD", on: showBoard, tint: Theme.steel) { showBoard.toggle() }.frame(width: 60)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Theme.obsidian.opacity(0.88))
        .overlay(alignment: .top) { Rectangle().fill(Theme.gold.opacity(0.4)).frame(height: 1) }
    }
}
