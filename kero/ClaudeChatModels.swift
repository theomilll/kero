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

enum ClaudeChatHeaderParser {
    static func parse(
        fileURL: URL, modified: Date, fallbackProjectPath: String
    ) -> ClaudeChatSummary? {
        let sessionId = fileURL.deletingPathExtension().lastPathComponent
        let fallback = ClaudeChatSummary(
            sessionId: sessionId,
            title: sessionId,
            gitBranch: nil,
            modified: modified,
            fileURL: fileURL,
            projectPath: fallbackProjectPath
        )

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return fallback
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else {
            return fallback
        }

        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let json = object as? [String: Any],
                  json["type"] as? String == "user"
            else {
                continue
            }
            if json["isSidechain"] as? Bool == true {
                return nil
            }

            let slug = (json["slug"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = promptText(from: json)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title: String
            if let slug, !slug.isEmpty {
                title = slug.split(separator: "-")
                    .map { $0.capitalized }
                    .joined(separator: " ")
            } else if let prompt, !prompt.isEmpty {
                title = String(prompt.prefix(50))
            } else {
                title = sessionId
            }

            return ClaudeChatSummary(
                sessionId: sessionId,
                title: title,
                gitBranch: json["gitBranch"] as? String,
                modified: modified,
                fileURL: fileURL,
                projectPath: json["cwd"] as? String ?? fallbackProjectPath
            )
        }

        return fallback
    }

    private static func promptText(from json: [String: Any]) -> String? {
        guard let message = json["message"] as? [String: Any] else {
            return nil
        }
        if let content = message["content"] as? String {
            return content
        }
        guard let content = message["content"] as? [[String: Any]] else {
            return nil
        }
        return content.first {
            $0["type"] as? String == "text" && $0["text"] is String
        }?["text"] as? String
    }
}
