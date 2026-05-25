import SwiftUI

/// Screen for creating a new agent invitation.
/// User enters a name, the vault creates an invitation,
/// and the screen displays the invite command for `vettid-agent init`.
struct CreateAgentInvitationView: View {
    @StateObject private var viewModel: CreateAgentInvitationViewModel
    @Environment(\.dismiss) private var dismiss
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

            case .created(let inviteCode, _, _):
                createdContent(inviteCode: inviteCode)

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

                    Text("Create an invitation to connect an AI agent tool to your vault. You'll name it and pick its permissions after the agent connects.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                // Info card (Area G — Android bbe0f2a: name + scope
                // prompt deferred to AuthorizeAgentView at Stage 2).
                infoCard
                    .padding(.horizontal, 24)

                // Create button
                Button {
                    Task {
                        // Empty name → vault uses "Pending agent…"
                        // placeholder until Stage 2 writes the real
                        // name (Android 8649b2f).
                        await viewModel.createInvitation(agentName: "")
                    }
                } label: {
                    HStack {
                        Image(systemName: "plus")
                        Text("Create Invitation")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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

    private func createdContent(inviteCode: String) -> some View {
        let dashed = Self.formatInviteCode(inviteCode)
        let initCommand = "vettid-agent init \(inviteCode)"

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

                    Text("Type this code into `vettid-agent init` on the machine where your agent runs:")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                // Invite code card — large, monospace, dash-grouped
                // (ABCD-EFGH-JKLM). Mirrors Android aecfa99.
                VStack(alignment: .leading, spacing: 12) {
                    Text("INVITE CODE")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)

                    Text(dashed)
                        .font(.system(.title, design: .monospaced).weight(.bold))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Button {
                        UIPasteboard.general.string = initCommand
                        showCopiedFeedback = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showCopiedFeedback = false
                        }
                    } label: {
                        HStack {
                            Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                            Text(showCopiedFeedback ? "Copied!" : "Copy `vettid-agent init` command")
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
                    await viewModel.createInvitation(agentName: "")
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

                Text("Tap Create to generate an invite code. Run the invite command on the machine where your agent runs, then you'll review and name the agent before approving the session.")
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

            Text("This code expires in 2 minutes. You'll be asked to approve the connection after the agent uses it.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(Color.red.opacity(0.08))
        .cornerRadius(12)
    }

    /// Display a 12-char ambiguity-safe invite code as three 4-char
    /// groups (ABCD-EFGH-JKLM). Anything other than 12 chars falls
    /// through unmodified. Mirrors Android `formatInviteCode`.
    private static func formatInviteCode(_ code: String) -> String {
        guard code.count == 12 else { return code }
        let a = code.prefix(4)
        let bStart = code.index(code.startIndex, offsetBy: 4)
        let bEnd = code.index(code.startIndex, offsetBy: 8)
        let b = code[bStart..<bEnd]
        let c = code.suffix(4)
        return "\(a)-\(b)-\(c)"
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
