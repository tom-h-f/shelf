import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Brand {
    static func image(_ name: String, template: Bool) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf"), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = template
        return image
    }
}

struct MenuView: View {
    @Bindable var runner: JobRunner
    @Bindable var downloads: DownloadsModel
    @State private var selected: URL?
    @State private var urlText = ""
    @State private var send = true
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            source
            recent
            actionBar
            if !runner.jobs.isEmpty { activity }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 420)
        .onAppear {
            Log.write("menu opened")
            downloads.watch(URL(fileURLWithPath: runner.settings.downloads))
            send = runner.settings.sendByDefault
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if let logo = Brand.image("logo", template: false) {
                Image(nsImage: logo).resizable().frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Shelf").font(.title3.weight(.semibold))
                Text("Convert, file and send to Kindle").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Settings…") { NSApp.activate(); openSettings() }
                Button("Open Library") { NSWorkspace.shared.open(Paths().library) }
                Button("Open Print folder") { NSWorkspace.shared.open(Paths().print) }
                Button("Open Shelf log") { NSWorkspace.shared.open(Log.url) }
                Divider()
                Button("Quit Shelf") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: Source

    private var source: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(.tertiary)
                TextField("Paste a link to an article or book", text: $urlText)
                    .textFieldStyle(.plain)
                    .onSubmit(convert)
                    .onChange(of: urlText) { if !urlText.isEmpty { selected = nil } }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            Button("Choose file…", action: choose)
                .controlSize(.large)
        }
    }

    // MARK: Recent downloads

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Recent downloads")
            if let error = downloads.error {
                placeholder(icon: "lock", text: error) {
                    Button("Allow access…") { downloads.requestAccess() }
                }
            } else if downloads.items.isEmpty {
                placeholder(icon: "tray", text: "Nothing new in the last two weeks.") {
                    if let report = downloads.lastReport {
                        Text(report).font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.horizontal, 12)
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: Self.rowSpacing) {
                        ForEach(downloads.items) { item in
                            DownloadRow(item: item, selected: selected == item.url)
                                .frame(height: Self.rowHeight)
                                .onTapGesture(count: 2) { pick(item); convert() }
                                .onTapGesture { pick(item) }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: listHeight)
                .background(GeometryReader { g in
                    Color.clear.onAppear { Log.write("list rendered \(downloads.items.count) rows in \(Int(g.size.width))x\(Int(g.size.height))pt", category: "ui") }
                })
            }
        }
    }

    private func placeholder<Action: View>(icon: String, text: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            action()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack {
            Toggle("Send to Kindle", isOn: $send)
                .toggleStyle(.switch)
                .controlSize(.small)
            Spacer()
            Button(action: convert) {
                Text("Convert").frame(minWidth: 72)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(pendingInput == nil)
        }
    }

    // MARK: Activity

    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Activity")
                Spacer()
                if runner.jobs.contains(where: { !$0.isActive }) {
                    Button("Clear finished") { runner.clearFinished() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 8) {
                ForEach(runner.jobs.prefix(4)) { job in JobCard(job: job, runner: runner) }
            }
            if runner.jobs.count > 4 {
                Text("\(runner.jobs.count - 4) older").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    static let rowHeight: CGFloat = 46
    static let rowSpacing: CGFloat = 2
    static let visibleRows = 6

    private var listHeight: CGFloat {
        let rows = CGFloat(min(downloads.items.count, Self.visibleRows))
        return rows * Self.rowHeight + max(0, rows - 1) * Self.rowSpacing
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
    }

    // MARK: Actions

    private var pendingInput: (String, InputKind)? {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return (text, .url) }
        if let selected, let kind = InputKind(fileExtension: selected.pathExtension) { return (selected.path, kind) }
        return nil
    }

    private func pick(_ item: DownloadItem) {
        selected = item.url
        urlText = ""
    }

    private func convert() {
        guard let (input, kind) = pendingInput else { return }
        runner.enqueue(input: input, kind: kind, send: send)
        selected = nil
        urlText = ""
    }

    private func choose() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.pdf, .epub, .html, UTType(filenameExtension: "md")].compactMap { $0 }
        panel.directoryURL = URL(fileURLWithPath: runner.settings.downloads)
        guard panel.runModal() == .OK, let url = panel.url, let kind = InputKind(fileExtension: url.pathExtension) else { return }
        runner.enqueue(input: url.path, kind: kind, send: send)
    }
}

extension InputKind {
    var symbol: String {
        switch self {
        case .pdf: "doc.richtext"
        case .epub: "book.closed"
        case .html, .url: "globe"
        case .markdown: "text.alignleft"
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 15))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 32, height: 32)
                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(background, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.url.lastPathComponent)
    }

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
        let age = item.added.formatted(.relative(presentation: .named))
        return "\(item.kind.rawValue.uppercased())  ·  \(size)  ·  \(age)"
    }

    private var background: Color {
        if selected { return Color.accentColor.opacity(0.16) }
        return hovering ? Color.primary.opacity(0.05) : .clear
    }
}

struct JobCard: View {
    let job: Job
    let runner: JobRunner

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 18, height: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayName).lineLimit(1).truncationMode(.middle)
                if job.isActive {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(job.state == .queued ? "Queued" : job.progress)  ·  \(elapsed)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            actions
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 2) {
            if job.isActive {
                iconButton("xmark", help: "Cancel") { runner.cancel(job.id) }
            } else {
                if let file = job.filedURL {
                    iconButton("folder", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    iconButton(job.sentAt == nil ? "paperplane" : "paperplane.fill", help: job.sentAt == nil ? "Send to Kindle" : "Send again") { runner.send(job.id) }
                }
                if FileManager.default.fileExists(atPath: runner.logURL(job.id).path) {
                    iconButton("doc.text", help: "Open log") { NSWorkspace.shared.open(runner.logURL(job.id)) }
                }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .preparing, .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .needsAttention: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private var elapsed: String {
        let s = Int(Date().timeIntervalSince(job.created))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var detail: String {
        switch job.state {
        case .done:
            if let err = job.sendError { return "Filed. Send failed: \(err)" }
            let filed = job.result?.filed_path.replacingOccurrences(of: Paths().cloud.path + "/", with: "") ?? ""
            return job.sentAt != nil ? "Sent to Kindle  ·  \(filed)" : filed
        case .needsAttention: return job.result?.summary ?? "Needs attention"
        case .failed: return job.error ?? "Failed"
        case .cancelled: return job.error ?? "Cancelled"
        default: return ""
        }
    }
}
