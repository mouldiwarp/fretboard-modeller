import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FretboardKit

/// State for the Markers tab: the inlay image and its tracing, the two cutting jobs, generation and export.
/// The marker geometry itself lives in `ModelStore.markers` so the Designer model shows the pockets.
@MainActor
final class MarkerStore: ObservableObject {
    @Published var dots = DotCutSettings()
    @Published var inlay = InlayCutSettings()
    @Published var trace = InlayTracer.Options() { didSet { if trace != oldValue && !restoring { retrace() } } }
    @Published private(set) var sourceName = ""
    @Published private(set) var sourceImage: NSImage?
    @Published private(set) var dotsJob: MarkerJob?
    @Published private(set) var inlayJob: MarkerJob?
    @Published private(set) var isGenerating = false
    @Published private(set) var message: String?
    /// Players for the 3D view of each job (rebuilt when the jobs are generated).
    @Published private(set) var dotsPlayer: JobPlayer?
    @Published private(set) var inlayPlayer: JobPlayer?
    /// PNG of the grayscale source image, saved with the project.
    @Published private(set) var imageData: Data?
    @Published var showToolpath = true
    @Published var zoomToInlay = true

    private struct Key: Equatable {
        var params: FretboardParameters, markers: MarkerSettings, dots: DotCutSettings, inlay: InlayCutSettings, stock: Double
    }
    private var generatedKey: Key?
    private var gray: (bytes: [UInt8], w: Int, h: Int)?
    private var restoring = false
    private var generation = 0
    weak var model: ModelStore?

    func isStale(_ m: ModelStore, cnc: CNCSettings) -> Bool {
        (dotsJob != nil || inlayJob != nil) && generatedKey != key(m, cnc)
    }

    private func key(_ m: ModelStore, _ cnc: CNCSettings) -> Key {
        Key(params: m.params, markers: m.markers, dots: dots, inlay: inlay, stock: cnc.stockThickness)
    }

    // MARK: Image input

    func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .pdf, .bmp, .gif, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    func load(url: URL) {
        guard let img = NSImage(contentsOf: url) else { message = "Could not read \(url.lastPathComponent)."; return }
        setImage(img, name: url.lastPathComponent)
    }

    func paste() {
        let pb = NSPasteboard.general
        guard let img = NSImage(pasteboard: pb) else { message = "There is no image on the clipboard."; return }
        setImage(img, name: "Pasted image")
    }

    /// Lets the user drag out a region of the screen (or press Space to pick a window), then traces it.
    func captureScreen() {
        let before = NSPasteboard.general.changeCount
        NSApp.hide(nil)
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-c"]
            try? p.run()
            p.waitUntilExit()
            await MainActor.run {
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                if NSPasteboard.general.changeCount != before, let img = NSImage(pasteboard: .general) {
                    self.setImage(img, name: "Screen capture")
                } else {
                    self.message = "No capture taken. If nothing happened, allow Screen Recording for this app in System Settings › Privacy & Security."
                }
            }
        }
    }

    /// Height (across the board) of the bundled default inlay.
    static let defaultInlayHeight = 45.0

    static let defaultInlayImage: NSImage? = {
        let candidates = [
            Bundle.main.url(forResource: "default-inlay", withExtension: "png"),
            // `swift run` during development: use the copy in the repository.
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../Assets/default-inlay.png").standardized,
        ]
        return candidates.compactMap { $0 }.lazy.compactMap { NSImage(contentsOf: $0) }.first
    }()

    /// Traces the bundled default design, 45 mm tall, used when a 12th-fret inlay is chosen with no image.
    func useDefaultImage() {
        guard let img = Self.defaultInlayImage else { return }
        setImage(img, name: "Default inlay", height: Self.defaultInlayHeight)
    }

    func clearImage() {
        sourceImage = nil; gray = nil; sourceName = ""; imageData = nil
        model?.markers.inlay.artwork = nil
    }

    private func setImage(_ img: NSImage, name: String, height: Double? = nil) {
        guard let g = Self.grayscale(img) else { message = "Could not read the image."; return }
        sourceImage = img; sourceName = name; gray = g; message = nil
        imageData = Self.png(g)
        retrace(resetSize: true, height: height)
    }

    /// `height`: start at this height (across the board) instead of the automatic size.
    private func retrace(resetSize: Bool = false, height: Double? = nil) {
        guard let g = gray, let model else { return }
        guard let art = InlayTracer.trace(gray: g.bytes, width: g.w, height: g.h, options: trace) else {
            message = "Nothing to trace. Try another threshold, or Invert if the design is light on dark."
            model.markers.inlay.artwork = nil
            return
        }
        message = nil
        var m = model.markers
        m.inlay.artwork = art
        if resetSize, let h = height {
            m.inlay.height = h
            m.inlay.width = h * art.aspect
            if m.mode == .none || m.mode == .dots { m.mode = .dotsAndInlay }
        } else if resetSize {
            // Start at a size that fits comfortably across the 12th fret.
            let L = model.layout
            let maxW = 2 * L.taperHalfWidth(at: MarkerSettings.spaceCentreX(L, m.inlay.fret)) - 12
            m.inlay.height = min(maxW, 20)
            m.inlay.width = m.inlay.height * art.aspect
            if m.inlay.width > 50 { m.inlay.width = 50; m.inlay.height = 50 / art.aspect }
            if m.mode == .none || m.mode == .dots { m.mode = .dotsAndInlay }
        } else if m.inlay.lockAspect {
            m.inlay.height = m.inlay.width / art.aspect
        }
        model.markers = m
    }

    /// Renders the image onto white as 8-bit gray, scaled so the long side is 600...1600 px.
    static func grayscale(_ img: NSImage) -> (bytes: [UInt8], w: Int, h: Int)? {
        var rect = CGRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let long = Double(max(cg.width, cg.height))
        let scale = long < 600 ? 600 / long : min(1, 1600 / long)
        let w = max(3, Int(Double(cg.width) * scale)), h = max(3, Int(Double(cg.height) * scale))
        var bytes = [UInt8](repeating: 255, count: w * h)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (bytes, w, h) : nil
    }

    /// Restores the state saved in a project without re-tracing (the project carries the traced artwork).
    func restore(image: ProjectFile.SourceImage?, trace t: InlayTracer.Options, dots d: DotCutSettings, inlay i: InlayCutSettings) {
        restoring = true
        defer { restoring = false }
        trace = t; dots = d; inlay = i
        message = nil
        dotsJob = nil; inlayJob = nil; dotsPlayer = nil; inlayPlayer = nil; generatedKey = nil
        if let image, let rep = NSBitmapImageRep(data: image.png) {
            let img = NSImage(size: rep.size); img.addRepresentation(rep)
            gray = Self.grayscale(img); sourceImage = img; sourceName = image.name; imageData = image.png
        } else {
            gray = nil; sourceImage = nil; sourceName = ""; imageData = nil
        }
    }

    static func png(_ g: (bytes: [UInt8], w: Int, h: Int)) -> Data? {
        guard let provider = CGDataProvider(data: Data(g.bytes) as CFData),
              let cg = CGImage(width: g.w, height: g.h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: g.w,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    // MARK: Jobs

    func generate(_ m: ModelStore, cnc: CNCSettings) {
        guard !isGenerating, m.errors.isEmpty, m.markerErrors.isEmpty else { return }
        isGenerating = true
        let k = key(m, cnc)
        let params = m.params, markers = m.markers, ds = dots, ins = inlay
        Task {
            let r = await Task.detached(priority: .userInitiated) { () -> (MarkerJob?, MarkerJob?) in
                let L = FretboardLayout(params)
                return (MarkerToolpath.dots(layout: L, markers: markers, settings: ds, cnc: cnc),
                        MarkerToolpath.inlay(layout: L, markers: markers, settings: ins, cnc: cnc))
            }.value
            dotsJob = r.0; inlayJob = r.1
            generation += 1
            dotsPlayer = r.0.map { JobPlayer($0.displayToolpath, version: generation * 2) }
            inlayPlayer = r.1.map { JobPlayer($0.displayToolpath, version: generation * 2 + 1) }
            generatedKey = k
            isGenerating = false
        }
    }

    func export(_ job: MarkerJob?, name: String) {
        guard let job else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "nc") ?? .plainText]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try job.gcode.write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
    }
}

/// Simulated playback of one marker job, in the board job's machine coordinates.
@MainActor
final class JobPlayer: ObservableObject {
    let toolpath: Toolpath
    let times: [Double]
    let version: Int
    let playback = Playback()

    init(_ tp: Toolpath, version: Int) {
        toolpath = tp
        times = tp.cumulativeTimes()
        self.version = version
        playback.speed = 10
        playback.reset(total: times.last ?? 0)
    }

    func state(at t: Double) -> (index: Int, pos: SIMD3<Double>)? { toolpathState(toolpath, times: times, at: t) }
}
