import SwiftUI
import SceneKit
import simd
import FretboardKit

func opColor(_ op: CutOperation) -> NSColor {
    switch op {
    case .roughSurface: return NSColor(srgbRed: 0xC5 / 255, green: 0xA0 / 255, blue: 0x59 / 255, alpha: 1)   // gold
    case .roughOutline: return NSColor(srgbRed: 1.0, green: 0xB5 / 255, blue: 0x4A / 255, alpha: 1)          // amber
    case .finishSurface: return NSColor(srgbRed: 0x86 / 255, green: 0xA2 / 255, blue: 0xBD / 255, alpha: 1)  // haze
    case .finishOutline: return NSColor(srgbRed: 0x9B / 255, green: 0xD8 / 255, blue: 0x6A / 255, alpha: 1)  // green
    }
}

/// Shows the toolpath, the board and a cutter that follows the simulated run.
struct ToolpathViewer: NSViewRepresentable {
    let toolpath: Toolpath
    let layout: FretboardLayout
    let mesh: IndexedMesh
    let version: Int
    let showRapids: Bool
    let showBoard: Bool
    let preset: ViewPreset
    let presetToken: Int
    let state: (index: Int, pos: SIMD3<Double>)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ZoomSCNView {
        let view = ZoomSCNView()
        let scene = SCNScene()
        view.scene = scene
        view.backgroundColor = NSColor(srgbRed: 0x0A / 255, green: 0x0A / 255, blue: 0x0A / 255, alpha: 1)
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        let c = context.coordinator
        scene.rootNode.addChildNode(c.modelNode)
        c.modelNode.eulerAngles.x = -.pi / 2
        let cam = SCNCamera()
        cam.zNear = 1; cam.zFar = 10000; cam.fieldOfView = 35
        c.cameraNode.camera = cam
        scene.rootNode.addChildNode(c.cameraNode)
        view.pointOfView = c.cameraNode

        let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 1000
        key.eulerAngles = SCNVector3(-0.9, 0.5, 0)
        let amb = SCNNode(); amb.light = SCNLight(); amb.light!.type = .ambient; amb.light!.intensity = 450
        scene.rootNode.addChildNode(key); scene.rootNode.addChildNode(amb)
        c.view = view
        return view
    }

    func updateNSView(_ view: ZoomSCNView, context: Context) {
        let c = context.coordinator
        if c.builtVersion != version {
            c.rebuild(toolpath: toolpath, layout: layout, mesh: mesh)
            c.frame(preset: preset, layout: layout, T: toolpath.settings.stockThickness)
            c.builtVersion = version
            c.lastPresetToken = presetToken
        }
        if c.lastPresetToken != presetToken {
            c.lastPresetToken = presetToken
            c.frame(preset: preset, layout: layout, T: toolpath.settings.stockThickness)
        }
        c.ghostNode.isHidden = !showBoard
        c.showRapids = showRapids
        if let s = state { c.update(index: s.index, pos: s.pos) }
    }

    @MainActor
    final class Coordinator {
        struct Chunk { var start: Int; var end: Int; var op: CutOperation; var kind: MoveKind; var node: SCNNode }

        let modelNode = SCNNode()
        let ghostNode = SCNNode()
        let pendingNode = SCNNode()
        let chunkRoot = SCNNode()
        let partialNode = SCNNode()
        let toolNode = SCNNode()
        let stockNode = SCNNode()
        let cameraNode = SCNNode()
        weak var view: ZoomSCNView?
        var builtVersion = -1
        var lastPresetToken = 0
        var showRapids = true
        var chunks: [Chunk] = []
        var from: [SIMD3<Double>] = []
        var to: [SIMD3<Double>] = []
        var ops: [CutOperation] = []
        var kinds: [MoveKind] = []
        var lastIndex = -1
        var lastShowRapids = true

        init() {
            [stockNode, ghostNode, pendingNode, chunkRoot, partialNode, toolNode].forEach { modelNode.addChildNode($0) }
        }

        func rebuild(toolpath tp: Toolpath, layout L: FretboardLayout, mesh: IndexedMesh) {
            let T = tp.settings.stockThickness
            [ghostNode, pendingNode, chunkRoot, partialNode, toolNode, stockNode].forEach { n in
                n.childNodes.forEach { $0.removeFromParentNode() }
                n.geometry = nil
            }
            chunks = []; from = []; to = []; ops = []; kinds = []; lastIndex = -1

            // Board (ghost), bottom of the board at the bottom of the stock.
            let g = ModelViewer.Coordinator.geometry(from: mesh)
            g.materials.forEach { $0.transparency = 0.45; $0.isDoubleSided = true }
            ghostNode.geometry = g
            ghostNode.position = SCNVector3(0, 0, -T)

            // Segments
            var p = tp.start
            for m in tp.moves { from.append(p); to.append(m.to); ops.append(m.op); kinds.append(m.kind); p = m.to }

            // Stock outline from the extent of the roughing passes.
            var minP = SIMD3<Double>(repeating: .infinity), maxP = SIMD3<Double>(repeating: -.infinity)
            for (i, m) in tp.moves.enumerated() where m.op == .roughSurface && m.kind == .cut {
                minP = simd_min(minP, to[i]); maxP = simd_max(maxP, to[i])
            }
            if minP.x.isFinite {
                let r = tp.settings.cutterRadius
                let x0 = minP.x - r, x1 = maxP.x + r, y0 = minP.y - r, y1 = maxP.y + r
                var segs: [(SIMD3<Double>, SIMD3<Double>)] = []
                for z in [0.0, -T] {
                    segs += [(SIMD3(x0, y0, z), SIMD3(x1, y0, z)), (SIMD3(x1, y0, z), SIMD3(x1, y1, z)),
                             (SIMD3(x1, y1, z), SIMD3(x0, y1, z)), (SIMD3(x0, y1, z), SIMD3(x0, y0, z))]
                }
                for (x, y) in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)] { segs.append((SIMD3(x, y, 0), SIMD3(x, y, -T))) }
                stockNode.addChildNode(ModelViewer.Coordinator.lines(segs, color: NSColor(white: 0.32, alpha: 1)))
            }

            // Dim preview of every cutting move.
            var pend: [(SIMD3<Double>, SIMD3<Double>)] = []
            for i in 0..<tp.moves.count where kinds[i] == .cut { pend.append((from[i], to[i])) }
            pendingNode.addChildNode(ModelViewer.Coordinator.lines(pend, color: NSColor(white: 0.22, alpha: 1)))

            // Revealed chunks (same op & kind, up to 400 moves).
            var start = 0
            while start < tp.moves.count {
                var end = start + 1
                while end < tp.moves.count, end - start < 400, ops[end] == ops[start], kinds[end] == kinds[start] { end += 1 }
                let color = kinds[start] == .rapid ? NSColor(srgbRed: 0x8E / 255, green: 0x8E / 255, blue: 0x8E / 255, alpha: 1)
                                                   : opColor(ops[start])
                let segs = (start..<end).map { (from[$0], to[$0]) }
                let node = ModelViewer.Coordinator.lines(segs, color: color)
                node.isHidden = true
                chunkRoot.addChildNode(node)
                chunks.append(Chunk(start: start, end: end, op: ops[start], kind: kinds[start], node: node))
                start = end
            }

            // Cutter
            let r = tp.settings.cutterRadius, h = 25.0
            let cyl = SCNCylinder(radius: r, height: h)
            let mat = SCNMaterial()
            mat.diffuse.contents = NSColor(white: 0.8, alpha: 1); mat.specular.contents = NSColor(white: 1, alpha: 1)
            mat.transparency = 0.8; mat.lightingModel = .blinn
            cyl.materials = [mat]
            let body = SCNNode(geometry: cyl)
            body.eulerAngles.x = .pi / 2
            body.position = SCNVector3(0, 0, h / 2)
            toolNode.addChildNode(body)
            if tp.settings.cutter == .ball {
                let tipSphere = SCNNode(geometry: SCNSphere(radius: r)); tipSphere.geometry?.materials = [mat]
                tipSphere.position = SCNVector3(0, 0, r)
                toolNode.addChildNode(tipSphere); body.position = SCNVector3(0, 0, h / 2 + r)
            }
            update(index: 0, pos: tp.start)
        }

        func update(index: Int, pos: SIMD3<Double>) {
            toolNode.position = SCNVector3(pos.x, pos.y, pos.z)
            guard !chunks.isEmpty else { return }
            let rapidsChanged = lastShowRapids != showRapids
            lastShowRapids = showRapids
            // Completed chunks
            if index != lastIndex || rapidsChanged {
                for ch in chunks {
                    let visible = ch.end <= index && (ch.kind == .cut || showRapids)
                    if ch.node.isHidden == visible { ch.node.isHidden = !visible }
                }
            }
            // Partially drawn chunk
            partialNode.childNodes.forEach { $0.removeFromParentNode() }
            if let ch = chunks.first(where: { $0.start <= index && index < $0.end }), ch.kind == .cut || showRapids {
                var segs = (ch.start..<index).map { (from[$0], to[$0]) }
                segs.append((from[index], pos))
                let color = ch.kind == .rapid ? NSColor(srgbRed: 0x8E / 255, green: 0x8E / 255, blue: 0x8E / 255, alpha: 1)
                                              : opColor(ch.op)
                partialNode.addChildNode(ModelViewer.Coordinator.lines(segs, color: color))
            }
            lastIndex = index
        }

        func frame(preset: ViewPreset, layout L: FretboardLayout, T: Double) {
            let center = SIMD3<Double>(L.xEnd / 2, 0, -T / 2)
            let d = max(L.xEnd, 120) * 1.7
            let dir: SIMD3<Double>, up: SIMD3<Double>
            switch preset {
            case .iso: dir = simd_normalize(SIMD3(-0.35, -0.85, 0.6)); up = SIMD3(0, 0, 1)
            case .top: dir = SIMD3(0, 0, 1); up = SIMD3(0, 1, 0)
            case .side: dir = SIMD3(0, -1, 0); up = SIMD3(0, 0, 1)
            case .heelEnd: dir = SIMD3(-1, 0, 0); up = SIMD3(0, 0, 1)
            case .nutEnd: dir = SIMD3(1, 0, 0); up = SIMD3(0, 0, 1)
            }
            let dist = (preset == .heelEnd || preset == .nutEnd) ? 220 : d
            func world(_ p: SIMD3<Double>) -> SCNVector3 { SCNVector3(p.x, p.z, -p.y) }
            cameraNode.position = world(center + dir * dist)
            view?.zoomTarget = world(center)
            cameraNode.look(at: world(center), up: world(up), localFront: SCNVector3(0, 0, -1))
        }
    }
}
