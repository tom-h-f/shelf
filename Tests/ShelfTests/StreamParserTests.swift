import Foundation
import Testing
@testable import Shelf

@Suite struct StreamParserTests {
    @Test func realLogYieldsProgressThenResult() throws {
        let url = try #require(Bundle.module.url(forResource: "epub-filing", withExtension: "jsonl", subdirectory: "Fixtures"))
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap(StreamParser.parse)
        let progress = events.compactMap { if case .progress(let s) = $0 { s } else { nil } }
        #expect(progress.contains("Running ebook-meta"))
        guard case .finished(let result, let cost, let isError, let denials) = try #require(events.last) else {
            Issue.record("last event is not the result")
            return
        }
        #expect(!isError)
        #expect(denials == 0)
        #expect((cost ?? 0) > 0)
        #expect(result?.status == .ok)
        #expect(result?.filed_path.hasSuffix(".epub") == true)
    }

    @Test func ignoresNonJSONAndUnknownEvents() {
        #expect(StreamParser.parse(line: "not json") == nil)
        #expect(StreamParser.parse(line: #"{"type":"system","subtype":"init"}"#) == nil)
    }

    @Test func toolDescriptionWins() {
        #expect(StreamParser.progressText(tool: "Bash", input: ["command": "epubcheck x.epub", "description": "Validate EPUB"]) == "Validate EPUB")
        #expect(StreamParser.progressText(tool: "Bash", input: ["command": "/opt/homebrew/bin/epubcheck x.epub"]) == "Running epubcheck")
    }

    @Test func missingStructuredOutputIsNilResult() {
        let event = StreamParser.parse(line: #"{"type":"result","is_error":true,"total_cost_usd":0.01}"#)
        #expect(event == .finished(result: nil, costUSD: 0.01, isError: true, denials: 0))
    }
}
