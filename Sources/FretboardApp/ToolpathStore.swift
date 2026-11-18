import SwiftUI
import simd
import UniformTypeIdentifiers
import FretboardKit

/// Drives the simulated run: time in seconds along the programmed toolpath, at an accelerated rate.
@MainActor
final class Playback: ObservableObject {
    @Published var time = 0.0
    @Published var isPlaying = false
    @Published var speed = 100.0
    private(set) var total = 0.0
    private var timer: Timer?

    func reset(total: Double) {
        stop(); self.total = total; time = 0
    }

    func toggle() {
        if isPlaying { stop(); return }
        if time >= total { time = 0 }
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(1.0 / 30.0) }
        }
    }

    func stop() { timer?.invalidate(); timer = nil; isPlaying = false }

    private func tick(_ dt: Double) {
        time = min(total, time + dt * speed)
        if time >= total { stop() }
    }
}

struct OperationSummary: Identifiable {
    var id: Int { op.rawValue }
    let op: CutOperation
    let moves: Int
    let seconds: Double
    let cutLength: Double
}

@MainActor
final class ToolpathStore: ObservableObject {
    @Published var settings = CNCSettings()
    @Published private(set) var toolpath: Toolpath?
    @Published private(set) var times: [Double] = []
    /// Board job G-code. When the board is Fender-style the nut slot is a separate file, `nutGcode`.
    @Published private(set) var gcode = ""
    @Published private(set) var nutGcode = ""
    @Published private(set) var summary: [OperationSummary] = []
    @Published private(set) var version = 0
    @Published private(set) var isGenerating = false
    @Published private(set) var generatedParams: FretboardParameters?
    @Published private(set) var generatedSettings: CNCSettings?
    let playback = Playback()

    func isStale(for params: FretboardParameters) -> Bool {
        toolpath != nil && (generatedParams != params || generatedSettings != settings)
    }

    func generate(params: FretboardParameters) {
        guard !isGenerating, params.validate().isEmpty, settings.validate(for: params).isEmpty else { return }
        isGenerating = true
        let s = settings
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (Toolpath, [Double], String, String, [OperationSummary]) in
                let layout = FretboardLayout(params)
                let board = ToolpathGenerator.generate(layout: layout, settings: s)
                let text = GCodeWriter.write(board, params: params)
                // The nut slot is its own job (own bit, own file) but is previewed and timed after the board job.
                let nut = NutSlotToolpath.generate(layout: layout, settings: s)
                var tp = board
                if let nut { tp.moves += nut.toolpath.moves }
                let times = tp.cumulativeTimes()
                var sums: [OperationSummary] = []
                for op in CutOperation.allCases {
                    var n = 0, secs = 0.0, len = 0.0
                    var prevPos = tp.start, prevT = 0.0
                    for (i, m) in tp.moves.enumerated() {
                        if m.op == op {
                            n += 1; secs += times[i] - prevT
                            if m.kind == .cut { len += simd_length(m.to - prevPos) }
                        }
                        prevPos = m.to; prevT = times[i]
                    }
                    if n > 0 { sums.append(OperationSummary(op: op, moves: n, seconds: secs, cutLength: len)) }
                }
                return (tp, times, text, nut?.gcode ?? "", sums)
            }.value
            toolpath = result.0; times = result.1; gcode = result.2; nutGcode = result.3; summary = result.4
            generatedParams = params; generatedSettings = s
            playback.reset(total: result.1.last ?? 0)
            version += 1
            isGenerating = false
        }
    }

    /// Index of the move in progress at time `t`, and the cutter position.
    func state(at t: Double) -> (index: Int, pos: SIMD3<Double>)? {
        guard let tp = toolpath else { return nil }
        return toolpathState(tp, times: times, at: t)
    }

    /// Forgets the generated toolpath (for example after opening a project).
    func clear() {
        toolpath = nil; times = []; gcode = ""; nutGcode = ""; summary = []
        generatedParams = nil; generatedSettings = nil
        playback.reset(total: 0)
        version += 1
    }

    static func fileName(_ params: FretboardParameters) -> String {
        String(format: "fretboard_%.0fmm_%dfrets.nc", params.scaleLength, params.fretCount)
    }

    static func nutFileName(_ params: FretboardParameters) -> String {
        fileName(params).replacingOccurrences(of: ".nc", with: "_2_nut_slot.nc")
    }

    /// The files to run in order: the board job, then (Fender) the nut slot after a tool change.
    func jobFiles(params: FretboardParameters) -> [(name: String, content: String)] {
        guard !nutGcode.isEmpty else { return [(Self.fileName(params), gcode)] }
        return [(Self.fileName(params).replacingOccurrences(of: ".nc", with: "_1_board.nc"), gcode),
                (Self.nutFileName(params), nutGcode)]
    }

    func exportGCode(params: FretboardParameters) {
        guard !gcode.isEmpty else { return }
        if !nutGcode.isEmpty {
            // Two jobs: write both into a folder, numbered in the order to run.
            let panel = NSOpenPanel()
            panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
            panel.prompt = "Export Both"
            panel.message = "Saves the board job and the nut slot job (run after a tool change) as two G-code files."
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            do {
                for f in jobFiles(params: params) { try f.content.write(to: dir.appendingPathComponent(f.name), atomically: true, encoding: .utf8) }
            } catch { NSAlert(error: error).runModal() }
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "nc") ?? .plainText]
        panel.nameFieldStringValue = Self.fileName(params)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try gcode.write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
    }
}

/// Index of the move in progress at time `t` along `tp`, and the cutter position.
func toolpathState(_ tp: Toolpath, times: [Double], at t: Double) -> (index: Int, pos: SIMD3<Double>)? {
    guard !tp.moves.isEmpty, times.count == tp.moves.count else { return nil }
    var lo = 0, hi = times.count - 1
    while lo < hi {
        let mid = (lo + hi) / 2
        if times[mid] >= t { hi = mid } else { lo = mid + 1 }
    }
    let prevPos = lo == 0 ? tp.start : tp.moves[lo - 1].to
    let t0 = lo == 0 ? 0 : times[lo - 1]
    let dur = times[lo] - t0
    let f = dur > 1e-12 ? min(1, max(0, (t - t0) / dur)) : 1
    return (lo, prevPos + (tp.moves[lo].to - prevPos) * f)
}
