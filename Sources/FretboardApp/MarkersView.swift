import SwiftUI
import AppKit
import simd
import FretboardKit

/// The Markers tab: plan fret dots and a custom 12th-fret inlay, preview them on the board and make the
/// two G-code files (dots with the main cutter, the inlay with a fine cutter).
struct MarkersView: View {
    @EnvironmentObject var store: ModelStore
    @EnvironmentObject var tp: ToolpathStore
    @EnvironmentObject var mk: MarkerStore
    @State private var mode: MarkerPreviewMode = .plan
    @State private var preset: ViewPreset = .iso
    @State private var presetToken = 0

    private func available(_ m: MarkerPreviewMode) -> Bool {
        switch m {
        case .plan: return true
        case .dots3D: return mk.dotsPlayer != nil
        case .inlay3D: return mk.inlayPlayer != nil
        }
    }

    /// Frames the 3D view on the inlay, in the board job's machine coordinates.
    private var inlayFocus: (center: SIMD3<Double>, span: Double) {
        let L = store.layout
        let c = store.markers.inlayCentre(L)
        let span = max(store.markers.inlay.width, store.markers.inlay.height, 10) * 1.6
        return (SIMD3(c.x, c.y, L.topZ(x: c.x, y: c.y) - tp.settings.stockThickness), span)
    }

    private var planView: some View {
        VStack(spacing: 0) {
            MarkerPreview(layout: store.layout, markers: store.markers,
                          inlayJob: mk.showToolpath ? mk.inlayJob : nil, zoom: mk.zoomToInlay)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gmCard()
                .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in drop(providers) }
            HStack(spacing: 4) {
                LatchButton(title: "WHOLE BOARD", on: !mk.zoomToInlay) { mk.zoomToInlay = false }.frame(width: 110)
                LatchButton(title: "12TH FRET", on: mk.zoomToInlay) { mk.zoomToInlay = true }.frame(width: 90)
                LatchButton(title: "INLAY TOOLPATH", on: mk.showToolpath, tint: Theme.haze) { mk.showToolpath.toggle() }.frame(width: 120)
                Spacer()
                Text(store.markers.strings.trebleOnPlusY
                     ? "Left-handed board seen from above: nut on the left, bass side at the top. Drop an image here to trace it."
                     : "Seen from above as in the Designer: nut on the right, bass side at the top. Drop an image here to trace it.")
                    .font(Theme.heading(10.5)).foregroundStyle(Theme.dim)
            }
            .padding(.top, 8)
        }
    }

    /// The selected view, or Plan when its job has gone (e.g. after opening a project).
    private var shown: MarkerPreviewMode { available(mode) ? mode : .plan }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MarkerSetupPanel().frame(width: 320)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(MarkerPreviewMode.allCases) { m in
                        LatchButton(title: m.title, on: shown == m) { mode = m; presetToken += 1 }
                            .frame(width: 96)
                            .disabled(!available(m))
                            .opacity(available(m) ? 1 : 0.4)
                    }
                    Spacer()
                    if shown != .plan, mk.isStale(store, cnc: tp.settings) {
                        Text("OUT OF DATE: GENERATE AGAIN").font(Theme.caption(10)).tracking(1).foregroundStyle(Theme.warn)
                    }
                }
                .padding(.bottom, 8)
                switch shown {
                case .plan:
                    planView
                case .dots3D:
                    if let pl = mk.dotsPlayer, let j = mk.dotsJob {
                        MarkerPlaybackView(player: pl, focus: nil, hudOffset: j.displayShift,
                                           preset: $preset, presetToken: $presetToken)
                    }
                case .inlay3D:
                    if let pl = mk.inlayPlayer, let j = mk.inlayJob {
                        MarkerPlaybackView(player: pl, focus: inlayFocus, hudOffset: j.displayShift,
                                           preset: $preset, presetToken: $presetToken)
                    }
                }
            }
            MarkerJobsPanel().frame(width: 330)
        }
        .padding(10)
        .onAppear {
            mk.model = store
            let a = CommandLine.arguments
            if let i = a.firstIndex(of: "--inlay-image"), i + 1 < a.count, store.markers.inlay.artwork == nil {
                mk.load(url: URL(fileURLWithPath: a[i + 1]))
            }
        }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        if p.canLoadObject(ofClass: URL.self) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in mk.load(url: url) } }
            }
            return true
        }
        return false
    }
}

enum MarkerPreviewMode: Int, CaseIterable, Identifiable {
    case plan, dots3D, inlay3D
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .plan: return "PLAN"
        case .dots3D: return "3D DOTS"
        case .inlay3D: return "3D INLAY"
        }
    }
}

/// 3D playback of a marker job on the board (with its pockets), reusing the board job's viewer and controls.
struct MarkerPlaybackView: View {
    @EnvironmentObject var store: ModelStore
    let player: JobPlayer
    let focus: (center: SIMD3<Double>, span: Double)?
    let hudOffset: SIMD3<Double>
    @Binding var preset: ViewPreset
    @Binding var presetToken: Int
    @State private var showRapids = true
    @State private var showBoard = true

    var body: some View {
        VStack(spacing: 0) {
            MarkerViewport(playback: player.playback, player: player, focus: focus, hudOffset: hudOffset,
                           preset: preset, presetToken: presetToken, showRapids: showRapids, showBoard: showBoard)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gmCard()
            PlaybackBar(enabled: true, playback: player.playback, preset: $preset, presetToken: $presetToken,
                        showRapids: $showRapids, showBoard: $showBoard)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.top, 8)
        }
    }
}

/// Observes the playback clock so only the viewport redraws as time advances.
private struct MarkerViewport: View {
    @EnvironmentObject var store: ModelStore
    @ObservedObject var playback: Playback
    let player: JobPlayer
    let focus: (center: SIMD3<Double>, span: Double)?
    let hudOffset: SIMD3<Double>
    let preset: ViewPreset
    let presetToken: Int
    let showRapids: Bool
    let showBoard: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            ToolpathViewer(toolpath: player.toolpath, layout: store.layout, mesh: store.mesh,
                           version: player.version &* 1_000_003 &+ store.meshVersion,
                           showRapids: showRapids, showBoard: showBoard, preset: preset, presetToken: presetToken,
                           state: player.state(at: playback.time), focus: focus)
            HUD(playback: playback, toolpath: player.toolpath, state: { player.state(at: $0) }, offset: hudOffset)
                .padding(10)
        }
    }
}

// MARK: - Setup

struct MarkerSetupPanel: View {
    @EnvironmentObject var store: ModelStore
    @EnvironmentObject var mk: MarkerStore

    private var m: Binding<MarkerSettings> { $store.markers }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Markers")
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach([MarkerMode.none, .dots]) { mode in
                            LatchButton(title: mode.title.uppercased(), on: store.markers.mode == mode) { store.markers.mode = mode }
                        }
                    }
                    HStack(spacing: 4) {
                        ForEach([MarkerMode.dotsAndInlay, .inlayOnly]) { mode in
                            LatchButton(title: mode.title.uppercased(), on: store.markers.mode == mode) { store.markers.mode = mode }
                        }
                    }
                }
                if store.markers.mode.hasDots { dotsSection }
                if store.markers.mode.hasInlay { inlaySection }
                if store.markers.mode != .none { stringsSection }
                ForEach(store.markerErrors, id: \.self) { e in
                    Text(e).font(Theme.heading(10.5)).foregroundStyle(Theme.danger)
                }
                ForEach(store.markerWarnings, id: \.self) { w in
                    Text(w).font(Theme.heading(10.5)).foregroundStyle(Theme.warn)
                }
                if store.markers.mode != .none && store.markerErrors.isEmpty {
                    Text("\(store.pocketCount) pocket\(store.pocketCount == 1 ? "" : "s") cut into the Designer model and its STL.")
                        .font(Theme.heading(10.5)).foregroundStyle(Theme.dim)
                }
            }
            .padding(12)
        }
        .gmCard()
    }

    private var dotsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Dots").padding(.top, 4)
            NumberField(title: "Diameter", value: m.dotDiameter)
            NumberField(title: "Depth", value: m.dotDepth)
            FieldCaption("Frets (double dots at 12 and 24)")
            let frets = Array(1...store.params.fretCount)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 8), spacing: 3) {
                ForEach(frets, id: \.self) { f in
                    let on = store.markers.dotFrets.contains(f)
                    LatchButton(title: "\(f)", on: on, tint: store.markers.doubleDotFrets.contains(f) ? Theme.haze : Theme.accent) {
                        if on { store.markers.dotFrets.removeAll { $0 == f } } else { store.markers.dotFrets.append(f) }
                    }
                }
            }
            Text("Dots sit in the middle of each fret space with a flat floor below the surface at their centre.")
                .font(Theme.heading(10)).foregroundStyle(Theme.dim)
        }
    }

    private var stringsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Strings (for the double dots)").padding(.top, 4)
            NumberField(title: "E string in from nut edge", value: m.strings.nutEdgeInset)
            NumberField(title: "E to E at bridge", value: m.strings.bridgeSpan)
            HStack {
                FieldCaption("Gauges (in)")
                Spacer()
                TextField("", text: Binding(
                    get: { store.markers.strings.gauges.map { String(format: ".%03.0f", $0 * 1000) }.joined(separator: " ") },
                    set: { t in
                        let g = t.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
                        if g.count == 6 { store.markers.strings.gauges = g }
                    }))
                .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.amber)
                .padding(.horizontal, 6).padding(.vertical, 3).frame(width: 180).gmWell()
            }
            LampCheck(text: "Left-handed board (treble side +Y)", on: m.strings.trebleOnPlusY,
                      detail: "Compensated spacing; the double dots sit under the B and A strings.")
        }
    }

    private var inlaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("12th fret inlay").padding(.top, 4)
            HStack(spacing: 4) {
                LatchButton(title: "IMPORT…", on: false, height: 22) { mk.importImage() }
                LatchButton(title: "PASTE", on: false, height: 22) { mk.paste() }
                LatchButton(title: "CAPTURE", on: false, height: 22) { mk.captureScreen() }
                    .help("Drag out an area of the screen (or press Space and click a window) to capture your design.")
            }
            if let msg = mk.message {
                Text(msg).font(Theme.heading(10.5)).foregroundStyle(Theme.warn)
            }
            if store.markers.inlay.artwork != nil {
                HStack {
                    Text(mk.sourceName).font(Theme.heading(10.5)).foregroundStyle(Theme.dim).lineLimit(1)
                    Spacer()
                    LatchButton(title: "CLEAR", on: false) { mk.clearImage() }.frame(width: 60)
                }
                HStack {
                    FieldCaption("Threshold")
                    Slider(value: $mk.trace.threshold, in: 0.05...0.95)
                }
                LampStepper(title: "Smoothing (px)", value: $mk.trace.smoothing, range: 0...6)
                LampCheck(text: "Invert (light design on dark)", on: $mk.trace.invert)
                SectionLabel("Size & position").padding(.top, 4)
                NumberField(title: "Width (along neck)", value: Binding(
                    get: { store.markers.inlay.width },
                    set: { v in
                        var i = store.markers.inlay
                        i.width = v
                        if i.lockAspect, let a = i.artwork?.aspect, v > 0 { i.height = v / a }
                        store.markers.inlay = i
                    }))
                NumberField(title: "Height (across)", value: Binding(
                    get: { store.markers.inlay.height },
                    set: { v in
                        var i = store.markers.inlay
                        i.height = v
                        if i.lockAspect, let a = i.artwork?.aspect, v > 0 { i.width = v * a }
                        store.markers.inlay = i
                    }))
                LampCheck(text: "Lock aspect ratio", on: Binding(
                    get: { store.markers.inlay.lockAspect },
                    set: { on in
                        var i = store.markers.inlay
                        i.lockAspect = on
                        if on, let a = i.artwork?.aspect { i.height = i.width / a }
                        store.markers.inlay = i
                    }))
                NumberField(title: "Move toward body", value: m.inlay.offsetAlong)
                NumberField(title: "Move toward bass", value: m.inlay.offsetAcross)
                NumberField(title: "Rotation", value: m.inlay.rotation, unit: "°")
                LampCheck(text: "Mirror", on: m.inlay.mirror)
                NumberField(title: "Pocket depth", value: m.inlay.depth)
                Text("Centred on the 12th fret space; it may span the 11th to 13th. The floor follows the board radius.")
                    .font(Theme.heading(10)).foregroundStyle(Theme.dim)
            } else {
                Text("Import a black-and-white image, paste one, or capture an area of the screen from your design app. Black areas become the pocket.")
                    .font(Theme.heading(10.5)).foregroundStyle(Theme.dim)
            }
        }
    }
}

// MARK: - Jobs

struct MarkerJobsPanel: View {
    @EnvironmentObject var store: ModelStore
    @EnvironmentObject var tp: ToolpathStore
    @EnvironmentObject var mk: MarkerStore

    private func pct(_ b: Binding<Double>) -> Binding<Double> {
        Binding(get: { b.wrappedValue * 100 }, set: { b.wrappedValue = $0 / 100 })
    }
    private func dbl(_ b: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = max(0, Int($0.rounded())) })
    }

    var body: some View {
        let stale = mk.isStale(store, cnc: tp.settings)
        let canGenerate = store.errors.isEmpty && store.markerErrors.isEmpty && store.markers.mode != .none
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    BigLampButton(title: mk.isGenerating ? "WORKING…" : "GENERATE", systemImage: "gearshape.2",
                                  enabled: canGenerate && !mk.isGenerating) { mk.generate(store, cnc: tp.settings) }
                    Spacer()
                    if stale { Text("OUT OF DATE").font(Theme.caption(10)).tracking(1).foregroundStyle(Theme.warn) }
                }
                Text(String(format: "Board-origin jobs use the board job's zero: X0 heel edge, Y0 centre line, Z0 top of the %.1f mm blank (set in the Toolpath tab). Run them after surfacing, before releasing the board from its tabs.",
                            tp.settings.stockThickness))
                    .font(Theme.heading(10)).foregroundStyle(Theme.dim)

                if store.markers.mode.hasDots {
                    SectionLabel("Dots job").padding(.top, 4)
                    NumberField(title: "Cutter", value: $mk.dots.cutterDiameter)
                    NumberField(title: "Peck depth", value: $mk.dots.peckDepth)
                    NumberField(title: "Plunge feed", value: $mk.dots.plungeFeed, unit: "mm/min")
                    NumberField(title: "X/Y feed", value: $mk.dots.xyFeed, unit: "mm/min")
                    NumberField(title: "Spindle (0 = manual)", value: dbl($mk.dots.spindleRPM), unit: "rpm")
                    ForEach(MarkerToolpath.validate(dots: mk.dots, markers: store.markers), id: \.self) {
                        Text($0).font(Theme.heading(10.5)).foregroundStyle(Theme.danger)
                    }
                    if let j = mk.dotsJob { summary(j) }
                    BigLampButton(title: "EXPORT DOTS G-CODE", systemImage: "square.and.arrow.up", enabled: mk.dotsJob != nil) {
                        mk.export(mk.dotsJob, name: String(format: "fret_dots_%.0fmm.nc", store.params.scaleLength))
                    }
                }

                if store.markers.mode.hasInlay {
                    SectionLabel("Inlay job (fine cutter)").padding(.top, 6)
                    HStack(spacing: 4) {
                        ForEach(InlayOrigin.allCases) { o in
                            LatchButton(title: o.title.uppercased(), on: mk.inlay.origin == o) { mk.inlay.origin = o }
                        }
                    }
                    Text(mk.inlay.origin == .board ? "Same zero as the board job."
                         : "Zero X/Y on the centre of the inlay and Z on the board surface there.")
                        .font(Theme.heading(10)).foregroundStyle(Theme.dim)
                    NumberField(title: "Cutter", value: $mk.inlay.cutterDiameter)
                    NumberField(title: "Flute length", value: $mk.inlay.fluteLength)
                    NumberField(title: "Depth per layer", value: $mk.inlay.depthPerLayer)
                    NumberField(title: "Stepover", value: pct($mk.inlay.stepover), unit: "%")
                    NumberField(title: "X/Y feed", value: $mk.inlay.xyFeed, unit: "mm/min")
                    NumberField(title: "Slot feed", value: pct($mk.inlay.slotFeedFactor), unit: "%")
                    NumberField(title: "Plunge feed", value: $mk.inlay.plungeFeed, unit: "mm/min")
                    NumberField(title: "Ramp angle", value: $mk.inlay.rampAngle, unit: "°")
                    NumberField(title: "Finish allowance", value: $mk.inlay.wallAllowance)
                    NumberField(title: "Planning resolution", value: $mk.inlay.resolution)
                    NumberField(title: "Spindle (0 = manual)", value: dbl($mk.inlay.spindleRPM), unit: "rpm")
                    HStack(spacing: 4) {
                        LatchButton(title: "CLIMB", on: mk.inlay.climb) { mk.inlay.climb = true }
                        LatchButton(title: "CONVENTIONAL", on: !mk.inlay.climb) { mk.inlay.climb = false }
                    }
                    ForEach(MarkerToolpath.validate(inlay: mk.inlay, markers: store.markers), id: \.self) {
                        Text($0).font(Theme.heading(10.5)).foregroundStyle(Theme.danger)
                    }
                    if let j = mk.inlayJob {
                        summary(j)
                        ForEach(j.warnings, id: \.self) { Text($0).font(Theme.heading(10.5)).foregroundStyle(Theme.warn) }
                    }
                    BigLampButton(title: "EXPORT INLAY G-CODE", systemImage: "square.and.arrow.up", enabled: mk.inlayJob != nil) {
                        mk.export(mk.inlayJob, name: "fret\(store.markers.inlay.fret)_inlay_\(mk.inlay.origin == .board ? "board" : "centre")_zero.nc")
                    }
                    Text("Fragile cutter: every entry ramps in along the path, the first loop after each entry runs at the slot feed, and each layer ends with a light finishing pass on the walls. Air-cut first with Z raised.")
                        .font(Theme.heading(10)).foregroundStyle(Theme.dim)
                }
            }
            .padding(12)
        }
        .gmCard()
    }

    private func summary(_ j: MarkerJob) -> some View {
        HStack(spacing: 8) {
            LedReadout(text: GCodeWriter.formatTime(j.toolpath.totalTime))
            LedReadout(text: "\(j.toolpath.moves.count) MOVES", color: Theme.haze)
            if j.pocketArea > 0 { LedReadout(text: String(format: "%.0f mm²", j.pocketArea), color: Theme.haze) }
        }
    }
}

// MARK: - Preview

/// Plan view of the board from above, bass side up (for a right-handed board this is the Designer's top
/// view: heel left, nut right) with frets, strings, pockets,
/// the inlay toolpath and areas the cutter cannot reach.
struct MarkerPreview: View {
    let layout: FretboardLayout
    let markers: MarkerSettings
    let inlayJob: MarkerJob?
    let zoom: Bool

    var body: some View {
        Canvas { ctx, size in
            let L = layout
            let v = markers.viewSign
            let n = L.params.fretCount
            let f = min(max(markers.inlay.fret, 2), n)
            let xHi = zoom ? L.fretX(max(0, f - 3)) + 3 : L.xEnd + 4
            let xLo = zoom ? L.fretX(min(n, f + 2)) - 3 : -4
            let yHalf = zoom ? L.taperHalfWidth(at: L.fretX(f)) + 4 : L.taperHalfWidth(at: 0) + 6
            let k = min((size.width - 24) / (xHi - xLo), (size.height - 30) / (2 * yHalf))
            let ox = (size.width - (xHi - xLo) * k) / 2
            func pt(_ p: SIMD2<Double>) -> CGPoint {
                CGPoint(x: ox + (v > 0 ? p.x - xLo : xHi - p.x) * k, y: size.height / 2 - v * p.y * k)
            }
            func path(_ rings: [[SIMD2<Double>]]) -> Path {
                var pa = Path()
                for r in rings where r.count > 2 {
                    pa.move(to: pt(r[0])); for q in r.dropFirst() { pa.addLine(to: pt(q)) }; pa.closeSubpath()
                }
                return pa
            }

            // Board
            let outline = ToolpathGenerator.offsetOutline(L, offset: 0)
            let board = path([outline])
            ctx.fill(board, with: .color(Color(red: 0.24, green: 0.15, blue: 0.09)))
            ctx.stroke(board, with: .color(Theme.gold.opacity(0.6)), lineWidth: 1)
            // Frets and their numbers
            for i in 0...n {
                let x = L.fretX(i), hw = L.taperHalfWidth(at: x)
                var p = Path(); p.move(to: pt(SIMD2(x, -hw))); p.addLine(to: pt(SIMD2(x, hw)))
                ctx.stroke(p, with: .color(i == 0 ? Theme.offwhite : Color(white: 0.75).opacity(0.7)), lineWidth: i == 0 ? 2.5 : 1)
                if i >= 1 {
                    let c = pt(SIMD2(MarkerSettings.spaceCentreX(L, i), v * (L.taperHalfWidth(at: x) + 2.5)))
                    ctx.draw(Text("\(i)").font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.dim), at: c)
                }
            }
            // Strings
            for s in 1...6 {
                var p = Path()
                for x in [L.xNut, 0.0] {
                    let d = L.xNut - x
                    let q = pt(SIMD2(x, markers.strings.y(string: s, fromNut: d, layout: L)))
                    if x == L.xNut { p.move(to: q) } else { p.addLine(to: q) }
                }
                ctx.stroke(p, with: .color(Color(white: 0.92).opacity(0.75)), lineWidth: 0.6 + 0.2 * Double(s))
            }
            // Pockets
            for pk in markers.pockets(L) {
                let pa = path(pk.rings)
                ctx.fill(pa, with: .color(Theme.amber.opacity(0.85)), style: FillStyle(eoFill: true))
                ctx.stroke(pa, with: .color(Theme.amber), lineWidth: 0.8)
            }
            // Inlay toolpath (cutting moves) and what the cutter can't reach
            if let j = inlayJob {
                var pa = Path()
                var prev: CGPoint?
                for m in j.toolpath.moves {
                    let q = pt(SIMD2(m.to.x, m.to.y) + j.originOffset)
                    if m.kind == .cut, let p0 = prev { pa.move(to: p0); pa.addLine(to: q) }
                    prev = q
                }
                ctx.stroke(pa, with: .color(Color(red: 0.1, green: 0.35, blue: 0.1).opacity(0.9)), lineWidth: 0.6)
                ctx.fill(path(j.uncut), with: .color(Theme.danger), style: FillStyle(eoFill: true))
            }
        }
        .background(Color.black.opacity(0.35))
    }
}
