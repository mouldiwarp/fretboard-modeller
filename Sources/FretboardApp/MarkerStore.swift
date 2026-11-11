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
    @Published var trace = InlayTracer.Options() { didSet { if trace != oldValue { retrace() } } }
    @Published private(set) var sourceName = ""
    @Published private(set) var sourceImage: NSImage?
    @Published private(set) var dotsJob: MarkerJob?
    @Published private(set) var inlayJob: MarkerJob?
    @Published private(set) var isGenerating = false
    @Published private(set) var message: String?
    @Published var showToolpath = true
    @Published var zoomToInlay = true

    private struct Key: Equatable {
        var params: FretboardParameters, markers: MarkerSettings, dots: DotCutSettings, inlay: InlayCutSettings, stock: Double
    }
    private var generatedKey: Key?
    private var gray: (bytes: [UInt8], w: Int, h: Int)?
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

    func clearImage() {
        sourceImage = nil; gray = nil; sourceName = ""
        model?.markers.inlay.artwork = nil
    }

    private func setImage(_ img: NSImage, name: String) {
        guard let g = Self.grayscale(img) else { message = "Could not read the image."; return }
        sourceImage = img; sourceName = name; gray = g; message = nil
        retrace(resetSize: true)
    }

    private func retrace(resetSize: Bool = false) {
        guard let g = gray, let model else { return }
        guard let art = InlayTracer.trace(gray: g.bytes, width: g.w, height: g.h, options: trace) else {
            message = "Nothing to trace. Try another threshold, or Invert if the design is light on dark."
            model.markers.inlay.artwork = nil
            return
        }
        message = nil
        var m = model.markers
        m.inlay.artwork = art
        if resetSize {
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
