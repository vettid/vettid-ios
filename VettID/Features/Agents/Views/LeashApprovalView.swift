import SwiftUI

/// Owner-side approval surface for an agent-initiated LEASH mint
/// request. Mirrors Android `LeashApprovalScreen` (commit ef03314).
///
/// Reached as a root-level fullScreenCover when the vault pushes
/// `forApp.agent.leash-mint-pending`. The owner reviews the agent's
/// requested scope + duration + reason, can toggle scopes off, and
/// hits Approve → `agent.leash-approve` round-trip. The vault mints
/// (or denies) and publishes the JWT back to the agent's response
/// subject directly — the owner doesn't have to copy anything.
struct LeashApprovalView: View {
    let requestId: String
    let onDone: () -> Void

    @StateObject private var viewModel: LeashApprovalViewModel
    @Environment(\.dismiss) private var dismiss

    init(
        requestId: String,
        ownerSpaceClient: OwnerSpaceClient? = nil,
        onDone: @escaping () -> Void = {}
    ) {
        self.requestId = requestId
        self.onDone = onDone
        self._viewModel = StateObject(wrappedValue: LeashApprovalViewModel(
            ownerSpaceClient: ownerSpaceClient
        ))
    }

    var body: some View {
        ZStack {
            switch viewModel.state {
            case .waiting:
                waitingView
            case .ready(let notification, let scopes, let duration):
                readyForm(notification: notification, scopes: scopes, duration: duration)
            case .submitting:
                progress("Approving…")
            case .done:
                doneView
            case .error(let message):
                errorView(message)
            }
        }
        // Title mirrors Android `LeashApprovalScreen` line 44
        // ("LEASH approval").
        .navigationTitle("LEASH approval")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.bindRequest(requestId: requestId) }
        .onChange(of: stateKey) { _ in
            if case .done = viewModel.state {
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    onDone()
                    dismiss()
                }
            }
        }
    }

    private var stateKey: String {
        switch viewModel.state {
        case .waiting: return "waiting"
        case .ready: return "ready"
        case .submitting: return "submitting"
        case .done: return "done"
        case .error(let m): return "error:\(m)"
        }
    }

    // MARK: - Waiting

    private var waitingView: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.3)
            Text("Loading the request…")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Ready

    private func readyForm(
        notification: AgentLeashMintPendingNotification,
        scopes: [ScopeToggle],
        duration: Int
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(notification: notification)
                    if !notification.reason.isEmpty {
                        reasonCard(notification.reason)
                    }
                    scopePicker(scopes: scopes)
                    durationSection(current: duration)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await viewModel.deny() }
                } label: {
                    Text("Deny")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await viewModel.approve() }
                } label: {
                    Text("Approve")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
        }
    }

    private func header(notification: AgentLeashMintPendingNotification) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.title2)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.agentName)
                    .font(.headline)
                Text("wants a scoped LEASH for "
                     + Self.formatDuration(notification.durationSeconds))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reasonCard(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reason")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(reason)
                .font(.subheadline)
                .italic()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1))
        )
    }

    private func scopePicker(scopes: [ScopeToggle]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Section header mirrors Android `LeashApprovalScreen`
            // line 162 — "Scopes" (LEASH terminology), not the
            // looser "Permissions".
            Text("Scopes")
                .font(.subheadline).fontWeight(.semibold)
            Text("The LEASH lets the agent do these things. Toggle any off you don't want to grant.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(scopes) { toggle in
                    let meta = LeashScopeCatalog.meta(for: toggle.token)
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meta.label)
                                .font(.subheadline)
                            Text(meta.description)
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(toggle.token)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { toggle.granted },
                            set: { viewModel.toggleScope(toggle.token, granted: $0) }
                        ))
                        .labelsHidden()
                    }
                    .padding(.vertical, 8)
                    if toggle.token != scopes.last?.token {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.08))
            )
        }
    }

    private func durationSection(current: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Duration")
                .font(.subheadline).fontWeight(.semibold)
            // LEASH durations are short by design; default chip row
            // matches the AgentDetail mint UI in phase A.
            let presets: [(label: String, seconds: Int)] = [
                ("15 min", 15 * 60),
                ("30 min", 30 * 60),
                ("1 hour", 60 * 60),
                ("24 hours", 24 * 60 * 60)
            ]
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.seconds) { preset in
                        let selected = preset.seconds == current
                        Button {
                            viewModel.setDuration(preset.seconds)
                        } label: {
                            Text(preset.label)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(selected ? Color.yellow : Color.gray.opacity(0.15))
                                )
                                .foregroundColor(selected ? .black : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Done / Error

    private var doneView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Sent")
                .font(.title3).fontWeight(.semibold)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.red)
                .padding(.horizontal, 24)
            Button("Close") {
                onDone()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func progress(_ message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.3)
            Text(message)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    static func formatDuration(_ seconds: Int) -> String {
        if seconds >= 86400 { return "\(seconds / 86400) day\(seconds / 86400 == 1 ? "" : "s")" }
        if seconds >= 3600 { return "\(seconds / 3600) hour\(seconds / 3600 == 1 ? "" : "s")" }
        return "\(seconds / 60) min"
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        LeashApprovalView(requestId: "preview")
    }
}
#endif
