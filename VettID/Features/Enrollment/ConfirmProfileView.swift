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
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer().frame(height: 12)

                    Image(systemName: "person.crop.circle.badge.checkmark.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor)

                    VStack(spacing: 8) {
                        Text("Your Public Profile")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("This is what others will see when they connect with you.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    profileCard
                    privacyNote
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            VStack(spacing: 8) {
                Button(action: onConfirm) {
                    Text("Publish Profile")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onSkip) {
                    Text("Skip for now")
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
    }

    private var profileCard: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 80, height: 80)

                Text(initials)
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
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
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.1))
            .clipShape(Capsule())
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var privacyNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.footnote)
                .foregroundStyle(Color.accentColor)
            Text("You can edit your public profile anytime from Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
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
