import AppKit
import Foundation
import Observation

/// Recent downloads, refreshed whenever the folder changes. A scan failure is kept and shown, never hidden.
@MainActor @Observable
final class DownloadsModel {
    private(set) var items: [DownloadItem] = []
    private(set) var error: String?
    private(set) var access: FolderAccess?
    private(set) var lastReport: String?
    private var source: DispatchSourceFileSystemObject?
    private(set) var folder: URL?

    func watch(_ folder: URL) {
        guard folder != self.folder || source == nil else { return refresh() }
        self.folder = folder
        source?.cancel()
        source = nil
        let fd = open(folder.path, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
            s.setCancelHandler { close(fd) }
            s.resume()
            source = s
        } else {
            Log.write("cannot watch \(folder.path): errno \(errno)", category: "downloads")
        }
        refresh()
    }

    func refresh() {
        guard let folder else { return }
        let access = FolderAccess.check(folder)
        self.access = access
        Log.write("access \(folder.path): \(access)", category: "downloads")
        switch access {
        case .missing:
            items = []
            error = "\(folder.path) doesn't exist. Check the Downloads folder in Settings."
            return
        case .denied(let detail):
            items = []
            error = "Shelf isn't allowed to read \(folder.lastPathComponent) (\(detail))."
            return
        case .granted:
            break
        }
        do {
            let report = try DownloadsScanner(folder: folder).report()
            items = report.items
            error = nil
            lastReport = report.summary
            Log.write("scan: \(report.summary)", category: "downloads")
        } catch {
            items = []
            self.error = "Couldn't list \(folder.lastPathComponent): \(error.localizedDescription)"
            Log.write("scan failed: \(Log.describe(error))", category: "downloads")
        }
    }

    /// Choosing the folder in an open panel counts as user consent, which grants access without a trip to Settings.
    func requestAccess() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.message = "Choose your Downloads folder so Shelf can list recent files."
        panel.prompt = "Allow"
        let response = panel.runModal()
        Log.write("access panel: \(response == .OK ? "chose \(panel.url?.path ?? "?")" : "cancelled")", category: "downloads")
        if response == .OK, let url = panel.url {
            source?.cancel()
            source = nil
            watch(url)
        }
    }
}
