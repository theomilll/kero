//
//  ClaudeChatListModel.swift
//  kero
//

import Combine
import Foundation

@MainActor
final class ClaudeChatListModel: ObservableObject {
    @Published private(set) var chats: [ClaudeChatSummary] = []
    private(set) var hasLoadedOnce: Bool = false

    private var fileStates: [String: (modified: Date, size: Int)] = [:]
    private var summaries: [String: ClaudeChatSummary] = [:]
    private var seenSessionIds: Set<String> = []
    private var isRefreshing = false
    private var cwd: String?

    func sync(
        cwd: String,
        settleStore: ClaudeChatSettleStore,
        onNewChat: @escaping () -> Void
    ) {
        guard !isRefreshing else { return }
        isRefreshing = true

        if self.cwd != cwd {
            self.cwd = cwd
            fileStates = [:]
            summaries = [:]
            seenSessionIds = []
            hasLoadedOnce = false
            chats = []
        }

        let previousStates = fileStates
        Task { @MainActor [weak self] in
            let scanned = await Task.detached(priority: .utility) {
                Self.scan(cwd: cwd, previousStates: previousStates)
            }.value

            guard let self else { return }
            defer { self.isRefreshing = false }

            guard let scanned else {
                // Project has no Claude directory: show the empty state.
                if !self.chats.isEmpty {
                    self.chats = []
                }
                self.fileStates = [:]
                self.summaries = [:]
                self.seenSessionIds = []
                self.hasLoadedOnce = true
                return
            }

            let liveNames = Set(scanned.liveStates.keys)
            self.summaries = self.summaries.filter { liveNames.contains($0.key) }
            for (name, summary) in scanned.parsed {
                self.summaries[name] = summary
            }
            self.fileStates = scanned.liveStates

            let updatedChats = liveNames.compactMap { self.summaries[$0] }
                .sorted { $0.modified > $1.modified }
            if updatedChats != self.chats {
                self.chats = updatedChats
            }

            let liveSessionIds = Set(
                liveNames.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            )
            settleStore.prune(
                project: ClaudeProjectDirectory.encoded(for: cwd),
                keeping: liveSessionIds
            )
            let visibleSessionIds = Set(updatedChats.map(\.sessionId))
            if self.hasLoadedOnce {
                for _ in visibleSessionIds.subtracting(self.seenSessionIds) {
                    onNewChat()
                }
            }
            self.seenSessionIds = visibleSessionIds
            self.hasLoadedOnce = true
        }
    }

    /// Enumerates the project directory and parses headers of files whose
    /// (mtime, size) changed since `previousStates`. Runs off the main actor;
    /// returns nil when the directory is missing.
    private nonisolated static func scan(
        cwd: String,
        previousStates: [String: (modified: Date, size: Int)]
    ) -> (
        liveStates: [String: (modified: Date, size: Int)],
        parsed: [(String, ClaudeChatSummary?)]
    )? {
        guard let directoryURL = ClaudeProjectDirectory.url(for: cwd) else {
            return nil
        }

        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
        ]
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: .skipsHiddenFiles
        ) else {
            return nil
        }

        // Inbox only surfaces recent activity; older chats never appear.
        let cutoff = Date().addingTimeInterval(-3 * 86400)
        var liveStates: [String: (modified: Date, size: Int)] = [:]
        var changedFiles: [(name: String, url: URL, modified: Date)] = []
        for fileURL in fileURLs {
            let name = fileURL.lastPathComponent
            guard name != "sessions-index.json",
                  fileURL.pathExtension == "jsonl",
                  let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isDirectory != true,
                  let modified = values.contentModificationDate,
                  modified > cutoff,
                  let size = values.fileSize
            else {
                continue
            }
            liveStates[name] = (modified, size)
            let previous = previousStates[name]
            if previous?.modified != modified || previous?.size != size {
                changedFiles.append((name, fileURL, modified))
            }
        }

        let parsed = changedFiles.map { file in
            (
                file.name,
                ClaudeChatHeaderParser.parse(
                    fileURL: file.url,
                    modified: file.modified,
                    fallbackProjectPath: cwd
                )
            )
        }
        return (liveStates, parsed)
    }
}
