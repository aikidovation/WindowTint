import CoreGraphics
import Foundation

/// Appends one refresh to ~/Library/Logs/WindowTint.log when the DebugLog default is true.
enum DebugLog {
    struct Row {
        let windowID: Int
        let pid: pid_t
        let bundleID: String
        let frame: CGRect
        let state: String
        let color: String
    }

    private static let queue = DispatchQueue(label: "com.aikidovation.WindowTint.log")

    /// Used for Mission Control enter/exit. Not deduped by the refresh state key.
    static func writeRaw(_ text: String) {
        guard UserDefaults.standard.bool(forKey: "DebugLog") else { return }
        let body = text.hasSuffix("\n") ? text : text + "\n"
        queue.async { append(body) }
    }

    static func write(trigger: String, onScreen: Int, zOrder: [Int], rows: [Row]) {
        guard UserDefaults.standard.bool(forKey: "DebugLog") else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let order = zOrder.map(String.init).joined(separator: ",")
        var lines = ["\(stamp) trigger=\(trigger) onScreen=\(onScreen) z=\(order)"]
        for row in rows {
            let frame = row.frame
            lines.append(
                "id=\(row.windowID) pid=\(row.pid) bundle=\(row.bundleID) " +
                "frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width))x\(Int(frame.height)) " +
                "overlay=\(row.state) color=\(row.color)"
            )
        }
        let text = lines.joined(separator: "\n") + "\n"
        queue.async { append(text) }
    }

    private static func append(_ text: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WindowTint.log")
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: url)
        }
    }
}
