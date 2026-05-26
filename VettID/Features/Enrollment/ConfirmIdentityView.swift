import SwiftUI

// MARK: - Confirm Identity View

/// Matches Android `ConfirmIdentityPhaseContent`: shows the identity
/// from the enrollment response with a "what your connections will
/// see" preview + a security note, in a scrollable centered layout.
/// Photo picker is intentionally deferred (Android treats it as
/// optional) — iOS adds it in the post-enrollment profile step.
struct ConfirmIdentityView: View {
    let firstName: String
    let lastName: String
    let email: String
    let onConfirm: () -> Void
    let onReject: () -> Void

    @State private var isReporting = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer().frame(height: 12)

                    avatarPlaceholder

                    VStack(spacing: 8) {
                        Text("Is this right?")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Here's what we have on file for you")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    identityCard
                    connectionsCard
                    securityNote
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            VStack(spacing: 8) {
                Button(action: onConfirm) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Continue")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    isReporting = true
                } label: {
                    Text("Something's wrong")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .alert("Report Mismatch", isPresented: $isReporting) {
            Button("Cancel", role: .cancel) {}
            Button("Report & Exit", role: .destructive) { onReject() }
        } message: {
            Text("If this identity doesn't match yours, we'll report a potential account mismatch and cancel enrollment.")
        }
    }

    // MARK: - Sections

    private var avatarPlaceholder: some View {
        ZStack {
            Circle()
                .fill(Color(.systemGray5))
                .frame(width: 112, height: 112)
            Image(systemName: "person.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
        }
    }

    private var identityCard: some View {
        VStack(spacing: 0) {
            identityRow(icon: "person.text.rectangle", label: "First Name", value: firstName)
            Divider().padding(.vertical, 12)
            identityRow(icon: "person.text.rectangle", label: "Last Name", value: lastName)
            Divider().padding(.vertical, 12)
            identityRow(icon: "envelope.fill", label: "Email", value: email)
        }
        .padding(20)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var connectionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "eye.fill")
                    .font(.subheadline)
                Text("What your connections will see")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            Text("• Your name\n• Your email address\n• Your profile photo (when you add one)")
                .font(.footnote)
            Text("Everything else stays private until you choose to share it from the Data tab.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.accentColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var securityNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.footnote)
                .foregroundStyle(Color.accentColor)
            Text("This information will be stored securely in your encrypted vault")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    private func identityRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body)
                    .fontWeight(.medium)
            }
            Spacer()
        }
    }
}

// MARK: - Preview

#Preview {
    ConfirmIdentityView(
        firstName: "Jane",
        lastName: "Doe",
        email: "jane.doe@example.com",
        onConfirm: {},
        onReject: {}
    )
}
