import Foundation

struct Paths: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var cloud: URL { home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs") }
    var library: URL { cloud.appendingPathComponent("Library") }
    var print: URL { cloud.appendingPathComponent("Print") }
    var downloads: URL { home.appendingPathComponent("Downloads") }
    var skills: URL { home.appendingPathComponent(".claude/skills") }
    var fileBook: URL { skills.appendingPathComponent("book-epub/scripts/file_book.py") }
}

/// What prepare.py reported, when it ran.
struct Prepared: Codable, Equatable, Sendable {
    var newPath: String
    var confident: Bool
    var candidates: String?
}

enum PromptBuilder {
    static let unattended = """
    This runs unattended from the Shelf menubar app. Never ask questions. Never send email or any message. \
    Always file the finished EPUB in the Library (\(Paths().library.path)) per its README.md: books in \
    <Domain>/<Subject>/Books, papers, essays and web articles in <Domain>/<Subject>/Papers, encyclopedia entries \
    in <Domain>/<Subject>/Reference, with the README's name and tags, using \(Paths().fileBook.path) --dir. \
    Never leave the result only in Print or the working directory. Put temporary files in the working directory, \
    not /tmp. There is no Grep tool in this session: search with grep through Bash. If a command is denied, \
    retry it in a simpler form before giving up. If a decision is ambiguous, take the skill's default and say so \
    in the summary. Finish with the JSON result.
    """

    static func prompt(input: String, kind: InputKind, prepared: Prepared?, paths: Paths = Paths()) -> String {
        var parts: [String] = []
        if let prepared, !prepared.confident {
            parts.append("""
            prepare.py stripped this file's metadata and named it from weak evidence. If the text shows a clearly \
            better title, authors (as printed, middle names and initials kept; three or more become <first>-et-al) \
            or year, rename it with: uv run \(paths.home.path)/Applications/Shelf.app/Contents/Resources/prepare.py \
            "\(prepared.newPath)" --rename-to <title>-<authors>-<year> --title "<Title>" (lowercase, hyphens, no \
            extension; the year only if verifiable) and use the path from its JSON output. Otherwise keep the name. \
            Its candidates were: \(prepared.candidates ?? "none")
            """)
        }
        if kind == .epub {
            parts.append("""
            This is an existing EPUB, stripped of embedded metadata: \(input)
            Do not reconvert it. File it in the Library:
            1. Identify the title, authors (as printed, middle names and initials kept) and original publication year from its text.
            2. Choose Domain, Subject and lowercase hyphenated topic tags per \(paths.library.path)/README.md.
            3. Copy it into the working directory, write title, authors and date into the copy with ebook-meta, then run: \
            uv run \(paths.fileBook.path) <copy> --dir "<Domain>/<Subject>/Books" --tags "<Domain>,<Subject>,Books,<topics>"
            4. Run epubcheck on the filed file. Don't run Kindle Previewer.
            """)
        } else {
            parts.append("""
            Use the to-epub skill to turn this into an EPUB, then follow the skill it routes to fully, including its \
            checks (epubcheck, Kindle Previewer). Input: \(input)
            For the Kindle Previewer check, the CLI is already unpacked: run kindle-previewer-cli <copy>.epub --convert --qualitychecks --output <dir> (no pkgutil or brew steps).
            """)
        }
        parts.append(unattended)
        return parts.joined(separator: "\n\n")
    }

    static func arguments(prompt: String, model: String, schema: String, settings: URL, paths: Paths = Paths()) -> [String] {
        [
            "-p", prompt,
            "--model", model,
            "--output-format", "stream-json", "--verbose",
            "--json-schema", schema,
            "--settings", settings.path,
            "--permission-mode", "dontAsk",
            "--strict-mcp-config", "--no-chrome", "--no-session-persistence",
            "--add-dir", paths.downloads.path,
            "--add-dir", paths.library.path,
            "--add-dir", paths.print.path,
            "--add-dir", paths.skills.path,
        ]
    }

    static let searchPath = ["/opt/homebrew/bin", "~/.local/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        .map { NSString(string: $0).expandingTildeInPath }
        .joined(separator: ":")
}
