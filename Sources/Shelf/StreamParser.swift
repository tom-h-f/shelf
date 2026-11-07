import Foundation

struct JobResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case ok, failed, needs_attention }
    var status: Status
    var kind: String
    var title: String
    var filed_path: String
    var epubcheck: String
    var kindle_previewer: String
    var summary: String
}

enum StreamEvent: Equatable, Sendable {
    case progress(String)
    case finished(result: JobResult?, costUSD: Double?, isError: Bool, denials: Int)
}

/// Turns `claude -p --output-format stream-json` lines into progress and the final structured result.
enum StreamParser {
    static func parse(line: Substring) -> StreamEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }
        switch type {
        case "assistant":
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for item in content.reversed() where item["type"] as? String == "tool_use" {
                if let text = progressText(tool: item["name"] as? String ?? "", input: item["input"] as? [String: Any] ?? [:]) {
                    return .progress(text)
                }
            }
            return nil
        case "result":
            var result: JobResult?
            if let structured = obj["structured_output"],
               let json = try? JSONSerialization.data(withJSONObject: structured) {
                result = try? JSONDecoder().decode(JobResult.self, from: json)
            }
            return .finished(
                result: result,
                costUSD: obj["total_cost_usd"] as? Double,
                isError: obj["is_error"] as? Bool ?? false,
                denials: (obj["permission_denials"] as? [Any])?.count ?? 0
            )
        default:
            return nil
        }
    }

    static func progressText(tool: String, input: [String: Any]) -> String? {
        if let description = input["description"] as? String, !description.isEmpty { return description }
        switch tool {
        case "StructuredOutput": return "Finishing"
        case "Skill": return (input["skill"] as? String).map { "Using \($0)" }
        case "Read", "Write", "Edit":
            return (input["file_path"] as? String).map { "\(tool) \(URL(fileURLWithPath: $0).lastPathComponent)" }
        case "Bash":
            guard let command = input["command"] as? String,
                  let first = command.split(separator: " ").first else { return nil }
            return "Running \(URL(fileURLWithPath: String(first)).lastPathComponent)"
        default:
            return tool
        }
    }
}
