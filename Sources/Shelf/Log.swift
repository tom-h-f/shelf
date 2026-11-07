import Foundation

/// Plain append-only log at ~/Library/Logs/Shelf/shelf.log (also visible in Console.app under Log Reports).
enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Shelf")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shelf.log")
    }()

    private static let queue = DispatchQueue(label: "org.tomfrench.shelf.log")
    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ message: String, category: String = "app") {
        let now = Date()
        queue.async {
            let line = "\(stamp.string(from: now)) [\(category)] \(message)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (underlying \(underlying.domain) \(underlying.code): \(underlying.localizedDescription))"
        }
        return text
    }
}
