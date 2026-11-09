import SwiftUI
import simd
import SceneKit
import FretboardKit

enum ViewPreset: String, CaseIterable, Identifiable {
    case iso, top, side, heelEnd, nutEnd
    var id: String { rawValue }
    var title: String {
        switch self {
        case .iso: return "3D"
        case .top: return "Top"
        case .side: return "Side"
        case .heelEnd: return "Heel end"
        case .nutEnd: return "Nut end"
        }
    }
}

/// SCNView that adds Command+scroll (works with Magic Mouse) and pinch zooming.
final class ZoomSCNView: SCNView {
    var zoomTarget = SCNVector3Zero
    /// Called when the view is resized before the user has moved the camera, so framing can follow the new shape.
    var onResize: (() -> Void)?
    private var userMoved = false
    private var lastSize = CGSize.zero

    override func layout() {
        super.layout()
        if bounds.size != lastSize, bounds.width > 0, bounds.height > 0 {
            lastSize = bounds.size
            if !userMoved { onResize?() }
        }
    }

    override func mouseDown(with event: NSEvent) { userMoved = true; super.mouseDown(with: event) }
    func resetUserMoved() { userMoved = false }

    private func zoom(by factor: CGFloat) {
        guard let node = pointOfView else { return }
        let p = node.worldPosition, t = zoomTarget
        let dx = p.x - t.x, dy = p.y - t.y, dz = p.z - t.z
        let dist = (dx * dx + dy * dy + dz * dz).squareRoot()
        let newDist = min(5000, max(15, dist * factor))
        let f = node.worldFront
        let move = dist - newDist
        node.worldPosition = SCNVector3(p.x + f.x * move, p.y + f.y * move, p.z + f.z * move)
    }

    override func scrollWheel(with event: NSEvent) {
        userMoved = true
        guard event.modifierFlags.contains(.command) else { super.scrollWheel(with: event); return }
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        zoom(by: CGFloat(exp(-Double(dy) * 0.01)))
    }

    override func magnify(with event: NSEvent) {
        userMoved = true
        zoom(by: max(0.1, 1 - event.magnification))
    }
}

/// SceneKit viewer. Model coordinates (X length, Y width, Z up) are kept inside a node
/// rotated -90° about X so SceneKit's Y-up world shows the board upright.
struct ModelViewer: NSViewRepresentable {
    let mesh: IndexedMesh
    let layout: FretboardLayout
    let meshVersion: Int
    let preset: ViewPreset
    let presetToken: Int
    let showFrets: Bool
    let showDimensions: Bool
    @Binding var picks: [SIMD3<Double>]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = ZoomSCNView()
        let scene = SCNScene()
        view.scene = scene
        view.backgroundColor = NSColor(srgbRed: 0x0A / 255, green: 0x0A / 255, blue: 0x0A / 255, alpha: 1)
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false

        let c = context.coordinator
        scene.rootNode.addChildNode(c.modelNode)
        c.modelNode.eulerAngles.x = -.pi / 2

        let cam = SCNCamera()
        cam.zNear = 1
        cam.zFar = 10000
        cam.fieldOfView = 35
        c.cameraNode.camera = cam
        scene.rootNode.addChildNode(c.cameraNode)
        view.pointOfView = c.cameraNode

        let key = SCNNode()
        key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 1100
        key.eulerAngles = SCNVector3(-0.9, 0.5, 0)
        let fill = SCNNode()
        fill.light = SCNLight(); fill.light!.type = .directional; fill.light!.intensity = 450
        fill.eulerAngles = SCNVector3(-0.4, -2.4, 0)
        let amb = SCNNode()
        amb.light = SCNLight(); amb.light!.type = .ambient; amb.light!.intensity = 350
        [key, fill, amb].forEach { scene.rootNode.addChildNode($0) }

        let click = NSClickGestureRecognizer(target: c, action: #selector(Coordinator.handleClick(_:)))
        view.addGestureRecognizer(click)
        c.view = view
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        c.picksBinding = $picks

        if c.builtVersion != meshVersion || c.builtOnce == false {
            c.rebuild(mesh: mesh, layout: layout)
            if !c.builtOnce { c.frame(preset: preset, layout: layout) }
            c.builtVersion = meshVersion
            c.builtOnce = true
        }
        if c.lastPresetToken != presetToken {
            c.lastPresetToken = presetToken
            c.frame(preset: preset, layout: layout)
        }
        c.fretNode.isHidden = !showFrets
        c.dimNode.isHidden = !showDimensions
        c.updatePicks(picks)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject {
        let modelNode = SCNNode()
        let boardNode = SCNNode()
        let fretNode = SCNNode()
        let dimNode = SCNNode()
        let pickNode = SCNNode()
        let cameraNode = SCNNode()
        weak var view: ZoomSCNView?
        var picksBinding: Binding<[SIMD3<Double>]>?
        var builtVersion = -1
        var builtOnce = false
        var lastPresetToken = 0

        override init() {
            super.init()
            [boardNode, fretNode, dimNode, pickNode].forEach { modelNode.addChildNode($0) }
        }

        func rebuild(mesh: IndexedMesh, layout L: FretboardLayout) {
            boardNode.geometry = Self.geometry(from: mesh)
            fretNode.childNodes.forEach { $0.removeFromParentNode() }
            dimNode.childNodes.forEach { $0.removeFromParentNode() }
            addFrets(L)
            addDimensions(L)
        }

        // MARK: Geometry

        /// Smooth normals on the curved top surface, flat normals everywhere else.
        static func geometry(from mesh: IndexedMesh) -> SCNGeometry {
            var positions: [SCNVector3] = []
            var normals: [SCNVector3] = []
            var indices: [Int32] = []

            var smooth = [SIMD3<Double>](repeating: .zero, count: mesh.vertices.count)
            var isTop = [Bool](repeating: false, count: mesh.triangleCount)
            for i in 0..<mesh.triangleCount {
                let t = mesh.triangle(i)
                let n = t.normal
                if n.z > 0.2 {
                    isTop[i] = true
                    let tri = mesh.triangles[i]
                    for v in [tri.x, tri.y, tri.z] { smooth[Int(v)] += n }
                }
            }
            func sv(_ p: SIMD3<Double>) -> SCNVector3 { SCNVector3(p.x, p.y, p.z) }
            for i in 0..<mesh.triangleCount {
                let tri = mesh.triangles[i]
                let t = mesh.triangle(i)
                let flat = t.normal
                for (k, v) in [tri.x, tri.y, tri.z].enumerated() {
                    positions.append(sv([t.a, t.b, t.c][k]))
                    let n: SIMD3<Double>
                    if isTop[i] {
                        let s = smooth[Int(v)]
                        let len = simd_length(s)
                        n = len > 0 ? s / len : flat
                    } else { n = flat }
                    normals.append(sv(n))
                    indices.append(Int32(positions.count - 1))
                }
            }
            let g = SCNGeometry(
                sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
                elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
            )
            let mat = SCNMaterial()
            mat.diffuse.contents = NSColor(calibratedRed: 0.36, green: 0.20, blue: 0.12, alpha: 1)
            mat.specular.contents = NSColor(white: 0.35, alpha: 1)
            mat.shininess = 0.35
            mat.lightingModel = .blinn
            g.materials = [mat]
            return g
        }

        static func lines(_ segs: [(SIMD3<Double>, SIMD3<Double>)], color: NSColor) -> SCNNode {
            var pts: [SCNVector3] = []
            var idx: [Int32] = []
            for (a, b) in segs {
                pts.append(SCNVector3(a.x, a.y, a.z)); pts.append(SCNVector3(b.x, b.y, b.z))
                idx.append(Int32(pts.count - 2)); idx.append(Int32(pts.count - 1))
            }
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pts)],
                                elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
            let m = SCNMaterial()
            m.diffuse.contents = color
            m.emission.contents = color
            m.lightingModel = .constant
            g.materials = [m]
            return SCNNode(geometry: g)
        }

        static func label(_ s: String, at p: SIMD3<Double>, color: NSColor) -> SCNNode {
            let t = SCNText(string: s, extrusionDepth: 0.05)
            t.font = NSFont.systemFont(ofSize: 3.2, weight: .medium)
            t.flatness = 0.1
            let m = SCNMaterial()
            m.diffuse.contents = color; m.emission.contents = color; m.lightingModel = .constant
            t.materials = [m]
            let n = SCNNode(geometry: t)
            let (mn, mx) = n.boundingBox
            n.pivot = SCNMatrix4MakeTranslation((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, 0)
            n.position = SCNVector3(p.x, p.y, p.z)
            return n
        }

        func addFrets(_ L: FretboardLayout) {
            var segs: [(SIMD3<Double>, SIMD3<Double>)] = []
            for n in 1...L.params.fretCount {
                let x = L.fretX(n)
                let hw = L.taperHalfWidth(at: x)
                let steps = 40
                for s in 0..<steps {
                    let y0 = -hw + 2 * hw * Double(s) / Double(steps)
                    let y1 = -hw + 2 * hw * Double(s + 1) / Double(steps)
                    segs.append((SIMD3(x, y0, L.topZ(x: x, y: y0) + 0.05), SIMD3(x, y1, L.topZ(x: x, y: y1) + 0.05)))
                }
            }
            // nut line
            let hwN = L.taperHalfWidth(at: L.xNut)
            segs.append((SIMD3(L.xNut, -hwN, L.topZ(x: L.xNut, y: -hwN) + 0.05),
                         SIMD3(L.xNut, hwN, L.topZ(x: L.xNut, y: hwN) + 0.05)))
            fretNode.addChildNode(Self.lines(segs, color: NSColor(calibratedRed: 0.85, green: 0.85, blue: 0.9, alpha: 1)))
        }

        func addDimensions(_ L: FretboardLayout) {
            let col = NSColor(srgbRed: 0xC5 / 255, green: 0xA0 / 255, blue: 0x59 / 255, alpha: 1)   // gold
            let hwMax = L.taperHalfWidth(at: L.cornerTangentX)
            var segs: [(SIMD3<Double>, SIMD3<Double>)] = []

            // Overall length
            let yL = -(hwMax + 9)
            segs += [(SIMD3(0, yL, 0), SIMD3(L.xEnd, yL, 0)),
                     (SIMD3(0, yL - 2, 0), SIMD3(0, yL + 2, 0)),
                     (SIMD3(L.xEnd, yL - 2, 0), SIMD3(L.xEnd, yL + 2, 0))]
            dimNode.addChildNode(Self.label(String(format: "%.1f mm", L.xEnd),
                                            at: SIMD3(L.xEnd / 2, yL - 4, 0), color: col))

            // Width at last fret and at nut
            for (x, name) in [(L.xLastFret, "last fret"), (L.xNut, "nut")] {
                let hw = L.taperHalfWidth(at: x)
                let y = hw + 6
                segs += [(SIMD3(x, -hw, 0), SIMD3(x, -hw - 6, 0)), (SIMD3(x, hw, 0), SIMD3(x, hw + 6, 0))]
                segs.append((SIMD3(x, -hw - 4, 0), SIMD3(x, hw + 4, 0)))
                dimNode.addChildNode(Self.label(String(format: "%.1f (%@)", 2 * hw, name),
                                                at: SIMD3(x, y + 3, 0), color: col))
            }
            dimNode.addChildNode(Self.lines(segs, color: col))
        }

        // MARK: Camera

        func frame(preset: ViewPreset, layout L: FretboardLayout) {
            let center = SIMD3<Double>(L.xEnd / 2, 0, 3)
            let d = max(L.xEnd, 120) * 1.7
            let dir: SIMD3<Double>
            let upModel: SIMD3<Double>
            switch preset {
            case .iso: dir = simd_normalize(SIMD3(-0.35, -0.85, 0.6)); upModel = SIMD3(0, 0, 1)
            case .top: dir = SIMD3(0, 0, 1); upModel = SIMD3(0, 1, 0)
            case .side: dir = SIMD3(0, -1, 0); upModel = SIMD3(0, 0, 1)
            case .heelEnd: dir = SIMD3(-1, 0, 0); upModel = SIMD3(0, 0, 1)
            case .nutEnd: dir = SIMD3(1, 0, 0); upModel = SIMD3(0, 0, 1)
            }
            var dist = d
            if preset == .heelEnd || preset == .nutEnd { dist = 220 }
            func world(_ p: SIMD3<Double>) -> SCNVector3 { SCNVector3(p.x, p.z, -p.y) }
            let eye = center + dir * dist
            cameraNode.position = world(eye)
            view?.zoomTarget = world(center)
            cameraNode.look(at: world(center), up: world(upModel), localFront: SCNVector3(0, 0, -1))
        }

        // MARK: Picking

        @objc func handleClick(_ g: NSClickGestureRecognizer) {
            guard let view else { return }
            let p = g.location(in: view)
            let hits = view.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
            guard let hit = hits.first(where: { $0.node === boardNode }) else { return }
            let lc = hit.localCoordinates
            let pt = SIMD3<Double>(Double(lc.x), Double(lc.y), Double(lc.z))
            guard let b = picksBinding else { return }
            var arr = b.wrappedValue
            if arr.count >= 2 { arr = [] }
            arr.append(pt)
            b.wrappedValue = arr
        }

        func updatePicks(_ picks: [SIMD3<Double>]) {
            pickNode.childNodes.forEach { $0.removeFromParentNode() }
            let col = NSColor(srgbRed: 1.0, green: 0xB5 / 255, blue: 0x4A / 255, alpha: 1)   // amber
            for p in picks {
                let s = SCNSphere(radius: 0.8)
                let m = SCNMaterial(); m.diffuse.contents = col; m.emission.contents = col; m.lightingModel = .constant
                s.materials = [m]
                let n = SCNNode(geometry: s)
                n.position = SCNVector3(p.x, p.y, p.z)
                pickNode.addChildNode(n)
            }
            if picks.count == 2 {
                pickNode.addChildNode(Self.lines([(picks[0], picks[1])], color: col))
                let mid = (picks[0] + picks[1]) / 2 + SIMD3(0, 0, 3)
                pickNode.addChildNode(Self.label(String(format: "%.2f mm", simd_length(picks[1] - picks[0])), at: mid, color: col))
            }
        }
    }
}
