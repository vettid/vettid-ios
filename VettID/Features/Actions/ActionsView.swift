import SwiftUI

// MARK: - Actions View

/// Top-level Actions surface (Phase 3.11, parity with Android
/// `ActionScreens.kt`).
///
/// Two tabs:
///   - **My Actions** — the catalog of actions I've published to
///     connections, with per-row enabled toggle.
///   - **Pending** — invocations from peers waiting on my
///     approve/deny (only relevant for actions whose auth mode is
///     `CONSENT_PER_CALL`).
///
/// Peer-side "invoke an action" sheets live on the connection-detail
/// screen — `InvokePeerActionSheet` shows up there once the peer-
/// actions list is wired in. This top-level view is owner-side only.
struct ActionsView: View {

    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ActionsViewModel()
    @State private var selectedTab: ActionsTab = .myActions

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selectedTab) {
                ForEach(ActionsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            content
        }
        .navigationTitle("Actions")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.client = appState.actionsClient
            await viewModel.load()
        }
        .refreshable { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .myActions:
            if viewModel.myActions.isEmpty {
                emptyView(title: "No actions published",
                          message: "Actions you publish to connections will show up here.")
            } else {
                List(viewModel.myActions) { action in
                    MyActionRow(action: action) { newValue in
                        Task { await viewModel.setEnabled(actionId: action.actionId, enabled: newValue) }
                    }
                }
                .listStyle(.insetGrouped)
            }
        case .pending:
            if viewModel.pending.isEmpty {
                emptyView(title: "No invocations waiting",
                          message: "When a connection invokes one of your consent-per-call actions, it'll appear here.")
            } else {
                List(viewModel.pending) { req in
                    PendingActionRow(approval: req) {
                        Task { await viewModel.approve(requestId: req.requestId) }
                    } onDeny: {
                        Task { await viewModel.deny(requestId: req.requestId) }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func emptyView(title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "wand.and.stars")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Tabs

private enum ActionsTab: String, CaseIterable, Identifiable {
    case myActions, pending
    var id: String { rawValue }
    var title: String {
        switch self {
        case .myActions: return "My Actions"
        case .pending:   return "Pending"
        }
    }
}

// MARK: - Rows

private struct MyActionRow: View {
    let action: PublishedAction
    let onToggle: (Bool) -> Void

    @State private var enabled: Bool

    init(action: PublishedAction, onToggle: @escaping (Bool) -> Void) {
        self.action = action
        self.onToggle = onToggle
        self._enabled = State(initialValue: action.enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.name).font(.subheadline.weight(.medium))
                    Text(action.authMode.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .onChange(of: enabled) { newValue in
                        onToggle(newValue)
                    }
            }
            if !action.descriptionText.isEmpty {
                Text(action.descriptionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !action.allowlist.isEmpty {
                Text("Allowlist: \(action.allowlist.count) connection\(action.allowlist.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PendingActionRow: View {
    let approval: PendingActionApproval
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.orange)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rowTitle).font(.subheadline.weight(.medium))
                    if !approval.params.isEmpty {
                        Text(paramsSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Spacer()
                Button(role: .destructive, action: onDeny) {
                    Text("Deny").font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: onApprove) {
                    Text("Approve").font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var rowTitle: String {
        let who = approval.peerLabel.isEmpty ? "A connection" : approval.peerLabel
        return "\(who) → \(approval.actionName)"
    }

    private var paramsSummary: String {
        approval.params
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
    }
}
