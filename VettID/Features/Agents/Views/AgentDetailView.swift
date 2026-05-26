import SwiftUI

/// Per-agent details screen — mirrors Android `AgentDetailScreen`
/// (commits a1d7acc + 855a9f5 + def1ee8 + 4c81a75). Reached from
/// `AgentManagementView` row-tap (settings → agents → tap row).
///
/// Two distinct affordances:
///
///   1. Bulk visibility — toggle which minor secrets are
///      catalog-visible to peers + agents. Global flip (not
///      per-connection); matches Android's current model.
///
///   2. Mint LEASH — issue a scoped, short-lived JWT for an existing
///      agent. The dialog renders the curated LEASH scope vocabulary
///      as toggles, plus a free-form "custom scope" field validated
///      against the LEASH grammar. Duration chips: 15m / 30m / 1h /
///      24h (default 30m). Result dialog shows the JWT, jti,
///      expires-at, and a copy button.
struct AgentDetailView: View {
    let connectionId: String

    @StateObject private var viewModel: AgentDetailViewModel
    @Environment(\.dismiss) private var dismiss

    init(connectionId: String, ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.connectionId = connectionId
        self._viewModel = StateObject(wrappedValue: AgentDetailViewModel(
            ownerSpaceClient: ownerSpaceClient
        ))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView().scaleEffect(1.3)
            case .error(let message):
                errorView(message)
            case .loaded(let agent, let items, let mint):
                loadedContent(agent: agent, items: items, mintDialog: mint)
            }
        }
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.bind(connectionId: connectionId)
        }
        .alert("Notice", isPresented: Binding(
            get: { viewModel.toast != nil },
            set: { if !$0 { viewModel.toast = nil } }
        )) {
            Button("OK") { viewModel.toast = nil }
        } message: {
            if let msg = viewModel.toast { Text(msg) }
        }
    }

    // MARK: - Loaded

    private func loadedContent(
        agent: AgentConnection,
        items: [VisibilityItem],
        mintDialog: MintDialogState?
    ) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                header(agent: agent)
                sectionCard(title: "Mint LEASH") {
                    mintLaunchButton()
                }
                sectionCard(title: "Visible to this agent") {
                    visibilityList(items: items)
                }
            }
            .padding(16)
        }
        .refreshable { await viewModel.refresh() }
        .sheet(isPresented: Binding(
            get: { mintDialog != nil },
            set: { if !$0 { viewModel.closeMint() } }
        )) {
            if let dialog = mintDialog {
                NavigationStack {
                    if let result = dialog.result {
                        MintResultSheet(result: result, agent: agent) {
                            viewModel.closeMint()
                        }
                    } else {
                        MintDialogSheet(
                            dialog: dialog,
                            agentName: agent.agentName,
                            onToggleScope: { viewModel.mintToggleScope($0, granted: $1) },
                            onSetCustom: { viewModel.mintSetCustomScope($0) },
                            onSetDuration: { viewModel.mintSetDuration($0) },
                            onCancel: { viewModel.closeMint() },
                            onMint: { Task { await viewModel.mintConfirm() } }
                        )
                    }
                }
            }
        }
    }

    private func header(agent: AgentConnection) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.yellow.opacity(0.95))
                Image(systemName: "cpu")
                    .font(.system(size: 32))
                    .foregroundStyle(.black)
            }
            .frame(width: 64, height: 64)
            Text(agent.agentName).font(.title3).fontWeight(.semibold)
            if !agent.agentType.isEmpty {
                Text(agent.agentType)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func mintLaunchButton() -> some View {
        Button {
            viewModel.openMint()
        } label: {
            HStack {
                Image(systemName: "key.fill")
                Text("Mint a LEASH for this agent")
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func visibilityList(items: [VisibilityItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Toggle which secrets this agent can see in your catalog. Visibility is global — peers see the same set.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Show all") { Task { await viewModel.bulkSet(makeVisible: true) } }
                    .buttonStyle(.bordered).font(.caption)
                Button("Hide all") { Task { await viewModel.bulkSet(makeVisible: false) } }
                    .buttonStyle(.bordered).font(.caption)
                Spacer()
            }
            if items.isEmpty {
                Text("No secrets yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        VisibilityRow(
                            item: item,
                            onToggle: { newValue in
                                Task {
                                    await viewModel.toggleVisibility(secretId: item.secretId, makeVisible: newValue)
                                }
                            }
                        )
                        if item.id != items.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.red)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.red)
                .padding(.horizontal, 24)
            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.08))
        )
    }
}

// MARK: - Visibility row

private struct VisibilityRow: View {
    let item: VisibilityItem
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline)
                HStack(spacing: 6) {
                    if let alias = item.alias, !alias.isEmpty {
                        Text(alias)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.category.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { item.visible },
                set: { onToggle($0) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Mint dialog sheet

private struct MintDialogSheet: View {
    let dialog: MintDialogState
    let agentName: String
    let onToggleScope: (String, Bool) -> Void
    let onSetCustom: (String) -> Void
    let onSetDuration: (Int) -> Void
    let onCancel: () -> Void
    let onMint: () -> Void

    var body: some View {
        Form {
            Section {
                Text("Mint a scoped, short-lived JWT for \(agentName). The agent uses this LEASH to call resource servers (your profile, wallet, etc.) on your behalf within the scope you grant.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Scopes") {
                ForEach(dialog.scopes) { toggle in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(
                            get: { toggle.granted },
                            set: { onToggleScope(toggle.token, $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(toggle.label).font(.subheadline)
                                Text(toggle.description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(toggle.token)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom scope")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField(
                        "resource:action (e.g. wallet.balance:read)",
                        text: Binding(
                            get: { dialog.customScope },
                            set: { onSetCustom($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.caption.monospaced())
                    Text("Grammar: resource:action[:qualifier]. Vault re-validates.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Section("Duration") {
                let presets: [(String, Int)] = [
                    ("15 min", 15 * 60),
                    ("30 min", 30 * 60),
                    ("1 hour", 60 * 60),
                    ("24 hours", 24 * 60 * 60)
                ]
                Picker("Length", selection: Binding(
                    get: { dialog.durationSeconds },
                    set: { onSetDuration($0) }
                )) {
                    ForEach(presets, id: \.1) { (label, seconds) in
                        Text(label).tag(seconds)
                    }
                }
                .pickerStyle(.segmented)
            }

            if let error = dialog.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Mint LEASH")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
                    .disabled(dialog.submitting)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(dialog.submitting ? "Minting…" : "Mint") {
                    onMint()
                }
                .disabled(dialog.submitting)
            }
        }
    }
}

// MARK: - Mint result sheet

private struct MintResultSheet: View {
    let result: MintResult
    let agent: AgentConnection
    let onDone: () -> Void

    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "key.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.yellow)
                    .padding(.top, 20)
                Text("LEASH minted")
                    .font(.title3).fontWeight(.semibold)
                Text("Hand this JWT to \(agent.agentName) — paste it into the agent's CLI or hand off via QR. The token is bound to the agent's pubkey; nobody else can use it.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                jwtCard

                detailsCard

                Button {
                    UIPasteboard.general.string = result.jwt
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied!" : "Copy JWT", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 16)

                Button("Done", action: onDone)
                    .buttonStyle(.bordered)
            }
            .padding(.bottom, 24)
        }
        .navigationTitle("LEASH")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var jwtCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LEASH JWT")
                .font(.caption).foregroundStyle(.secondary)
            Text(result.jwt)
                .font(.footnote.monospaced())
                .lineLimit(nil)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1))
        )
        .padding(.horizontal, 16)
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("jti").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Text(result.jti)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            HStack {
                Text("Expires").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Text(Self.formatExpiry(result.expiresAt))
                    .font(.footnote)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.08))
        )
        .padding(.horizontal, 16)
    }

    private static func formatExpiry(_ epochSeconds: Int) -> String {
        guard epochSeconds > 0 else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        AgentDetailView(connectionId: "preview")
    }
}
#endif
