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
    @Published private(set) var gcode = ""
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
            let result = await Task.detached(priority: .userInitiated) { () -> (Toolpath, [Double], String, [OperationSummary]) in
                let layout = FretboardLayout(params)
                let tp = ToolpathGenerator.generate(layout: layout, settings: s)
                let times = tp.cumulativeTimes()
                let text = GCodeWriter.write(tp, params: params)
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
                    sums.append(OperationSummary(op: op, moves: n, seconds: secs, cutLength: len))
                }
                return (tp, times, text, sums)
            }.value
            toolpath = result.0; times = result.1; gcode = result.2; summary = result.3
            generatedParams = params; generatedSettings = s
            playback.reset(total: result.1.last ?? 0)
            version += 1
            isGenerating = false
        }
    }

    /// Index of the move in progress at time `t`, and the cutter position.
    func state(at t: Double) -> (index: Int, pos: SIMD3<Double>)? {
        guard let tp = toolpath, !tp.moves.isEmpty else { return nil }
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

    func exportGCode(params: FretboardParameters) {
        guard !gcode.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "nc") ?? .plainText]
        panel.nameFieldStringValue = String(format: "fretboard_%.0fmm_%dfrets.nc", params.scaleLength, params.fretCount)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try gcode.write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
    }
}
