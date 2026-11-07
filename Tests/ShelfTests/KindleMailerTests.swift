import Foundation
import Testing
@testable import Shelf

@Suite struct KindleMailerTests {
    let mailer = KindleMailer(sender: "a@b.com", kindleAddress: "k@kindle.com", sizeLimit: 1000)

    @Test func escapesQuotesAndBackslashes() {
        #expect(KindleMailer.quoted(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
    }

    @Test func scriptKeepsUnicodeAndQuotesPath() {
        let file = URL(fileURLWithPath: "/Users/t/Library/the-metastases-of-enjoyment-slavoj-zizek-1994.epub")
        let s = mailer.script(file: file, subject: "Žižek’s \"Metastases\"")
        #expect(s.contains(#"subject:"Žižek’s \"Metastases\"""#))
        #expect(s.contains(#"POSIX file "/Users/t/Library/the-metastases-of-enjoyment-slavoj-zizek-1994.epub" as alias"#))
        #expect(s.contains(#"{address:"k@kindle.com"}"#))
        #expect(s.contains(#"sender:"a@b.com""#))
    }

    @Test func compilesAsAppleScript() throws {
        let s = mailer.script(file: URL(fileURLWithPath: "/tmp/a \"b\".epub"), subject: "x")
        let script = try #require(NSAppleScript(source: s))
        var error: NSDictionary?
        #expect(script.compileAndReturnError(&error))
        #expect(error == nil)
    }

    @MainActor @Test func refusesOversizeFileBeforeTouchingMail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).epub")
        try Data(count: 2000).write(to: url)
        #expect(throws: MailError.self) { try mailer.send(file: url, subject: "x") }
    }
}
