import Foundation
import Testing
@testable import Shelf

@Suite struct PromptBuilderTests {
    let paths = Paths(home: URL(fileURLWithPath: "/Users/t"))

    @Test func convertPromptUsesToEpub() {
        let p = PromptBuilder.prompt(input: "https://example.org/a", kind: .url, prepared: nil, paths: paths)
        #expect(p.contains("to-epub skill"))
        #expect(p.contains("Never send email"))
        #expect(!p.contains("--rename-to"))
    }

    @Test func epubPromptFilesWithoutReconverting() {
        let p = PromptBuilder.prompt(input: "/Users/t/Downloads/x.epub", kind: .epub, prepared: Prepared(newPath: "/Users/t/Downloads/x.epub", confident: true), paths: paths)
        #expect(p.contains("Do not reconvert"))
        #expect(p.contains("/Users/t/.claude/skills/book-epub/scripts/file_book.py"))
        #expect(!p.contains("to-epub skill"))
    }

    @Test func lowConfidenceAsksClaudeToRename() {
        let prepared = Prepared(newPath: "/Users/t/Downloads/download (3).pdf", confident: false, candidates: "[\"A Title\"]")
        let p = PromptBuilder.prompt(input: prepared.newPath, kind: .pdf, prepared: prepared, paths: paths)
        #expect(p.contains("--rename-to"))
        #expect(p.contains("\"/Users/t/Downloads/download (3).pdf\""))
        #expect(p.contains("A Title"))
    }

    @Test func argumentsKeepPromptAsOneArgument() {
        let prompt = "line one\n\"quoted\" 'and' $dollar"
        let args = PromptBuilder.arguments(prompt: prompt, model: "sonnet", schema: "{}", settings: URL(fileURLWithPath: "/s.json"), paths: paths)
        #expect(args[0] == "-p" && args[1] == prompt)
        #expect(args.contains("dontAsk"))
        #expect(args.contains("/Users/t/Library/Mobile Documents/com~apple~CloudDocs/Library"))
    }
}
