import SwiftUI

/// Screen for creating a new agent invitation.
/// User enters a name, the vault creates an invitation,
/// and the screen displays the invite command for `vettid-agent init`.
struct CreateAgentInvitationView: View {
    @StateObject private var viewModel: CreateAgentInvitationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var agentName = ""
    @State private var showCopiedFeedback = false

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self._viewModel = StateObject(wrappedValue: CreateAgentInvitationViewModel(
            ownerSpaceClient: ownerSpaceClient
        ))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .ready:
                readyContent

            case .creating:
                creatingContent

            case .created(let inviteToken, _, let shortLink):
                createdContent(inviteToken: inviteToken, shortLink: shortLink)

            case .error(let message):
                errorContent(message)
            }
        }
        .navigationTitle("Create Agent Invitation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Ready Content

    private var readyContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Agent icon
                Image(systemName: "cpu")
                    .font(.system(size: 50))
                    .foregroundColor(.accentColor)
                    .padding(.top, 24)

                VStack(spacing: 8) {
                    Text("Connect an Agent")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Create an invitation to connect an AI agent tool to your vault.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                // Name field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Agent Name")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    TextField("e.g., Claude Code, GitHub Copilot", text: $agentName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 24)

                // Info card
                infoCard
                    .padding(.horizontal, 24)

                // Create button
                Button {
                    Task {
                        await viewModel.createInvitation(agentName: agentName)
                    }
                } label: {
                    HStack {
                        Image(systemName: "plus")
                        Text("Create Invitation")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Creating Content

    private var creatingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Creating invitation...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Created Content

    private func createdContent(inviteToken: String, shortLink: String) -> some View {
        let initCommand = "vettid-agent init \(shortLink)"

        return ScrollView {
            VStack(spacing: 24) {
                // Success icon
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.green)
                    .padding(.top, 24)

                VStack(spacing: 8) {
                    Text("Invitation Created")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Run this command on the machine where your agent runs:")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                // Command card
                VStack(alignment: .leading, spacing: 12) {
                    Text("INIT COMMAND")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)

                    Text(initCommand)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        UIPasteboard.general.string = initCommand
                        showCopiedFeedback = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showCopiedFeedback = false
                        }
                    } label: {
                        HStack {
                            Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                            Text(showCopiedFeedback ? "Copied!" : "Copy Command")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal, 24)

                // Security note
                securityWarning
                    .padding(.horizontal, 24)

                // Done button
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Error Content

    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

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
                Task {
                    await viewModel.createInvitation(agentName: agentName)
                }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
    }

    // MARK: - Info Card

    private var infoCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("How it works")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("After creating the invitation, run the invite command on the machine where your agent runs. The agent will connect to your vault with \"always ask\" approval mode by default.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(12)
    }

    // MARK: - Security Warning

    private var securityWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.caption)

            Text("This invitation expires in 24 hours. Do not share it with others.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(Color.red.opacity(0.08))
        .cornerRadius(12)
    }
}

#if DEBUG
struct CreateAgentInvitationView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            CreateAgentInvitationView()
        }
    }
}
#endif
