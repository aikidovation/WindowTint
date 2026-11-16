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

    static func write(trigger: String, onScreen: Int, rows: [Row]) {
        guard UserDefaults.standard.bool(forKey: "DebugLog") else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines = ["\(stamp) trigger=\(trigger) onScreen=\(onScreen)"]
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
