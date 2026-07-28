//
//  ClaudeChatModels.swift
//  kero
//

import Foundation

struct ClaudeChatSummary: Identifiable, Equatable {
    let sessionId: String
    var id: String { sessionId }
    let title: String
    let gitBranch: String?
    let modified: Date
    let fileURL: URL
    let projectPath: String
}

enum ClaudeProjectDirectory {
    static func encoded(for cwd: String) -> String {
        cwd.map { character in
            character.isASCII && (character.isLetter || character.isNumber)
                ? String(character)
                : "-"
        }
        .joined()
    }

    static func url(for cwd: String) -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(encoded(for: cwd), isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return nil
        }
        return url
    }
}

/// Titles chats the way Claude Code's /resume picker does: the newest
/// `last-prompt` record's `lastPrompt` string, verbatim (the CLI has already
/// rendered image placeholders and flattened newlines into it). Everything
/// else — slugs, first prompts, command invocations — diverges from what the
/// picker shows.
enum ClaudeChatHeaderParser {
    /// Files up to this size are parsed whole; larger ones are sampled at
    /// both ends, which still covers the header records and the trailing
    /// last-prompt record the title comes from.
    private static let sampleWindow = 1024 * 1024
    private static let wholeFileLimit = 2 * 1024 * 1024

    /// Wrapper blocks the CLI injects around command plumbing; their contents
    /// were never typed by the user.
    private static let injectedWrappers = try? NSRegularExpression(
        pattern: "<(local-command-caveat|local-command-stdout|command-message"
            + "|command-args|system-reminder)>.*?</\\1>",
        options: [.dotMatchesLineSeparators]
    )

    /// The wrapper regex backtracks quadratically on unclosed openers, so it
    /// only ever sees this much of a prompt; a title keeps just 60 characters.
    private static let wrapperScanLimit = 4096

    static func parse(
        fileURL: URL, modified: Date, fallbackProjectPath: String
    ) -> ClaudeChatSummary? {
        let sessionId = fileURL.deletingPathExtension().lastPathComponent
        // Row for a file whose contents can't vouch for a better title.
        func placeholderRow() -> ClaudeChatSummary {
            ClaudeChatSummary(
                sessionId: sessionId,
                title: sessionId,
                gitBranch: nil,
                modified: modified,
                fileURL: fileURL,
                projectPath: fallbackProjectPath
            )
        }
        guard let lines = recordLines(from: fileURL) else {
            // Unreadable file: keep the row rather than dropping the session.
            return placeholderRow()
        }

        var gitBranch: String?
        var cwd: String?
        var sawUserLine = false
        var decodedRecord = false
        var lastPrompt: String?
        var lastSummary: String?
        var lastUsablePrompt: String?

        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let json = object as? [String: Any],
                  let type = json["type"] as? String
            else {
                continue
            }
            decodedRecord = true

            switch type {
            case "last-prompt":
                // Written after each real prompt; records that predate the
                // first prompt lack the field and are skipped.
                if let prompt = json["lastPrompt"] as? String {
                    let cleaned = normalized(prompt)
                    if !cleaned.isEmpty { lastPrompt = cleaned }
                }
            case "summary":
                if let summary = json["summary"] as? String {
                    let cleaned = normalized(summary)
                    if !cleaned.isEmpty { lastSummary = cleaned }
                }
            case "user":
                if !sawUserLine {
                    sawUserLine = true
                    // A sidechain transcript belongs to a subagent, not the inbox.
                    if json["isSidechain"] as? Bool == true { return nil }
                }
                if gitBranch == nil, let branch = json["gitBranch"] as? String,
                   !branch.isEmpty {
                    gitBranch = branch
                }
                if cwd == nil, let path = json["cwd"] as? String, !path.isEmpty {
                    cwd = path
                }
                // Tracked only as a last resort when no last-prompt or
                // summary record exists; keeping the newest survivor
                // preserves the picker's last-prompt semantics. Once either
                // exists the result could never win, so skip the (regex-
                // sanitizing, potentially costly) scan entirely.
                if lastPrompt == nil, lastSummary == nil,
                   let prompt = usablePrompt(from: json) {
                    lastUsablePrompt = prompt
                }
            default:
                break
            }
        }

        // Prompt-less sessions don't appear in the picker either — but when
        // not even one record decoded (e.g. a sampled file whose windows held
        // no complete line), the file said nothing about the session, so keep
        // a placeholder row instead of silently dropping it.
        guard let title = lastPrompt ?? lastSummary ?? lastUsablePrompt else {
            return decodedRecord ? nil : placeholderRow()
        }
        return ClaudeChatSummary(
            sessionId: sessionId,
            title: String(title.prefix(60)),
            gitBranch: gitBranch,
            modified: modified,
            fileURL: fileURL,
            projectPath: cwd ?? fallbackProjectPath
        )
    }

    /// Complete jsonl records: the whole file when small, otherwise the head
    /// (session header and first user record) plus the tail (where the title
    /// lives). A single record can exceed half a megabyte, so a small fixed
    /// read cannot be trusted to contain even one complete line.
    private static func recordLines(from fileURL: URL) -> [Data]? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        let newline = UInt8(ascii: "\n")
        if size <= UInt64(wholeFileLimit) {
            guard (try? handle.seek(toOffset: 0)) != nil,
                  let data = try? handle.readToEnd()
            else { return nil }
            return data.split(separator: newline)
        }

        guard (try? handle.seek(toOffset: 0)) != nil,
              let head = try? handle.read(upToCount: sampleWindow),
              (try? handle.seek(toOffset: size - UInt64(sampleWindow))) != nil,
              let tail = try? handle.readToEnd()
        else { return nil }

        // Both windows end or start mid-record; drop the cut fragments.
        var lines: [Data] = []
        if let lastBreak = head.lastIndex(of: newline) {
            lines = head[..<lastBreak].split(separator: newline)
        }
        if let firstBreak = tail.firstIndex(of: newline) {
            lines += tail[tail.index(after: firstBreak)...].split(separator: newline)
        }
        return lines
    }

    /// Title-worthy text of a user record, or nil for turns the picker
    /// ignores: meta and sidechain records, tool results, slash-command
    /// invocations, task notifications, and interruption pseudo-turns.
    private static func usablePrompt(from json: [String: Any]) -> String? {
        guard json["isMeta"] as? Bool != true,
              json["isSidechain"] as? Bool != true,
              let message = json["message"] as? [String: Any]
        else {
            return nil
        }

        var text: String
        if let content = message["content"] as? String {
            text = content
        } else if let blocks = message["content"] as? [[String: Any]] {
            let texts = blocks.compactMap { block in
                block["type"] as? String == "text" ? block["text"] as? String : nil
            }
            // The CLI stores "[Image #N]" placeholders inline with the text;
            // synthesize them only when a record somehow lacks its own, so an
            // image-only prompt still titles as "[Image #1]".
            let images = blocks.filter { $0["type"] as? String == "image" }.count
            guard !texts.isEmpty || images > 0 else { return nil }
            text = texts.joined(separator: " ")
            if images > 0, !text.contains("[Image #") {
                let placeholders = (1...images)
                    .map { "[Image #\($0)]" }
                    .joined(separator: " ")
                text = text.isEmpty ? placeholders : text + " " + placeholders
            }
        } else {
            return nil
        }

        // Command turns never title a session — not even the bare name — and
        // turns that open with command plumbing are output, not a prompt.
        guard !text.contains("<command-name>"),
              !text.hasPrefix("<task-notification>"),
              !text.hasPrefix("<local-command-")
        else {
            return nil
        }

        // Cap what the wrapper regex sees: its backtracking is quadratic on
        // unclosed openers, and only 60 characters ever reach the title.
        var stripped = String(text.prefix(wrapperScanLimit))
        if let injectedWrappers {
            stripped = injectedWrappers.stringByReplacingMatches(
                in: stripped,
                range: NSRange(stripped.startIndex..., in: stripped),
                withTemplate: ""
            )
        }
        let cleaned = normalized(stripped)
        guard !cleaned.isEmpty,
              cleaned != "[Request interrupted by user]",
              cleaned != "[Request interrupted by user for tool use]"
        else {
            return nil
        }
        return cleaned
    }

    /// One space between words, no leading or trailing whitespace.
    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
