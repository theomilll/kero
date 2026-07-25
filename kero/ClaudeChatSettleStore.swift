//
//  ClaudeChatSettleStore.swift
//  kero
//

import Combine
import Foundation

@MainActor
final class ClaudeChatSettleStore: ObservableObject {
    /// One process-wide store: every window shares the same in-memory state,
    /// so a stale per-window copy can never clobber another window's writes.
    static let shared = ClaudeChatSettleStore()

    /// Settled session ids and settle dates, namespaced by encoded project
    /// directory name so pruning one project never touches another's state.
    @Published private(set) var settled: [String: [String: Date]]

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
            .appendingPathComponent("claude-settled-chats.json")
    }()

    private init() {
        settled = Self.load()
    }

    func settle(_ sessionId: String, project: String) {
        settled[project, default: [:]][sessionId] = Date()
        persist()
    }

    func unsettle(_ sessionId: String, project: String) {
        settled[project]?.removeValue(forKey: sessionId)
        if settled[project]?.isEmpty == true {
            settled.removeValue(forKey: project)
        }
        persist()
    }

    func isSettled(_ sessionId: String, project: String) -> Bool {
        settled[project]?[sessionId] != nil
    }

    /// Drops settled entries for `project` whose session file no longer
    /// exists. Other projects' entries are untouched: the caller only has
    /// visibility into the directory it just synced.
    func prune(project: String, keeping: Set<String>) {
        guard let entries = settled[project] else { return }
        let pruned = entries.filter { keeping.contains($0.key) }
        guard pruned.count != entries.count else { return }
        if pruned.isEmpty {
            settled.removeValue(forKey: project)
        } else {
            settled[project] = pruned
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settled) else { return }
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

    private static func load() -> [String: [String: Date]] {
        guard let data = try? Data(contentsOf: fileURL),
              let settled = try? JSONDecoder().decode(
                [String: [String: Date]].self, from: data
              )
        else {
            return [:]
        }
        return settled
    }
}
