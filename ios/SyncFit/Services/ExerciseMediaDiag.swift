import Foundation

/// Dual sink for ExerciseMedia diagnostics: NSLog (Xcode console) + Documents file
/// (readable via `simctl get_app_container` when stdout/stderr capture is empty).
///
/// Entirely DEBUG-only — Release builds compile these methods to no-ops so no
/// NSLog or Documents/`exercise_media_diag.log` I/O occurs in production.
enum ExerciseMediaDiag {
    static func log(_ message: String) {
        #if DEBUG
        let line = message.hasPrefix("[") ? message : "[ExerciseMedia] \(message)"
        NSLog("%@", line)
        appendToFile(line)
        #endif
    }

    static func logGIF(_ message: String) {
        #if DEBUG
        let line = message.hasPrefix("[") ? message : "[AnimatedGIFWebView] \(message)"
        NSLog("%@", line)
        appendToFile(line)
        #endif
    }

    #if DEBUG
    private static let fileName = "exercise_media_diag.log"
    private static let lock = NSLock()

    private static func appendToFile(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let url = dir.appendingPathComponent(fileName)
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let data = stamped.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName)
    }

    static func resetFile() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
    #endif
}
