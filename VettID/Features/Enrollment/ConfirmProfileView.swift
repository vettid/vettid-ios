import SwiftUI

// MARK: - Confirm Profile View

/// After credential verification, shows the default public profile
/// for the user to confirm or skip publishing.
struct ConfirmProfileView: View {
    let displayName: String
    let email: String?
    let onConfirm: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Profile icon
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 100, height: 100)

                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
            }

            // Title
            VStack(spacing: 8) {
                Text("Your Public Profile")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("This is what others will see when they connect with you")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Profile card
            VStack(spacing: 16) {
                // Avatar placeholder
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 80, height: 80)

                    Text(initials)
                        .font(.title)
                        .fontWeight(.semibold)
                        .foregroundStyle(.blue)
                }

                Text(displayName)
                    .font(.title3)
                    .fontWeight(.semibold)

                if let email = email, !email.isEmpty {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.caption)
                    Text("Visible to connections")
                        .font(.caption)
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGray6))
            .cornerRadius(16)
            .padding(.horizontal)

            Text("You can edit your profile anytime from settings")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            // Action buttons
            VStack(spacing: 12) {
                Button(action: onConfirm) {
                    Text("Publish Profile")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onSkip) {
                    Text("Skip for Now")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    private var initials: String {
        let parts = displayName.split(separator: " ")
        let first = parts.first?.prefix(1) ?? ""
        let last = parts.count > 1 ? parts.last!.prefix(1) : ""
        return "\(first)\(last)".uppercased()
    }
}

// MARK: - Preview

#Preview {
    ConfirmProfileView(
        displayName: "Jane Doe",
        email: "jane.doe@example.com",
        onConfirm: {},
        onSkip: {}
    )
}
