import AppKit
import Foundation

enum MailError: LocalizedError {
    case tooLarge(bytes: Int64, limit: Int64)
    case missingFile(String)
    case script(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes, let limit):
            "EPUB is \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)), over Send to Kindle's \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) email limit"
        case .missingFile(let path): "File not found: \(path)"
        case .script(let message): "Mail: \(message)"
        }
    }
}

/// Sends an EPUB to a Kindle address through Mail.app, from an account already set up in Mail.
struct KindleMailer {
    var sender: String
    var kindleAddress: String
    var sizeLimit: Int64

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func script(file: URL, subject: String) -> String {
        """
        tell application "Mail"
            set msg to make new outgoing message with properties {subject:\(Self.quoted(subject)), content:"", visible:false, sender:\(Self.quoted(sender))}
            tell msg
                make new to recipient at end of to recipients with properties {address:\(Self.quoted(kindleAddress))}
                make new attachment with properties {file name:(POSIX file \(Self.quoted(file.path)) as alias)} at after the last paragraph
            end tell
            delay 2
            send msg
        end tell
        """
    }

    @MainActor
    func send(file: URL, subject: String) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        guard let bytes = (attrs?[.size] as? NSNumber)?.int64Value else { throw MailError.missingFile(file.path) }
        guard bytes <= sizeLimit else { throw MailError.tooLarge(bytes: bytes, limit: sizeLimit) }
        try Self.run(script(file: file, subject: subject))
    }

    @MainActor
    static func accounts() throws -> [String] {
        let result = try run("tell application \"Mail\" to get email addresses of every account")
        var out: [String] = []
        for i in stride(from: 1, through: result.numberOfItems, by: 1) {
            guard let list = result.atIndex(i) else { continue }
            for j in stride(from: 1, through: list.numberOfItems, by: 1) {
                if let address = list.atIndex(j)?.stringValue { out.append(address) }
            }
        }
        return out
    }

    @MainActor
    @discardableResult
    static func run(_ source: String) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw MailError.script("could not compile script") }
        let result = script.executeAndReturnError(&error)
        if let error {
            throw MailError.script(error[NSAppleScript.errorMessage] as? String ?? "\(error)")
        }
        return result
    }
}

extension KindleMailer {
    /// Amazon documents 50 MB per Send to Kindle email; decimal megabytes is the conservative reading.
    static let amazonEmailLimit: Int64 = 50_000_000
}
