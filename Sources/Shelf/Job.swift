import Foundation

struct Job: Codable, Identifiable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case queued, preparing, running, done, needsAttention, failed, cancelled }

    var id = UUID()
    var input: String
    var kind: InputKind
    var created = Date()
    var state: State = .queued
    var progress = ""
    var sendToKindle: Bool
    var prepared: Prepared?
    var result: JobResult?
    var costUSD: Double?
    var error: String?
    var sentAt: Date?
    var sendError: String?
    var finished: Date?

    var displayName: String {
        if let title = result?.title, !title.isEmpty { return title }
        if kind == .url { return input }
        return URL(fileURLWithPath: prepared?.newPath ?? input).deletingPathExtension().lastPathComponent
    }

    var filedURL: URL? {
        guard let path = result?.filed_path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    var isActive: Bool { [.queued, .preparing, .running].contains(state) }
}

/// Job history as one JSON file, so Send works after a restart.
struct JobStore: Sendable {
    let file: URL

    static var standard: JobStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Shelf")
        return JobStore(file: dir.appendingPathComponent("jobs.json"))
    }

    var jobsDirectory: URL { file.deletingLastPathComponent().appendingPathComponent("jobs") }

    func load() -> [Job] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var jobs = (try? decoder.decode([Job].self, from: data)) ?? []
        for i in jobs.indices where jobs[i].isActive {
            jobs[i].state = .cancelled
            jobs[i].error = "Shelf quit while this job was running"
        }
        return jobs
    }

    /// Deletes job working folders (logs, extracted text, previews) older than `age`, unless the job is still listed.
    func pruneJobFolders(olderThan age: TimeInterval, keeping: Set<UUID>, now: Date = Date()) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: jobsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var removed = 0
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent), !keeping.contains(id),
                  let modified = try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > age else { continue }
            if (try? fm.removeItem(at: dir)) != nil { removed += 1 }
        }
        if removed > 0 { Log.write("pruned \(removed) job folders older than \(Int(age / 86400)) days", category: "jobs") }
    }

    func save(_ jobs: [Job]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(jobs) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
