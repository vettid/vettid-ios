import SwiftUI

/// Stage-2 agent authorisation. Mirror of `AuthorizeAgentScreen.kt`
/// (Android 830ba5f) — owner reviews the agent's identity card,
/// toggles requested scopes, picks duration + approval mode, and
/// hits Approve to authorize the session.
struct AuthorizeAgentView: View {
    let connectionId: String
    let onAuthorized: () -> Void
    let onDeny: () -> Void

    @StateObject private var viewModel: AuthorizeAgentViewModel
    @Environment(\.dismiss) private var dismiss

    init(
        connectionId: String,
        ownerSpaceClient: OwnerSpaceClient? = nil,
        onAuthorized: @escaping () -> Void = {},
        onDeny: @escaping () -> Void = {}
    ) {
        self.connectionId = connectionId
        self.onAuthorized = onAuthorized
        self.onDeny = onDeny
        self._viewModel = StateObject(wrappedValue: AuthorizeAgentViewModel(
            ownerSpaceClient: ownerSpaceClient
        ))
    }

    var body: some View {
        ZStack {
            switch viewModel.state {
            case .waiting:
                waitingView
            case .ready(let notification, let scopes, let approvalMode, let duration, let rateLimitMax, let rateLimitPer):
                readyForm(
                    notification: notification,
                    scopes: scopes,
                    approvalMode: approvalMode,
                    duration: duration,
                    rateLimitMax: rateLimitMax,
                    rateLimitPer: rateLimitPer
                )
            case .submitting:
                progress("Authorising…")
            case .done:
                doneView
            case .error(let message):
                errorView(message)
            }
        }
        .navigationTitle("Authorize Agent")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.bindConnection(connectionId: connectionId)
        }
        .onChange(of: stateKey) { _ in
            switch viewModel.state {
            case .done:
                // Area H — route to onDeny when the .done was driven
                // by a Deny tap so the root cover can clear
                // pendingAgentAuth either way and any future telemetry
                // can distinguish accepted vs. denied pairings.
                let denied = viewModel.lastActionWasDeny
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if denied { onDeny() } else { onAuthorized() }
                    dismiss()
                }
            default:
                break
            }
        }
    }

    /// Stable key so `.onChange` fires on state transitions.
    private var stateKey: String {
        switch viewModel.state {
        case .waiting:    return "waiting"
        case .ready:      return "ready"
        case .submitting: return "submitting"
        case .done:       return "done"
        case .error(let m): return "error:\(m)"
        }
    }

    // MARK: - Waiting

    private var waitingView: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.3)
            Text("Waiting for agent to connect…")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Ready form

    private func readyForm(
        notification: AgentPendingAuthNotification,
        scopes: [ScopeToggle],
        approvalMode: String,
        duration: Int,
        rateLimitMax: Int,
        rateLimitPer: String
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(notification: notification)
                    identityCard(notification: notification)
                    scopePicker(scopes: scopes)
                    approvalModeSection(notification: notification, current: approvalMode)
                    durationSection(notification: notification, current: duration)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            // Action row pinned to the bottom outside the scroll.
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

    private func header(notification: AgentPendingAuthNotification) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.title2)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Authorize this agent")
                    .font(.headline)
                Text(notification.agentMetadata?.agentType.isEmpty == false
                     ? notification.agentMetadata!.agentType
                     : "Agent")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func identityCard(notification: AgentPendingAuthNotification) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let meta = notification.agentMetadata {
                if !meta.hostname.isEmpty {
                    infoRow(label: "Hostname", value: meta.hostname)
                }
                if !meta.platform.isEmpty {
                    infoRow(label: "Platform", value: meta.platform)
                }
                let osLabel = [meta.osName, meta.osVersion]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !osLabel.isEmpty {
                    infoRow(label: "OS", value: osLabel)
                }
                if !meta.appVersion.isEmpty {
                    infoRow(label: "App version", value: meta.appVersion)
                }
                if !meta.binaryFingerprint.isEmpty {
                    infoRow(label: "Binary fingerprint", value: meta.binaryFingerprint, mono: true)
                }
                if !meta.machineFingerprint.isEmpty {
                    infoRow(label: "Machine fingerprint", value: meta.machineFingerprint, mono: true)
                }
            } else if !notification.binaryFpPrefix.isEmpty {
                // No full metadata available — at least show the prefix.
                infoRow(label: "Binary fingerprint", value: notification.binaryFpPrefix, mono: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1))
        )
    }

    private func scopePicker(scopes: [ScopeToggle]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permissions")
                .font(.subheadline).fontWeight(.semibold)
            Text("The agent requested these. Toggle any off you don't want to grant.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(scopes) { toggle in
                    let meta = AgentScopeLabels.meta(for: toggle.token)
                    HStack(alignment: .top, spacing: 10) {
                        if meta.sensitive {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.subheadline)
                                .padding(.top, 2)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meta.label)
                                .font(.subheadline.weight(meta.sensitive ? .semibold : .regular))
                            Text(meta.description)
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
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

    private func approvalModeSection(
        notification: AgentPendingAuthNotification,
        current: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Approval mode")
                .font(.subheadline).fontWeight(.semibold)
            let agentAskedForAuto = notification.requestedApprovalMode == "auto_within_contract"
            Picker("Mode", selection: Binding(
                get: { current },
                set: { viewModel.setApprovalMode($0) }
            )) {
                Text("Always ask").tag("always_ask")
                Text("Auto within scope").tag("auto_within_contract")
                    .disabled(!agentAskedForAuto)
            }
            .pickerStyle(.segmented)
            if !agentAskedForAuto {
                Text("This agent didn't ask for auto-approval, so it stays disabled.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func durationSection(
        notification: AgentPendingAuthNotification,
        current: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Session duration")
                .font(.subheadline).fontWeight(.semibold)
            // Android `AuthorizeAgentScreen`: agents get the
            // shorter preset row — no multi-day options. 24 h vault
            // cap enforced server-side regardless.
            let presets = Self.durationPresets(maxSeconds: notification.maxDurationSeconds)
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
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Done / Error / Progress

    private var doneView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Authorized")
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
            Button("Close") { dismiss() }
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

    private func infoRow(label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(mono ? .caption.monospaced() : .footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    /// Preset session lengths the chip row scrolls through, clamped
    /// to the vault's `max_duration_seconds`. Agents get a shorter
    /// list than desktops — no multi-day options.
    private static func durationPresets(maxSeconds: Int) -> [(label: String, seconds: Int)] {
        let all: [(String, Int)] = [
            ("1 hour", 60 * 60),
            ("4 hours", 4 * 60 * 60),
            ("8 hours", 8 * 60 * 60),
            ("12 hours", 12 * 60 * 60),
            ("1 day", 24 * 60 * 60)
        ]
        let filtered = all.filter { $0.1 <= maxSeconds }
        let chosen = filtered.isEmpty ? [all[0]] : filtered
        return chosen.map { (label: $0.0, seconds: $0.1) }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        AuthorizeAgentView(connectionId: "preview")
    }
}
#endif
