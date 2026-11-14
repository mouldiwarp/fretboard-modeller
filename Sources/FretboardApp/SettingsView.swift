import SwiftUI
import FretboardKit

/// Every setting that has a default, editable. The values here are the starting point of each new project.
struct SettingsView: View {
    @EnvironmentObject var project: ProjectController
    @ObservedObject private var defaults = AppDefaults.shared
    @State private var frets = ""
    @State private var doubles = ""

    private typealias KP<V> = WritableKeyPath<DefaultsFile, V>
    private let P = \DefaultsFile.project

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), alignment: .leading, spacing: 12) {
                    card("Board") { board }
                    card("Truss rod & cutout") { cutout }
                    card("Blank (stock)") { blank }
                    card("Cutter & feeds") { cutter }
                    card("Roughing & finishing") { passes }
                    card("Outline, tabs & accuracy") { outline }
                    card("Fret dots") { dots }
                    card("12th fret inlay") { inlay }
                    card("Inlay cutter") { inlayCutter }
                    card("Strings & marker layout") { strings }
                    card("Inlay image trace") { trace }
                    card("Fret template") { template }
                }
            }
            .padding(14)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Defaults for new projects").font(Theme.headingBold(14)).foregroundStyle(Theme.offwhite)
                Text("Changes are saved as you type and used by every new project (⌘N) and the next launch. They don't change the project that is open; use “Apply to open project” for that.")
                    .font(Theme.heading(10.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                if let e = defaults.loadError { Text(e).font(Theme.heading(10.5)).foregroundStyle(Theme.danger) }
            }
            Spacer()
            LatchButton(title: "USE OPEN PROJECT'S VALUES", on: false, height: 24) { adoptOpenProject() }.frame(width: 190)
            LatchButton(title: "APPLY TO OPEN PROJECT", on: false, height: 24) { applyToOpenProject() }.frame(width: 170)
            LatchButton(title: "RESET TO FACTORY", on: false, tint: Theme.danger, height: 24) { resetAll() }
                .frame(width: 140).disabled(defaults.isFactory).opacity(defaults.isFactory ? 0.4 : 1)
        }
    }

    private func confirm(_ message: String, _ info: String, button: String) -> Bool {
        let a = NSAlert()
        a.messageText = message; a.informativeText = info
        a.addButton(withTitle: button); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func resetAll() {
        if confirm("Reset every default to the factory value?", "Your saved defaults will be replaced. Open projects are not changed.", button: "Reset") {
            defaults.resetToFactory(); syncLists()
        }
    }

    private func adoptOpenProject() {
        if confirm("Use the open project's settings as your defaults?", "Every setting in the open project, apart from its inlay image, becomes the starting point of new projects.", button: "Use as defaults") {
            defaults.adopt(project.snapshot()); syncLists()
        }
    }

    private func applyToOpenProject() {
        if confirm("Apply the defaults to the open project?", "All of the open project's settings are replaced by the defaults (its inlay image is kept). You can undo this by not saving.", button: "Apply") {
            project.applyDefaultsKeepingInlay()
        }
    }

    // MARK: Sections

    private var board: some View {
        Group {
            num("Scale length", P.appending(path: \.params.scaleLength))
            num("Nut width", P.appending(path: \.params.nutWidth))
            num("Width at last fret", P.appending(path: \.params.lastFretWidth))
            count("Frets", P.appending(path: \.params.fretCount), 1...40)
            num("Thickness", P.appending(path: \.params.thickness))
            num("Radius at fret 1", P.appending(path: \.params.radiusFirstFretInches), "in")
            num("Radius at last fret", P.appending(path: \.params.radiusLastFretInches), "in")
            flag("Fender-style nut (10 mm past 0 fret)", P.appending(path: \.params.fenderNut))
            num("Wide-end corner Ø", P.appending(path: \.params.cornerDiameter))
        }
    }

    private var cutout: some View {
        Group {
            flag("Spoke-wheel truss rod", P.appending(path: \.params.hasSpokeWheelTrussRod))
            num("Extension past last fret", P.appending(path: \.params.trussRodExtension))
            num("Cutout width", P.appending(path: \.params.cutoutWidth))
            num("Cutout depth", P.appending(path: \.params.cutoutDepth))
            num("Cutout corner radius", P.appending(path: \.params.cutoutCornerRadius))
        }
    }

    private var blank: some View {
        Group {
            num("Thickness", P.appending(path: \.cnc.stockThickness))
            num("Length", P.appending(path: \.cnc.stockLength))
            num("Width", P.appending(path: \.cnc.stockWidth))
            num("Heel margin", P.appending(path: \.cnc.stockHeelMargin))
        }
    }

    private var cutter: some View {
        Group {
            num("Cutter diameter", P.appending(path: \.cnc.cutterDiameter))
            num("X/Y feed", P.appending(path: \.cnc.xyFeed), "mm/min")
            num("Z feed", P.appending(path: \.cnc.zFeed), "mm/min")
            num("Rapid feed", P.appending(path: \.cnc.rapidFeed), "mm/min")
            num("Safe Z", P.appending(path: \.cnc.safeZ))
            rpm("Spindle speed (0 = off)", P.appending(path: \.cnc.spindleRPM))
        }
    }

    private var passes: some View {
        Group {
            num("Roughing depth per pass", P.appending(path: \.cnc.roughDepthPerPass))
            num("Material left by roughing", P.appending(path: \.cnc.roughAllowance))
            num("Roughing overlap", P.appending(path: \.cnc.roughOverlap), "%", scale: 100)
            num("Finishing overlap", P.appending(path: \.cnc.finishOverlap), "%", scale: 100)
            num("Edge margin", P.appending(path: \.cnc.edgeMargin))
            num("Trench width", P.appending(path: \.cnc.trenchWidthFactor), "× Ø")
            num("Floor left under trench", P.appending(path: \.cnc.outlineFloorAllowance))
            num("Cut into spoilboard", P.appending(path: \.cnc.throughCutExtra))
        }
    }

    private var outline: some View {
        Group {
            flag("Climb milling (counter-clockwise)", P.appending(path: \.cnc.climbOutline))
            count("Tabs", P.appending(path: \.cnc.tabCount), 0...12)
            num("Tab width", P.appending(path: \.cnc.tabWidth))
            num("Tab height", P.appending(path: \.cnc.tabHeight))
            num("Outline trim per side", P.appending(path: \.cnc.outlineTrim))
            flag("Spring pass (cut the outline twice)", P.appending(path: \.cnc.outlineSpringPass))
            Text("Trim moves the final outline cut into the board. If the part comes out oversize, use a small positive value. The spring pass removes what the tool pushed away on the first lap.")
                .font(.system(size: 10)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dots: some View {
        Group {
            HStack(spacing: 4) {
                ForEach(MarkerMode.allCases) { m in
                    LatchButton(title: m.title.uppercased(), on: defaults.file.project.markers.mode == m) {
                        defaults.file.project.markers.mode = m
                    }
                }
            }
            num("Dot diameter", P.appending(path: \.markers.dotDiameter))
            num("Dot depth", P.appending(path: \.markers.dotDepth))
            num("Cutter diameter", P.appending(path: \.dots.cutterDiameter))
            num("Peck depth", P.appending(path: \.dots.peckDepth))
            num("Plunge feed", P.appending(path: \.dots.plungeFeed), "mm/min")
            num("X/Y feed", P.appending(path: \.dots.xyFeed), "mm/min")
            num("Stepover", P.appending(path: \.dots.stepover), "%", scale: 100)
            num("Safe Z", P.appending(path: \.dots.safeZ))
            rpm("Spindle speed (0 = off)", P.appending(path: \.dots.spindleRPM))
        }
    }

    private var inlay: some View {
        Group {
            num("Width", P.appending(path: \.markers.inlay.width))
            num("Height", P.appending(path: \.markers.inlay.height))
            flag("Keep proportions", P.appending(path: \.markers.inlay.lockAspect))
            count("Fret space", P.appending(path: \.markers.inlay.fret), 1...40)
            num("Offset along board", P.appending(path: \.markers.inlay.offsetAlong))
            num("Offset across board", P.appending(path: \.markers.inlay.offsetAcross))
            num("Rotation", P.appending(path: \.markers.inlay.rotation), "°")
            flag("Mirror", P.appending(path: \.markers.inlay.mirror))
            num("Pocket depth", P.appending(path: \.markers.inlay.depth))
        }
    }

    private var inlayCutter: some View {
        Group {
            num("Cutter diameter", P.appending(path: \.inlay.cutterDiameter))
            num("Flute length", P.appending(path: \.inlay.fluteLength))
            num("Depth per layer", P.appending(path: \.inlay.depthPerLayer))
            num("Stepover", P.appending(path: \.inlay.stepover), "%", scale: 100)
            num("X/Y feed", P.appending(path: \.inlay.xyFeed), "mm/min")
            num("Plunge feed", P.appending(path: \.inlay.plungeFeed), "mm/min")
            num("Ramp angle", P.appending(path: \.inlay.rampAngle), "°")
            num("Wall allowance", P.appending(path: \.inlay.wallAllowance))
            num("Slot feed", P.appending(path: \.inlay.slotFeedFactor), "%", scale: 100)
            num("Planning resolution", P.appending(path: \.inlay.resolution))
            num("Safe Z", P.appending(path: \.inlay.safeZ))
            rpm("Spindle speed (0 = off)", P.appending(path: \.inlay.spindleRPM))
            flag("Climb milling", P.appending(path: \.inlay.climb))
            HStack(spacing: 4) {
                ForEach(InlayOrigin.allCases) { o in
                    LatchButton(title: o.title.uppercased(), on: defaults.file.project.inlay.origin == o) {
                        defaults.file.project.inlay.origin = o
                    }
                }
            }
        }
    }

    private var strings: some View {
        Group {
            num("Margin to edges / other pockets", P.appending(path: \.markers.edgeMargin))
            num("Outer string inset at nut", P.appending(path: \.markers.strings.nutEdgeInset))
            num("Bridge string span", P.appending(path: \.markers.strings.bridgeSpan))
            flag("Treble side on +Y", P.appending(path: \.markers.strings.trebleOnPlusY))
            ForEach(0..<6, id: \.self) { i in
                num("String \(i + 1) gauge", P.appending(path: \.markers.strings.gauges).appending(path: \Array<Double>.[i]), "in")
            }
            listField("Dot frets", $frets) { defaults.file.project.markers.dotFrets = $0 }
            listField("Double-dot frets", $doubles) { defaults.file.project.markers.doubleDotFrets = $0 }
        }
        .onAppear { syncLists() }
    }

    private var trace: some View {
        Group {
            num("Threshold", P.appending(path: \.trace.threshold), "%", scale: 100)
            flag("Invert", P.appending(path: \.trace.invert))
            count("Smoothing", P.appending(path: \.trace.smoothing), 0...10)
            num("Ignore specks below", P.appending(path: \.trace.minAreaFraction), "%", scale: 100)
        }
    }

    private var template: some View {
        Group {
            let T = \DefaultsFile.fretTemplate
            num("Hole diameter", T.appending(path: \.holeDiameter))
            num("Plunge depth", T.appending(path: \.plungeDepth))
            num("Safe Z", T.appending(path: \.safeZ))
            num("Feed", T.appending(path: \.feed), "mm/min")
            HStack(spacing: 4) {
                LatchButton(title: "( COMMENTS )", on: defaults.file.fretTemplate.commentStyle == .parentheses) {
                    defaults.file.fretTemplate.commentStyle = .parentheses
                }
                LatchButton(title: "; COMMENTS", on: defaults.file.fretTemplate.commentStyle == .semicolon) {
                    defaults.file.fretTemplate.commentStyle = .semicolon
                }
            }
        }
    }

    // MARK: Building blocks

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .gmCard()
    }

    private func num(_ title: String, _ kp: KP<Double>, _ unit: String = "mm", scale: Double = 1) -> some View {
        NumberField(title: title, value: Binding(get: { defaults.file[keyPath: kp] * scale },
                                                 set: { defaults.file[keyPath: kp] = $0 / scale }), unit: unit)
    }

    private func rpm(_ title: String, _ kp: KP<Int>) -> some View {
        NumberField(title: title, value: Binding(get: { Double(defaults.file[keyPath: kp]) },
                                                 set: { defaults.file[keyPath: kp] = max(0, Int($0.rounded())) }), unit: "rpm")
    }

    private func count(_ title: String, _ kp: KP<Int>, _ range: ClosedRange<Int>) -> some View {
        LampStepper(title: title, value: Binding(get: { defaults.file[keyPath: kp] },
                                                 set: { defaults.file[keyPath: kp] = $0 }), range: range)
    }

    private func flag(_ title: String, _ kp: KP<Bool>) -> some View {
        LampCheck(text: title, on: Binding(get: { defaults.file[keyPath: kp] }, set: { defaults.file[keyPath: kp] = $0 }))
    }

    private func listField(_ title: String, _ text: Binding<String>, set: @escaping ([Int]) -> Void) -> some View {
        HStack(spacing: 8) {
            FieldCaption(title)
            Spacer(minLength: 4)
            TextField("", text: text)
                .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.amber)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .frame(width: 150).gmWell()
                .onChange(of: text.wrappedValue) { v in
                    set(v.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1...40).contains($0) })
                }
        }
    }

    private func syncLists() {
        frets = defaults.file.project.markers.dotFrets.map(String.init).joined(separator: ", ")
        doubles = defaults.file.project.markers.doubleDotFrets.map(String.init).joined(separator: ", ")
    }
}
