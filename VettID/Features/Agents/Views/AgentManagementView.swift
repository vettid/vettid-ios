import SwiftUI

/// Agent management screen showing connected agents.
/// Supports viewing, revoking, and navigating to create new invitations.
struct AgentManagementView: View {
    @StateObject private var viewModel: AgentManagementViewModel
    @State private var showCreateInvitation = false
    @State private var agentToRevoke: AgentConnection?

    private let ownerSpaceClient: OwnerSpaceClient?

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.ownerSpaceClient = ownerSpaceClient
        self._viewModel = StateObject(wrappedValue: AgentManagementViewModel(
            ownerSpaceClient: ownerSpaceClient
        ))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                loadingView

            case .empty:
                emptyView

            case .loaded(let agents):
                agentsList(agents)

            case .error(let message):
                errorView(message)
            }
        }
        .navigationTitle("Agent Connections")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateInvitation = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreateInvitation) {
            // Refresh after dismissing create invitation
            Task { await viewModel.loadAgents() }
        } content: {
            NavigationStack {
                CreateAgentInvitationView(ownerSpaceClient: ownerSpaceClient)
            }
        }
        .alert("Revoke Agent?", isPresented: showRevokeAlert) {
            Button("Cancel", role: .cancel) {
                agentToRevoke = nil
            }
            Button("Revoke", role: .destructive) {
                if let agent = agentToRevoke {
                    Task { await viewModel.revokeAgent(connectionId: agent.connectionId) }
                    agentToRevoke = nil
                }
            }
        } message: {
            if let agent = agentToRevoke {
                Text("This will permanently disconnect \"\(agent.agentName)\" and revoke its access to your secrets. This cannot be undone.")
            }
        }
        .task {
            await viewModel.loadAgents()
        }
    }

    // MARK: - Alert Binding

    private var showRevokeAlert: Binding<Bool> {
        Binding(
            get: { agentToRevoke != nil },
            set: { if !$0 { agentToRevoke = nil } }
        )
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack {
            ProgressView()
            Text("Loading agents...")
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "cpu")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Agents Connected")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Connect AI agent tools to your vault to give them secure access to your secrets. You control what each agent can access.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                showCreateInvitation = true
            } label: {
                Label("Create Invitation", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Agents List

    private func agentsList(_ agents: [AgentConnection]) -> some View {
        List {
            ForEach(agents) { agent in
                AgentRow(agent: agent)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if agent.isActive {
                            Button(role: .destructive) {
                                agentToRevoke = agent
                            } label: {
                                Label("Revoke", systemImage: "xmark.shield")
                            }
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.loadAgents()
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.red)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                Task { await viewModel.loadAgents() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Agent Row

private struct AgentRow: View {
    let agent: AgentConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon, name, status badge
            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.agentName)
                        .font(.headline)

                    if !agent.agentType.isEmpty {
                        Text(agent.displayAgentType)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                AgentStatusBadge(status: agent.status)
            }

            // Details
            if let hostname = agent.hostname, !hostname.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(buildHostnameLabel(hostname: hostname, platform: agent.platform))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "shield.checkered")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(agent.approvalModeDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func buildHostnameLabel(hostname: String, platform: String?) -> String {
        if let platform = platform, !platform.isEmpty {
            return "\(hostname) (\(platform))"
        }
        return hostname
    }
}

// MARK: - Agent Status Badge

private struct AgentStatusBadge: View {
    let status: String

    var body: some View {
        Text(status.prefix(1).uppercased() + status.dropFirst())
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor)
            .cornerRadius(8)
    }

    private var textColor: Color {
        switch status {
        case "active": return .green
        case "invited": return .orange
        case "revoked": return .red
        default: return .secondary
        }
    }

    private var backgroundColor: Color {
        switch status {
        case "active": return .green.opacity(0.15)
        case "invited": return .orange.opacity(0.15)
        case "revoked": return .red.opacity(0.15)
        default: return .secondary.opacity(0.15)
        }
    }
}

#if DEBUG
struct AgentManagementView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            AgentManagementView()
        }
    }
}
#endif
