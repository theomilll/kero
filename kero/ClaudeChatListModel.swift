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
    private var mergeScanStates: [String: MergeScanState] = [:]
    private var summaries: [String: ClaudeChatSummary] = [:]
    private var seenSessionIds: Set<String> = []
    private var isRefreshing = false
    private var cwd: String?

    func sync(
        cwd: String,
        settleStore: ClaudeChatSettleStore,
        mergeStore: ClaudeChatMergeStore,
        onNewChat: @escaping () -> Void,
        onPRMerged: @escaping (_ sessionId: String, _ merge: DetectedMerge) -> Void
    ) {
        guard !isRefreshing else { return }
        isRefreshing = true

        if self.cwd != cwd {
            self.cwd = cwd
            fileStates = [:]
            mergeScanStates = [:]
            summaries = [:]
            seenSessionIds = []
            hasLoadedOnce = false
            chats = []
        }

        let previousStates = fileStates
        let previousMergeStates = mergeScanStates
        Task { @MainActor [weak self] in
            let scanned = await Task.detached(priority: .utility) {
                Self.scan(
                    cwd: cwd,
                    previousStates: previousStates,
                    previousMergeStates: previousMergeStates
                )
            }.value

            guard let self else { return }
            defer { self.isRefreshing = false }

            guard let scanned else {
                // Project has no Claude directory: show the empty state.
                if !self.chats.isEmpty {
                    self.chats = []
                }
                self.fileStates = [:]
                self.mergeScanStates = [:]
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
            self.mergeScanStates = scanned.mergeStates.filter {
                liveNames.contains($0.key)
            }

            let updatedChats = liveNames.compactMap { self.summaries[$0] }
                .sorted { $0.modified > $1.modified }
            if updatedChats != self.chats {
                self.chats = updatedChats
            }

            let liveSessionIds = Set(
                liveNames.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            )
            let project = ClaudeProjectDirectory.encoded(for: cwd)
            settleStore.prune(project: project, keeping: liveSessionIds)
            mergeStore.prune(project: project, keeping: liveSessionIds)

            // Check-and-mark on the main actor so a second window syncing the
            // same project can never celebrate the same merge twice.
            for detection in scanned.detected
            where !mergeStore.isMerged(detection.sessionId, project: project) {
                mergeStore.markMerged(
                    detection.sessionId,
                    project: project,
                    prNumber: detection.merge.prNumber
                )
                onPRMerged(detection.sessionId, detection.merge)
            }

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
        previousStates: [String: (modified: Date, size: Int)],
        previousMergeStates: [String: MergeScanState]
    ) -> (
        liveStates: [String: (modified: Date, size: Int)],
        parsed: [(String, ClaudeChatSummary?)],
        mergeStates: [String: MergeScanState],
        detected: [(sessionId: String, merge: DetectedMerge)]
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

        // Merge detection reuses the same changed-file list, so each tick
        // only tail-reads transcripts that actually grew.
        var mergeStates = previousMergeStates
        var detected: [(sessionId: String, merge: DetectedMerge)] = []
        for file in changedFiles {
            guard let size = liveStates[file.name]?.size else { continue }
            let result = ClaudeChatMergeDetector.scan(
                fileURL: file.url,
                fileSize: UInt64(size),
                state: previousMergeStates[file.name]
            )
            mergeStates[file.name] = result.state
            let sessionId = file.url.deletingPathExtension().lastPathComponent
            detected += result.merges.map { (sessionId, $0) }
        }
        return (liveStates, parsed, mergeStates, detected)
    }
}
