//
//  ClaudeChatsSidebarView.swift
//  kero
//

import AppKit
import Combine
import GhosttyTerminal
import SwiftUI

/// Auto-hiding right-edge panel listing the current project's Claude Code
/// chats. Slides in while a `claude` process runs in some kero terminal and
/// away once none does. Sibling of `RightSidebarView`, not a `RightPanel` tab.
struct ClaudeChatsSidebarView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var monitor: ClaudeActivityMonitor
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    @ObservedObject private var settleStore = ClaudeChatSettleStore.shared
    @StateObject private var model = ClaudeChatListModel()
    @AppStorage("claudeChatsSidebarWidth") private var width: Double = 250
    @AppStorage("claudeChatsSettledCollapsed") private var settledCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var settlingID: String?
    @State private var confirmingID: String?
    @State private var isVisible = false
    @State private var hideTask: Task<Void, Never>?

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(manager: TerminalManager) {
        self._manager = ObservedObject(wrappedValue: manager)
        self._monitor = ObservedObject(wrappedValue: manager.claudeMonitor)
    }

    private enum InboxItem: Identifiable, Equatable {
        case chat(ClaudeChatSummary)
        case settledHeader

        var id: String {
            switch self {
            case .chat(let c): return c.sessionId
            case .settledHeader: return "settled-header"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if isVisible {
                Rectangle()
                    .fill(Color(nsColor: Theme.divider))
                    .frame(width: 1)

                VStack(spacing: 0) {
                    header
                    if model.chats.isEmpty { emptyState } else { chatList }
                }
                .frame(width: width)
                .background(Color(nsColor: Theme.sidebar))
                .overlay(alignment: .leading) {
                    SidebarResizeHandle(
                        edge: .leading,
                        width: $width,
                        range: 200...360,
                        defaultWidth: 250
                    )
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isVisible)
        .onAppear {
            if shouldShow {
                isVisible = true
                sync()
            }
        }
        .onReceive(refreshTimer) { _ in sync() }
        .onChange(of: shouldShow) { updateVisibility() }
        .onChange(of: manager.selectedProjectID) { sync() }
    }

    // MARK: - Visibility

    private var shouldShow: Bool {
        settings.claudeChatsEnabled && monitor.hasActiveClaude
    }

    private func updateVisibility() {
        if shouldShow {
            hideTask?.cancel()
            hideTask = nil
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isVisible = true }
            sync()
        } else {
            hideTask?.cancel()
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isVisible = false }
            }
        }
    }

    /// Working directory the list is rooted at: an attached claude's own cwd
    /// when one of the selected project's terminals hosts it, else the selected
    /// session's live cwd.
    private var panelCwd: String? {
        guard let project = manager.selectedProject else { return nil }
        let sessionIDs = Set(project.sessions.map(\.id))
        if let attachment = monitor.attachments.first(where: { sessionIDs.contains($0.key) })?.value {
            return attachment.claudeCwd
        }
        return project.selectedSession?.currentDirectoryPath
    }

    private func sync() {
        guard isVisible, let cwd = panelCwd else { return }
        model.sync(cwd: cwd, settleStore: settleStore) {
            if NSApp.isActive, isVisible, model.hasLoadedOnce {
                ChatSounds.play(.newChat)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: Theme.accent))
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Chats")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(manager.selectedProject?.name ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if workingCount > 0 {
                Text("\(workingCount)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - List

    private var items: [InboxItem] {
        let chats = model.chats
        let active = chats.filter { !isSettled($0) }
            .sorted {
                (isWorking($0) ? 1 : 0, $0.modified.timeIntervalSince1970)
                    > (isWorking($1) ? 1 : 0, $1.modified.timeIntervalSince1970)
            }
        let settled = chats.filter(isSettled).sorted { $0.modified > $1.modified }
        var out = active.map(InboxItem.chat)
        if !settled.isEmpty {
            out.append(.settledHeader)
            if !settledCollapsed { out += settled.map(InboxItem.chat) }
        }
        return out
    }

    private var chatList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(items) { item in
                    switch item {
                    case .settledHeader:
                        settledHeader.transition(.opacity)
                    case .chat(let chat):
                        ChatRow(
                            chat: chat,
                            isWorking: isWorking(chat),
                            isSettled: isSettled(chat),
                            isConfirming: confirmingID == chat.sessionId,
                            activate: { activate(chat) },
                            toggleSettled: { toggleSettled(chat) }
                        )
                        .zIndex(settlingID == chat.sessionId ? 1 : 0)
                        .scaleEffect(settlingID == chat.sessionId ? 1.02 : 1)
                        .shadow(color: .black.opacity(settlingID == chat.sessionId ? 0.18 : 0), radius: 6, y: 2)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .animation(itemsAnimation, value: items)
        }
    }

    private var settledHeader: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { settledCollapsed.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(settledCollapsed ? 0 : 90))
                Text("SETTLED")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text("\(settledCount)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            .frame(height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.quaternary)
            VStack(spacing: 2) {
                Text("No chats yet")
                    .font(.system(size: 11.5, weight: .medium))
                Text("Claude Code sessions in this project appear here.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Predicates

    /// Settle-store namespace: the encoded project directory the chat's
    /// jsonl actually lives in.
    private func projectKey(_ chat: ClaudeChatSummary) -> String {
        chat.fileURL.deletingLastPathComponent().lastPathComponent
    }

    private func isSettled(_ chat: ClaudeChatSummary) -> Bool {
        settleStore.isSettled(chat.sessionId, project: projectKey(chat))
    }

    private func isWorking(_ chat: ClaudeChatSummary) -> Bool {
        monitor.attachment(forChat: chat.sessionId) != nil
    }

    private var workingCount: Int { model.chats.filter(isWorking).count }
    private var settledCount: Int { model.chats.filter(isSettled).count }

    private var itemsAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.55, dampingFraction: 0.8)
    }

    // MARK: - Settle

    private func toggleSettled(_ chat: ClaudeChatSummary) {
        let project = projectKey(chat)
        let id = chat.sessionId
        guard confirmingID != id else { return }
        let currentlySettled = settleStore.isSettled(id, project: project)
        ChatSounds.play(currentlySettled ? .unsettle : .settle)

        if currentlySettled || reduceMotion {
            withAnimation(itemsAnimation) {
                if currentlySettled {
                    settleStore.unsettle(id, project: project)
                } else {
                    settleStore.settle(id, project: project)
                }
            }
            return
        }

        // Green "okay" beat on the row, then the glide down into Settled.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { confirmingID = id }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(itemsAnimation) {
                settlingID = id
                settleStore.settle(id, project: project)
            }
            try? await Task.sleep(for: .milliseconds(550))
            withAnimation(.easeOut(duration: 0.2)) {
                if settlingID == id { settlingID = nil }
                if confirmingID == id { confirmingID = nil }
            }
        }
    }

    // MARK: - Resume / activate

    private func activate(_ chat: ClaudeChatSummary) {
        // 1. A live terminal already hosts this chat — just focus it.
        if let sessionID = monitor.attachment(forChat: chat.sessionId),
           let session = manager.projects.flatMap(\.sessions).first(where: { $0.id == sessionID }) {
            manager.revealSession(session)
            return
        }
        guard let project = manager.selectedProject else { return }
        let command = "claude --resume '" + shellEscape(chat.sessionId) + "'\n"
        let targetEncoded = ClaudeProjectDirectory.encoded(for: chat.projectPath)

        // 2. Reuse an idle-at-prompt terminal in the same project directory.
        if let idle = project.sessions.first(where: { session in
            guard let pid = session.shellPid else { return false }
            return session.terminalView.foregroundPid == pid
                && ClaudeProjectDirectory.encoded(for: session.currentDirectoryPath) == targetEncoded
        }) {
            manager.revealSession(idle)
            idle.sendCommand(command)
            return
        }

        // 3. Open a fresh terminal at the chat's cwd, then resume once its
        // shell reports a pid.
        let session = project.newSession(directory: chat.projectPath)
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if session.shellPid != nil { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            session.sendCommand(command)
        }
    }

    private func shellEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "'\\''")
    }
}

// MARK: - Row

private struct ChatRow: View {
    let chat: ClaudeChatSummary
    let isWorking: Bool
    let isSettled: Bool
    let isConfirming: Bool
    let activate: () -> Void
    let toggleSettled: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 8) {
                leadingGlyph.frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(.system(size: 13))
                        .foregroundStyle(isSettled ? .tertiary : isWorking ? .primary : .secondary)
                        .lineLimit(1)
                    subtitle
                }
                Spacer(minLength: 0)
                if isHovering {
                    Button(action: toggleSettled) {
                        Image(systemName: isSettled ? "arrow.uturn.up" : "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tooltip(isSettled ? "Unsettle" : "Settle", alignment: .trailing)
                } else {
                    Text(chat.modified.compactRelative)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isConfirming ? Color.green.opacity(0.12)
                        : isWorking ? Color.primary.opacity(0.06)
                        : isHovering ? Color.primary.opacity(0.04)
                        : .clear
                )
        )
        .onHover { isHovering = $0 }
        .opacity(isSettled ? 0.7 : 1)
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if isConfirming {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemGreen))
                .transition(.scale(scale: 0.3).combined(with: .opacity))
        } else if isWorking {
            WorkingDot()
        } else if isSettled {
            Image(systemName: "checkmark")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .systemGreen))
        } else {
            Circle()
                .fill(Color(nsColor: .systemYellow))
                .frame(width: 7, height: 7)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if isWorking || chat.gitBranch != nil {
            HStack(spacing: 4) {
                if isWorking {
                    Text("Working")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemBlue))
                    if chat.gitBranch != nil {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let branch = chat.gitBranch {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(branch)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Working indicator

private struct WorkingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color(nsColor: .systemBlue))
            .frame(width: 7, height: 7)
            .background {
                if !reduceMotion {
                    Circle()
                        .stroke(Color(nsColor: .systemBlue), lineWidth: 1.5)
                        .scaleEffect(pulsing ? 2.6 : 1)
                        .opacity(pulsing ? 0 : 0.55)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }
    }
}

// MARK: - Sounds

enum ChatSounds {
    enum Cue { case settle, unsettle, newChat }

    static func play(_ cue: Cue) {
        guard AppSettings.shared.claudeChatSounds else { return }
        let (name, volume): (String, Float) = switch cue {
        case .settle: ("Pop", 0.4)
        case .unsettle: ("Tink", 0.3)
        case .newChat: ("Purr", 0.25)
        }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }
}

// MARK: - Compact relative time

extension Date {
    /// "32m" / "3h" / "2d" — a terse age with no formatter overhead.
    var compactRelative: String {
        let seconds = max(0, -timeIntervalSinceNow)
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}
