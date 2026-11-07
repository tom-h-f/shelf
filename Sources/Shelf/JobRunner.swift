import Foundation
import Observation

struct ShelfSettings: Codable, Equatable, Sendable {
    var kindleAddress = "frenchtom06_g2Shs0@kindle.com"
    var sender = "thomas.harry.french@icloud.com"
    var model = "sonnet"
    var downloads = Paths().downloads.path
    var sendByDefault = true

    static let key = "settings"

    static func load() -> ShelfSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(ShelfSettings.self, from: data) else { return ShelfSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

enum Executable {
    static func find(_ name: String) -> URL? {
        PromptBuilder.searchPath.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// Kills a process and all its descendants (claude spawns uv, pandoc, Calibre, Kindle Previewer).
enum ProcessTree {
    static func children(of pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").compactMap { pid_t($0) }
    }

    static func kill(_ pid: pid_t) {
        for child in children(of: pid) { kill(child) }
        Darwin.kill(pid, SIGTERM)
    }
}

@MainActor @Observable
final class JobRunner {
    private(set) var jobs: [Job]
    var settings: ShelfSettings { didSet { settings.save() } }
    private let store: JobStore
    private var current: Process?
    private var cancelled: Set<UUID> = []
    private var working = false
    let resources: URL

    init(store: JobStore = .standard, resources: URL = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")) {
        self.store = store
        self.resources = resources
        self.jobs = store.load()
        self.settings = ShelfSettings.load()
        store.pruneJobFolders(olderThan: 30 * 24 * 3600, keeping: Set(jobs.map(\.id)))
    }

    var isBusy: Bool { jobs.contains(where: \.isActive) }

    func enqueue(input: String, kind: InputKind, send: Bool) {
        jobs.insert(Job(input: input, kind: kind, sendToKindle: send), at: 0)
        persist()
        pump()
    }

    func cancel(_ id: UUID) {
        guard let i = index(id), jobs[i].isActive else { return }
        cancelled.insert(id)
        if jobs[i].state == .queued {
            finish(id) { $0.state = .cancelled }
        } else if let pid = current?.processIdentifier {
            ProcessTree.kill(pid)
        }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
        persist()
    }

    func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id && !$0.isActive }
        persist()
    }

    func send(_ id: UUID) {
        guard let i = index(id), let file = jobs[i].filedURL else { return }
        let mailer = KindleMailer(sender: settings.sender, kindleAddress: settings.kindleAddress, sizeLimit: KindleMailer.amazonEmailLimit)
        do {
            try mailer.send(file: file, subject: jobs[i].displayName)
            update(id) { $0.sentAt = Date(); $0.sendError = nil }
            Notifier.post(title: "Sent to Kindle", body: jobs[i].displayName)
        } catch {
            update(id) { $0.sendError = error.localizedDescription }
            Notifier.post(title: "Send to Kindle failed", body: error.localizedDescription)
        }
    }

    func logURL(_ id: UUID) -> URL { store.jobsDirectory.appendingPathComponent(id.uuidString).appendingPathComponent("job.log") }

    private func pump() {
        guard !working, let next = jobs.last(where: { $0.state == .queued }) else { return }
        working = true
        Task {
            await run(next.id)
            working = false
            pump()
        }
    }

    private func run(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let dir = store.jobsDirectory.appendingPathComponent(id.uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var input = job.input
        var prepared: Prepared?

        if job.kind.needsPrepare {
            update(id) { $0.state = .preparing; $0.progress = "Renaming and stripping metadata" }
            do {
                prepared = try await prepare(path: input, dir: dir)
                input = prepared!.newPath
                update(id) { $0.prepared = prepared }
            } catch {
                return finish(id) { $0.state = .failed; $0.error = error.localizedDescription }
            }
        }
        if cancelled.contains(id) { return finish(id) { $0.state = .cancelled } }

        update(id) { $0.state = .running; $0.progress = "Starting Claude" }
        let prompt = PromptBuilder.prompt(input: input, kind: job.kind, prepared: prepared)
        do {
            let event = try await runClaude(id: id, prompt: prompt, dir: dir)
            guard case .finished(let result, let cost, let isError, _) = event else {
                return finish(id) { $0.state = .failed; $0.error = "Claude ended without a result" }
            }
            finish(id) {
                $0.result = result
                $0.costUSD = cost
                switch (isError, result?.status) {
                case (false, .ok): $0.state = .done
                case (_, .needs_attention): $0.state = .needsAttention
                default: $0.state = .failed; $0.error = result?.summary ?? "Claude reported an error"
                }
            }
        } catch {
            return finish(id) { $0.state = self.cancelled.contains(id) ? .cancelled : .failed; $0.error = error.localizedDescription }
        }

        guard let done = jobs.first(where: { $0.id == id }) else { return }
        switch done.state {
        case .done:
            Notifier.post(title: "Filed: \(done.displayName)", body: done.result?.filed_path.replacingOccurrences(of: Paths().cloud.path + "/", with: "") ?? "")
            if done.sendToKindle { send(id) }
        case .needsAttention:
            Notifier.post(title: "Needs attention: \(done.displayName)", body: done.result?.summary ?? "")
        default:
            Notifier.post(title: "Failed: \(done.displayName)", body: done.error ?? "")
        }
    }

    private func prepare(path: String, dir: URL) async throws -> Prepared {
        guard let uv = Executable.find("uv") else { throw RunError.missing("uv") }
        let script = resources.appendingPathComponent("prepare.py")
        let (status, out) = try await Self.capture(uv, ["run", "-q", script.path, path], cwd: dir)
        try out.write(to: dir.appendingPathComponent("prepare.json"))
        guard let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any] else {
            throw RunError.failed("prepare.py gave no JSON (exit \(status))")
        }
        if let error = obj["error"] as? String { throw RunError.failed(error) }
        guard let newPath = obj["new_path"] as? String else { throw RunError.failed("prepare.py gave no path") }
        let candidates = (obj["candidates"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) }
        return Prepared(newPath: newPath, confident: obj["confident"] as? Bool ?? false, candidates: candidates)
    }

    private func runClaude(id: UUID, prompt: String, dir: URL) async throws -> StreamEvent? {
        guard let claude = Executable.find("claude") else { throw RunError.missing("claude") }
        let schema = try String(contentsOf: resources.appendingPathComponent("result-schema.json"), encoding: .utf8)
        let process = Process()
        process.executableURL = claude
        process.arguments = PromptBuilder.arguments(prompt: prompt, model: settings.model, schema: schema, settings: resources.appendingPathComponent("claude-settings.json"))
        process.currentDirectoryURL = dir
        process.environment = Self.environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle(forWritingAtPath: dir.appendingPathComponent("job.err").path) ?? FileHandle.nullDevice
        FileManager.default.createFile(atPath: dir.appendingPathComponent("job.err").path, contents: nil)
        FileManager.default.createFile(atPath: logURL(id).path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL(id))
        defer { try? log.close() }

        try process.run()
        current = process
        defer { current = nil }
        var last: StreamEvent?
        for try await line in out.fileHandleForReading.bytes.lines {
            log.write(Data((line + "\n").utf8))
            guard let event = StreamParser.parse(line: Substring(line)) else { continue }
            if case .progress(let text) = event {
                update(id) { $0.progress = text }
            } else {
                last = event
            }
        }
        process.waitUntilExit()
        if cancelled.contains(id) { throw RunError.failed("Cancelled") }
        return last
    }

    nonisolated static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = PromptBuilder.searchPath
        return env
    }

    nonisolated static func capture(_ exe: URL, _ args: [String], cwd: URL) async throws -> (Int32, Data) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.environment = environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        return await Task.detached {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, data)
        }.value
    }

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = index(id) else { return }
        change(&jobs[i])
        persist()
    }

    private func finish(_ id: UUID, _ change: (inout Job) -> Void) {
        update(id) { job in
            change(&job)
            job.finished = Date()
            job.progress = ""
        }
        cancelled.remove(id)
    }

    private func persist() { store.save(jobs) }
}

enum RunError: LocalizedError {
    case missing(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missing(let tool): "\(tool) not found on PATH"
        case .failed(let message): message
        }
    }
}
