//
//  ClaudeChatMergeStore.swift
//  kero
//

import Combine
import Foundation

struct ClaudeChatMergeRecord: Codable, Equatable {
    /// When the merge was detected, not when it happened — only used for
    /// pruning alongside the chat itself.
    let date: Date
    let prNumber: Int?
}

/// Chats in which a PR was merged, persisted so the merged badge survives
/// restarts and a re-scan of an old transcript never re-celebrates.
/// A sibling of `ClaudeChatSettleStore` rather than an extension of it: the
/// settle file's schema is a bare `[project: [session: Date]]` and widening
/// it would break existing installs.
@MainActor
final class ClaudeChatMergeStore: ObservableObject {
    /// One process-wide store, same reasoning as `ClaudeChatSettleStore`.
    static let shared = ClaudeChatMergeStore()

    /// Merge records namespaced by encoded project directory name.
    @Published private(set) var merged: [String: [String: ClaudeChatMergeRecord]]

    private static let fileURL: URL = {
        #if DEBUG
        let directory = "kero-dev"
        #else
        let directory = "kero"
        #endif
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("claude-merged-chats.json")
    }()

    private init() {
        merged = Self.load()
    }

    func markMerged(_ sessionId: String, project: String, prNumber: Int?) {
        merged[project, default: [:]][sessionId] =
            ClaudeChatMergeRecord(date: Date(), prNumber: prNumber)
        persist()
    }

    func isMerged(_ sessionId: String, project: String) -> Bool {
        merged[project]?[sessionId] != nil
    }

    func record(_ sessionId: String, project: String) -> ClaudeChatMergeRecord? {
        merged[project]?[sessionId]
    }

    /// Drops records for `project` whose session file no longer exists,
    /// mirroring `ClaudeChatSettleStore.prune`.
    func prune(project: String, keeping: Set<String>) {
        guard let entries = merged[project] else { return }
        let pruned = entries.filter { keeping.contains($0.key) }
        guard pruned.count != entries.count else { return }
        if pruned.isEmpty {
            merged.removeValue(forKey: project)
        } else {
            merged[project] = pruned
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(merged) else { return }
        do {
            try FileManager.default.createDirectory(
                at: Self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("kero: failed to write \(Self.fileURL.path): \(error)")
        }
    }

    private static func load() -> [String: [String: ClaudeChatMergeRecord]] {
        guard let data = try? Data(contentsOf: fileURL),
              let merged = try? JSONDecoder().decode(
                [String: [String: ClaudeChatMergeRecord]].self, from: data
              )
        else {
            return [:]
        }
        return merged
    }
}
