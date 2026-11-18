import AppKit
import Foundation

/// Sends G-code straight to a GCode Controller hub (github.com/mouldiwarp/gcode-controller), which
/// queues it for the machine. The hub normally runs on this Mac, so the default address is localhost.
enum GCodeHub {
    static let urlKey = "gcodeHubURL"
    static let defaultURL = "http://localhost:8080"

    struct File {
        var name: String
        var content: String
        init(name: String, content: String) {
            self.name = name
            self.content = content
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The address passed in, else the one in settings, else this Mac.
    static func resolvedAddress(_ override: String? = nil) -> String {
        let s = (override ?? UserDefaults.standard.string(forKey: urlKey) ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? defaultURL : s
    }

    static var address: String { resolvedAddress() }

    /// Sends the files in order. More than one file is sent as a group (side A, side B, …) so the
    /// controller lists them together in the order they must run.
    @discardableResult
    static func send(_ files: [File], source: String, group: String?, address override: String? = nil) async throws -> Int {
        let address = resolvedAddress(override)
        guard let base = URL(string: address), base.scheme == "http" || base.scheme == "https" else {
            throw Failure(message: "The GCode Controller address \"\(address)\" isn't a valid http:// URL. Check it in Settings.")
        }
        let grouped = files.count > 1 ? group : nil
        for (i, f) in files.enumerated() {
            var req = URLRequest(url: base.appendingPathComponent("api/jobs"))
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.setValue(encode(f.name), forHTTPHeaderField: "X-Filename")
            req.setValue(encode(source), forHTTPHeaderField: "X-Source")
            if let g = grouped {
                req.setValue(encode(g), forHTTPHeaderField: "X-Group")
                req.setValue(String(i + 1), forHTTPHeaderField: "X-Group-Index")
            }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.upload(for: req, from: Data(f.content.utf8))
            } catch let e as URLError where [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost].contains(e.code) {
                throw Failure(message: "GCode Controller isn't reachable at \(address). Start the hub (Start Hub.command), then try again.")
            }
            guard let http = response as? HTTPURLResponse else { throw Failure(message: "No reply from GCode Controller.") }
            if http.statusCode != 201 && http.statusCode != 200 {
                let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                throw Failure(message: "GCode Controller refused \(f.name): \(reason ?? "HTTP \(http.statusCode)")")
            }
        }
        return files.count
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "%"))) ?? s
    }
}


/// Sends one G-code file to GCode Controller and reports the result, for the SEND buttons.
@MainActor
func sendToGCodeController(name: String, content: String) {
    sendToGCodeController([GCodeHub.File(name: name, content: content)], group: nil)
}

/// Sends several files as one group, in run order (for example the board job, then the nut slot job).
@MainActor
func sendToGCodeController(_ files: [GCodeHub.File], group: String?) {
    Task { @MainActor in
        let alert = NSAlert()
        let name = files.count == 1 ? files[0].name : "\(files.count) files"
        do {
            try await GCodeHub.send(files, source: "Fretboard Modeller", group: group)
            alert.messageText = "Sent to GCode Controller"
            alert.informativeText = files.count == 1 ? "\(name) is in the controller's library, ready to run."
                : "\(name) are in the controller's library as \"\(group ?? "")\", in the order to run them."
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Couldn't send \(name)"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}
