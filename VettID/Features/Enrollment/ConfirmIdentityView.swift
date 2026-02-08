import SwiftUI

// MARK: - Confirm Identity View

/// Shows the identity from enrollment response for user confirmation.
/// The user can confirm or reject ("This is not my account").
struct ConfirmIdentityView: View {
    let firstName: String
    let lastName: String
    let email: String
    let onConfirm: () -> Void
    let onReject: () -> Void

    @State private var isReporting = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Identity icon
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 100, height: 100)

                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)
            }

            // Title
            VStack(spacing: 8) {
                Text("Confirm Your Identity")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Please verify the information below matches your account")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Identity card
            VStack(spacing: 16) {
                identityRow(label: "First Name", value: firstName)
                Divider()
                identityRow(label: "Last Name", value: lastName)
                Divider()
                identityRow(label: "Email", value: email)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(16)
            .padding(.horizontal)

            Spacer()

            // Action buttons
            VStack(spacing: 12) {
                Button(action: onConfirm) {
                    Text("Yes, This Is Me")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: {
                    isReporting = true
                }) {
                    Text("This Is Not My Account")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .alert("Report Mismatch", isPresented: $isReporting) {
            Button("Cancel", role: .cancel) {}
            Button("Report & Exit", role: .destructive) {
                onReject()
            }
        } message: {
            Text("If this identity doesn't match yours, we'll report a potential account mismatch and cancel enrollment.")
        }
    }

    private func identityRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)

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
