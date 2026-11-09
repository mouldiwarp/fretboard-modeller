import Foundation

public enum STLWriter {
    /// Binary STL: 80-byte header, UInt32 triangle count, then 50 bytes per triangle. Units are mm.
    public static func binary(_ mesh: IndexedMesh) -> Data {
        var data = Data(capacity: 84 + 50 * mesh.triangleCount)
        var header = [UInt8](repeating: 0, count: 80)
        let text = Array("Fretboard Modeller - units: mm".utf8)
        header.replaceSubrange(0..<min(80, text.count), with: text.prefix(80))
        data.append(contentsOf: header)
        append(UInt32(mesh.triangleCount), to: &data)
        for i in 0..<mesh.triangleCount {
            let t = mesh.triangle(i)
            for v in [t.normal, t.a, t.b, t.c] {
                append(Float(v.x), to: &data)
                append(Float(v.y), to: &data)
                append(Float(v.z), to: &data)
            }
            data.append(contentsOf: [0, 0])
        }
        return data
    }

    private static func append(_ v: UInt32, to d: inout Data) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
    }

    private static func append(_ v: Float, to d: inout Data) {
        append(v.bitPattern, to: &d)
    }
}
