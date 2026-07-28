//
//  ClaudeChatMergeDetector.swift
//  kero
//

import Foundation

/// Incremental scan position for one chat transcript, kept across sync ticks
/// so each tick only reads the bytes appended since the last one.
struct MergeScanState {
    /// Byte offset just past the last fully-consumed newline.
    var offset: UInt64
    /// Bash tool_use ids whose command looked like a `gh pr merge`, awaiting
    /// their tool_result. Insertion-ordered so overflow drops the oldest.
    var pendingToolUses: [(id: String, command: String)] = []
}

struct DetectedMerge: Equatable {
    let prNumber: Int?
    /// The tool_result record's own timestamp — distinguishes a merge that
    /// just happened from one found while catching up on an old transcript.
    let timestamp: Date?
}

/// Tail-parses Claude Code transcript jsonl for a successful `gh pr merge`
/// run through the Bash tool: a tool_use whose command invokes the merge,
/// paired with a tool_result that didn't error.
enum ClaudeChatMergeDetector {
    /// How far back to look on first sight of a file (app launch or project
    /// switch). Merges buried deeper than this are missed — acceptable.
    static let tailWindow: UInt64 = 256 * 1024
    private static let maxPending = 50

    /// `gh pr merge` at the start of the command or after a shell separator;
    /// captures its arguments up to the next separator. `git merge` and
    /// substrings like `high pr merge` cannot match.
    private static let mergeCommand = try! NSRegularExpression(
        pattern: #"(?:^|[;&|(`\n]|\bthen\s|\bdo\s)\s*gh\s+pr\s+merge\b([^;&|)`\n]*)"#
    )

    static func scan(
        fileURL: URL, fileSize: UInt64, state: MergeScanState?
    ) -> (state: MergeScanState, merges: [DetectedMerge]) {
        var start: UInt64
        var pending: [(id: String, command: String)]
        // A resumed offset sits just past a newline; a tail jump lands
        // mid-line and must skip forward to the next line break.
        var startsMidLine: Bool
        if let state, fileSize >= state.offset {
            start = state.offset
            startsMidLine = false
            pending = state.pendingToolUses
            // A huge append (e.g. a pasted image) isn't worth wading through.
            if fileSize - start > 4 * tailWindow {
                start = fileSize - tailWindow
                startsMidLine = true
            }
        } else {
            // First sight, or the file shrank (rewritten): bootstrap from the
            // tail. The persisted merge store dedups anything re-detected.
            start = fileSize > tailWindow ? fileSize - tailWindow : 0
            startsMidLine = start > 0
            pending = []
        }

        var consumed = start
        var merges: [DetectedMerge] = []

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return (MergeScanState(offset: consumed, pendingToolUses: pending), [])
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else {
            return (MergeScanState(offset: consumed, pendingToolUses: pending), [])
        }

        let newline = UInt8(ascii: "\n")
        var lower = data.startIndex
        // Mid-line start: skip the partial first line.
        if startsMidLine {
            guard let firstBreak = data.firstIndex(of: newline) else {
                return (MergeScanState(offset: consumed, pendingToolUses: pending), [])
            }
            lower = data.index(after: firstBreak)
        }
        // Only consume through the last newline; a partial trailing line is
        // re-read on the next tick once the writer finishes it.
        guard let lastBreak = data.lastIndex(of: newline), lastBreak >= lower else {
            return (MergeScanState(offset: consumed, pendingToolUses: pending), [])
        }
        consumed = start + UInt64(data.distance(from: data.startIndex, to: lastBreak) + 1)

        for line in data[lower...lastBreak].split(separator: newline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let json = object as? [String: Any],
                  let type = json["type"] as? String
            else { continue }

            switch type {
            case "assistant":
                for item in contentItems(of: json)
                where item["type"] as? String == "tool_use"
                    && item["name"] as? String == "Bash" {
                    guard let id = item["id"] as? String,
                          let input = item["input"] as? [String: Any],
                          let command = input["command"] as? String,
                          isMergeCommand(command)
                    else { continue }
                    pending.append((id, command))
                    if pending.count > maxPending { pending.removeFirst() }
                }
            case "user":
                for item in contentItems(of: json)
                where item["type"] as? String == "tool_result" {
                    guard let id = item["tool_use_id"] as? String,
                          let index = pending.firstIndex(where: { $0.id == id })
                    else { continue }
                    let command = pending.remove(at: index).command
                    if let merge = successfulMerge(
                        result: item, record: json, command: command
                    ) {
                        merges.append(merge)
                    }
                }
            default:
                break
            }
        }

        return (MergeScanState(offset: consumed, pendingToolUses: pending), merges)
    }

    // MARK: - Record parsing

    private static func contentItems(of json: [String: Any]) -> [[String: Any]] {
        guard let message = json["message"] as? [String: Any] else { return [] }
        return message["content"] as? [[String: Any]] ?? []
    }

    private static func successfulMerge(
        result: [String: Any], record: [String: Any], command: String
    ) -> DetectedMerge? {
        guard result["is_error"] as? Bool != true else { return nil }
        let toolUseResult = record["toolUseResult"] as? [String: Any]
        guard toolUseResult?["interrupted"] as? Bool != true else { return nil }

        // Newer CLI records carry a structured summary of the git operation —
        // authoritative for both the outcome and the PR number when present.
        var prNumber: Int?
        if let pr = (toolUseResult?["gitOperation"] as? [String: Any])?["pr"]
            as? [String: Any] {
            guard pr["action"] as? String == "merged" else { return nil }
            prNumber = pr["number"] as? Int
        }

        let timestamp = (record["timestamp"] as? String).flatMap(parseTimestamp)
        return DetectedMerge(
            prNumber: prNumber ?? Self.prNumber(fromCommand: command),
            timestamp: timestamp
        )
    }

    private static func parseTimestamp(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    // MARK: - Command matching

    static func isMergeCommand(_ command: String) -> Bool {
        mergeArguments(of: command) != nil
    }

    /// The argument segment of the first real `gh pr merge` invocation, or
    /// nil when the command doesn't merge anything.
    private static func mergeArguments(of command: String) -> String? {
        let range = NSRange(command.startIndex..., in: command)
        for match in mergeCommand.matches(in: command, range: range) {
            guard let argsRange = Range(match.range(at: 1), in: command) else {
                continue
            }
            let args = String(command[argsRange])
            let words = args.split(whereSeparator: \.isWhitespace).map(String.init)
            // Help output and turning auto-merge off don't merge anything.
            if words.contains("--help") || words.contains("-h")
                || words.contains("--disable-auto") {
                continue
            }
            return args
        }
        return nil
    }

    private static func prNumber(fromCommand command: String) -> Int? {
        guard let args = mergeArguments(of: command) else { return nil }
        for word in args.split(whereSeparator: \.isWhitespace) {
            if let number = Int(word), (1...999_999).contains(number) {
                return number
            }
            if let range = word.range(of: #"/pull/(\d+)"#, options: .regularExpression) {
                return Int(word[range].dropFirst("/pull/".count))
            }
        }
        return nil
    }
}
