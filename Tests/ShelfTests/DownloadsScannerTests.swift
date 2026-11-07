import Foundation
import Testing
@testable import Shelf

@Suite struct DownloadsScannerTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func touch(_ name: String, created: Date) throws {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
    }

    @Test func keepsOnlySupportedKinds() throws {
        let now = Date()
        try touch("a.pdf", created: now.addingTimeInterval(-300))
        try touch("b.EPUB", created: now.addingTimeInterval(-100))
        try touch("c.md", created: now.addingTimeInterval(-200))
        try touch("d.xlsx", created: now)
        try touch("e.htm", created: now.addingTimeInterval(-400))
        let names = try DownloadsScanner(folder: dir).scan(now: now.addingTimeInterval(1)).map(\.url.lastPathComponent)
        #expect(Set(names) == ["a.pdf", "b.EPUB", "c.md", "e.htm"])
    }

    @Test func respectsLimit() throws {
        for i in 0..<5 { try touch("\(i).pdf", created: Date()) }
        #expect(try DownloadsScanner(folder: dir, limit: 3).scan().count == 3)
    }

    @Test func unreadableFolderThrows() {
        #expect(throws: (any Error).self) { try DownloadsScanner(folder: dir.appendingPathComponent("nope")).scan() }
    }

    @Test func annasArchiveDisplayName() {
        let url = URL(fileURLWithPath: "/x/Love in the Time of Contagion _ A Diagnosis -- Laura Kipnis -- 2022 -- Knopf -- abc123 -- Anna’s Archive.epub")
        let item = DownloadItem(url: url, kind: .epub, added: Date(), bytes: 1)
        #expect(item.displayName == "Love in the Time of Contagion: A Diagnosis - Laura Kipnis")
    }

    @Test func plainDisplayName() {
        let item = DownloadItem(url: URL(fileURLWithPath: "/x/feminist-contentions-seyla-benhabib-1995.pdf"), kind: .pdf, added: Date(), bytes: 1)
        #expect(item.displayName == "feminist-contentions-seyla-benhabib-1995")
    }
}
