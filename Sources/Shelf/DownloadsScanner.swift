import Foundation

enum InputKind: String, Codable, Sendable {
    case pdf, epub, html, markdown, url

    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "pdf": self = .pdf
        case "epub": self = .epub
        case "html", "htm": self = .html
        case "md", "markdown": self = .markdown
        default: return nil
        }
    }

    var needsPrepare: Bool { self == .pdf || self == .epub }
}

struct DownloadItem: Identifiable, Hashable, Sendable {
    let url: URL
    let kind: InputKind
    let added: Date
    let bytes: Int64

    var id: URL { url }

    /// "Title - Author" from an Anna's Archive name, otherwise the file name without extension.
    var displayName: String {
        let stem = url.deletingPathExtension().lastPathComponent
        let parts = stem.components(separatedBy: " -- ")
        guard parts.count >= 3, parts.last?.range(of: "anna.s archive", options: [.regularExpression, .caseInsensitive]) != nil else {
            return stem
        }
        let title = parts[0].replacingOccurrences(of: " _ ", with: ": ").replacingOccurrences(of: "_ ", with: ": ")
        return "\(title) - \(parts[1])"
    }
}

struct ScanReport: Sendable {
    var items: [DownloadItem] = []
    var entries = 0
    var unsupported = 0
    var notRegular = 0
    var noDate = 0
    var tooOld = 0
    var valueErrors = 0
    var firstValueError: String?

    var summary: String {
        "\(entries) entries -> \(items.count) listed; dropped: \(unsupported) other types, \(notRegular) not files, "
            + "\(tooOld) older than cutoff, \(noDate) without a date, \(valueErrors) unreadable"
            + (firstValueError.map { " (first: \($0))" } ?? "")
    }
}

struct DownloadsScanner: Sendable {
    let folder: URL
    var maxAge: TimeInterval = 14 * 24 * 3600
    var limit = 15

    func scan(now: Date = Date()) throws -> [DownloadItem] {
        try report(now: now).items
    }

    func report(now: Date = Date()) throws -> ScanReport {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )
        var r = ScanReport(entries: urls.count)
        var items: [DownloadItem] = []
        for url in urls {
            guard let kind = InputKind(fileExtension: url.pathExtension) else { r.unsupported += 1; continue }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                r.valueErrors += 1
                if r.firstValueError == nil { r.firstValueError = "\(url.lastPathComponent): \(Log.describe(error))" }
                continue
            }
            guard values.isRegularFile == true else { r.notRegular += 1; continue }
            guard let added = values.addedToDirectoryDate ?? values.creationDate else { r.noDate += 1; continue }
            guard now.timeIntervalSince(added) <= maxAge else { r.tooOld += 1; continue }
            items.append(DownloadItem(url: url, kind: kind, added: added, bytes: Int64(values.fileSize ?? 0)))
        }
        r.items = Array(items.sorted { $0.added > $1.added }.prefix(limit))
        return r
    }
}
