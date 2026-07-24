//
//  ClaudeActivityMonitor.swift
//  kero
//

import Combine
import Darwin
import Foundation

@MainActor
final class ClaudeActivityMonitor: ObservableObject {
    struct Attachment: Equatable {
        let claudePid: pid_t
        let claudeCwd: String
        var chatSessionId: String?
    }

    @Published private(set) var attachments: [UUID: Attachment] = [:]

    var hasActiveClaude: Bool { !attachments.isEmpty }

    private struct SessionProcess: Sendable {
        let id: UUID
        let shellPid: pid_t
    }

    private struct ClaudeProcess: Sendable {
        let pid: pid_t
        let cwd: String
        let started: Date?
    }

    private var sessionsProvider: (() -> [TerminalSession])?
    private var jsonlSnapshots: [UUID: [URL: Date]] = [:]
    private var settingsObservation: AnyCancellable?
    private var timerObservation: AnyCancellable?
    private var isRefreshing = false
    private var pollingGeneration = 0

    init() {
        settingsObservation = AppSettings.shared.$claudeChatsEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.startPolling()
                } else {
                    self.stopPolling()
                }
            }
    }

    func attachment(forChat sessionId: String) -> UUID? {
        attachments.first { $0.value.chatSessionId == sessionId }?.key
    }

    func bind(sessionsProvider: @escaping () -> [TerminalSession]) {
        self.sessionsProvider = sessionsProvider
    }

    private func startPolling() {
        guard timerObservation == nil else { return }
        timerObservation = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    private func stopPolling() {
        timerObservation?.cancel()
        timerObservation = nil
        pollingGeneration += 1
        if !attachments.isEmpty {
            attachments = [:]
        }
        jsonlSnapshots = [:]
    }

    private func refresh() {
        guard !isRefreshing else { return }

        let sessions = sessionsProvider?() ?? []
        let sessionProcesses = sessions.compactMap { session -> SessionProcess? in
            guard !session.hasExited, let shellPid = session.shellPid else { return nil }
            return SessionProcess(id: session.id, shellPid: shellPid)
        }
        let generation = pollingGeneration
        let knownAttachments = attachments
        let knownSnapshots = jsonlSnapshots
        isRefreshing = true

        Task.detached(priority: .utility) { [weak self] in
            let processes = Self.snapshot(sessions: sessionProcesses)
            let resolved = Self.resolve(
                processes: processes,
                attachments: knownAttachments,
                snapshots: knownSnapshots
            )
            await MainActor.run {
                guard let self else { return }
                self.isRefreshing = false
                guard AppSettings.shared.claudeChatsEnabled,
                      self.pollingGeneration == generation else { return }
                self.jsonlSnapshots = resolved.snapshots
                if self.attachments != resolved.attachments {
                    self.attachments = resolved.attachments
                }
            }
        }
    }

    /// Pairs each claude process with a chat session id by watching which
    /// jsonl file advances past the snapshot taken when the process was first
    /// seen. Newly seen processes may have written their jsonl before this
    /// poll noticed them, so their first resolution attempt considers files
    /// modified after the process launched. Session ids already claimed by
    /// another terminal are skipped so two claude instances in one cwd cannot
    /// converge on the same chat.
    private nonisolated static func resolve(
        processes: [UUID: ClaudeProcess],
        attachments: [UUID: Attachment],
        snapshots: [UUID: [URL: Date]]
    ) -> (attachments: [UUID: Attachment], snapshots: [UUID: [URL: Date]]) {
        var updatedAttachments: [UUID: Attachment] = [:]
        var updatedSnapshots: [UUID: [URL: Date]] = [:]
        var datesByCwd: [String: [URL: Date]] = [:]
        var claimed = Set<String>()
        for (sessionID, process) in processes {
            if let existing = attachments[sessionID],
               existing.claudePid == process.pid,
               let chatSessionId = existing.chatSessionId {
                claimed.insert(chatSessionId)
            }
        }

        for (sessionID, process) in processes {
            let dates: [URL: Date]
            if let cached = datesByCwd[process.cwd] {
                dates = cached
            } else {
                dates = jsonlModificationDates(for: process.cwd)
                datesByCwd[process.cwd] = dates
            }

            if let existing = attachments[sessionID],
               existing.claudePid == process.pid {
                var attachment = Attachment(
                    claudePid: process.pid,
                    claudeCwd: process.cwd,
                    chatSessionId: existing.chatSessionId
                )
                let snapshot = snapshots[sessionID] ?? dates
                if attachment.chatSessionId == nil {
                    attachment.chatSessionId = chatSessionID(
                        in: dates, since: snapshot, excluding: claimed
                    )
                    if let id = attachment.chatSessionId {
                        claimed.insert(id)
                    }
                }
                updatedAttachments[sessionID] = attachment
                updatedSnapshots[sessionID] = snapshot
            } else {
                var attachment = Attachment(
                    claudePid: process.pid,
                    claudeCwd: process.cwd,
                    chatSessionId: nil
                )
                if let started = process.started {
                    attachment.chatSessionId = chatSessionID(
                        in: dates.filter { $0.value > started },
                        since: [:],
                        excluding: claimed
                    )
                    if let id = attachment.chatSessionId {
                        claimed.insert(id)
                    }
                }
                updatedAttachments[sessionID] = attachment
                updatedSnapshots[sessionID] = dates
            }
        }
        return (updatedAttachments, updatedSnapshots)
    }

    private nonisolated static func snapshot(
        sessions: [SessionProcess]
    ) -> [UUID: ClaudeProcess] {
        let psOut = run("/bin/ps", ["-axo", "pid=,ppid=,comm="])
        var childPids: [pid_t: [pid_t]] = [:]
        var commByPid: [pid_t: String] = [:]
        for line in psOut.split(separator: "\n") {
            let fields = line.split(
                separator: " ",
                maxSplits: 2,
                omittingEmptySubsequences: true
            )
            guard fields.count == 3,
                  let pid = pid_t(fields[0]),
                  let ppid = pid_t(fields[1]) else { continue }
            let comm = String(fields[2])
            childPids[ppid, default: []].append(pid)
            commByPid[pid] = (comm as NSString).lastPathComponent
        }

        var result: [UUID: ClaudeProcess] = [:]
        for session in sessions {
            var claudePid: pid_t?
            var fallbackPids: [pid_t] = []
            var queue = childPids[session.shellPid] ?? []
            while !queue.isEmpty {
                let pid = queue.removeFirst()
                let comm = commByPid[pid] ?? ""
                if comm == "claude" || comm.hasPrefix("claude-") {
                    claudePid = pid
                    break
                }
                if comm == "node" || comm == "bun" {
                    fallbackPids.append(pid)
                }
                queue.append(contentsOf: childPids[pid] ?? [])
            }

            if claudePid == nil {
                claudePid = fallbackClaudePid(candidates: fallbackPids)
            }
            guard let claudePid,
                  let cwd = processWorkingDirectory(pid: claudePid) else { continue }
            result[session.id] = ClaudeProcess(
                pid: claudePid,
                cwd: cwd,
                started: processStartDate(pid: claudePid)
            )
        }
        return result
    }

    private nonisolated static func fallbackClaudePid(
        candidates: [pid_t]
    ) -> pid_t? {
        guard !candidates.isEmpty else { return nil }
        let ordered = candidates.sorted()
        let list = ordered.map(String.init).joined(separator: ",")
        let commands = run(
            "/bin/ps",
            ["-o", "command=", "-p", list]
        ).split(separator: "\n")
        for (pid, command) in zip(ordered, commands) where command.contains("claude") {
            return pid
        }
        return nil
    }

    private nonisolated static func processWorkingDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    private nonisolated static func processStartDate(pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return Date(
            timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        )
    }

    private nonisolated static func jsonlModificationDates(
        for cwd: String
    ) -> [URL: Date] {
        guard let directory = ClaudeProjectDirectory.url(for: cwd),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return [:] }

        var dates: [URL: Date] = [:]
        for file in files where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ), let modified = values.contentModificationDate else { continue }
            dates[file] = modified
        }
        return dates
    }

    private nonisolated static func chatSessionID(
        in dates: [URL: Date],
        since snapshot: [URL: Date],
        excluding claimed: Set<String>
    ) -> String? {
        dates
            .filter { file, modified in
                guard let previous = snapshot[file] else { return true }
                return modified > previous
            }
            .map { (id: $0.key.deletingPathExtension().lastPathComponent, modified: $0.value) }
            .filter { !claimed.contains($0.id) }
            .max { $0.modified < $1.modified }?
            .id
    }

    private nonisolated static func run(
        _ executable: String,
        _ args: [String]
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ""
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
