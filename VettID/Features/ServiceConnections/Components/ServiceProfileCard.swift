import SwiftUI

/// Card displaying service profile information
struct ServiceProfileCard: View {
    let profile: ServiceProfile
    let compact: Bool

    init(profile: ServiceProfile, compact: Bool = true) {
        self.profile = profile
        self.compact = compact
    }

    var body: some View {
        if compact {
            compactCard
        } else {
            fullCard
        }
    }

    // MARK: - Compact Card

    private var compactCard: some View {
        HStack(spacing: 12) {
            // Service Logo
            ServiceLogoView(url: profile.serviceLogoUrl, size: 50)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(profile.serviceName)
                        .font(.headline)
                        .lineLimit(1)

                    if profile.organization.verified {
                        VerificationBadge(type: profile.organization.verificationType)
                    }
                }

                Text(profile.serviceCategory.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Full Card

    private var fullCard: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 16) {
                ServiceLogoView(url: profile.serviceLogoUrl, size: 80)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(profile.serviceName)
                            .font(.title2)
                            .fontWeight(.bold)
                            .lineLimit(2)

                        if profile.organization.verified {
                            VerificationBadge(type: profile.organization.verificationType)
                        }
                    }

                    Text(profile.organization.name)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack {
                        Image(systemName: profile.serviceCategory.icon)
                            .foregroundColor(.blue)
                        Text(profile.serviceCategory.displayName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }

            // Description
            Text(profile.serviceDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Verified Contacts
            if !profile.contactInfo.emails.isEmpty || !profile.contactInfo.phoneNumbers.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Verified Contact")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)

                    if let primaryEmail = profile.contactInfo.emails.first(where: { $0.primary }) ?? profile.contactInfo.emails.first {
                        HStack {
                            Image(systemName: "envelope.fill")
                                .foregroundColor(.blue)
                                .frame(width: 20)
                            Text(primaryEmail.value)
                                .font(.subheadline)
                            if primaryEmail.verified {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            }
                        }
                    }

                    if let primaryPhone = profile.contactInfo.phoneNumbers.first(where: { $0.primary }) ?? profile.contactInfo.phoneNumbers.first {
                        HStack {
                            Image(systemName: "phone.fill")
                                .foregroundColor(.blue)
                                .frame(width: 20)
                            Text(primaryPhone.value)
                                .font(.subheadline)
                            if primaryPhone.verified {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(16)
    }
}

// MARK: - Service Logo View

struct ServiceLogoView: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: URL(string: url ?? "")) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Image(systemName: "building.2.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(size * 0.2)
                .foregroundColor(.white)
                .background(Color.blue)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}

// MARK: - Verification Badge

struct VerificationBadge: View {
    let type: VerificationType?

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark.seal.fill")
                .font(.caption)
            if let type = type {
                Text(badgeText(for: type))
                    .font(.caption2)
                    .fontWeight(.medium)
            }
        }
        .foregroundColor(badgeColor)
    }

    private func badgeText(for type: VerificationType) -> String {
        switch type {
        case .business: return "Business"
        case .nonprofit: return "Nonprofit"
        case .government: return "Gov"
        }
    }

    private var badgeColor: Color {
        guard let type = type else { return .blue }
        switch type {
        case .business: return .blue
        case .nonprofit: return .green
        case .government: return .purple
        }
    }
}

// MARK: - Service Connection Row

struct ServiceConnectionRow: View {
    let connection: ServiceConnectionRecord

    var body: some View {
        HStack(spacing: 12) {
            // Service Logo
            ServiceLogoView(url: connection.serviceProfile.serviceLogoUrl, size: 50)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(connection.serviceProfile.serviceName)
                        .font(.headline)
                        .lineLimit(1)

                    if connection.serviceProfile.organization.verified {
                        VerificationBadge(type: connection.serviceProfile.organization.verificationType)
                    }

                    Spacer()

                    if let lastActivity = connection.lastActivityAt {
                        Text(lastActivity, style: .relative)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Text(connection.serviceProfile.serviceCategory.displayName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    // Status indicators
                    HStack(spacing: 4) {
                        if connection.isFavorite {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                                .font(.caption)
                        }

                        if connection.isMuted {
                            Image(systemName: "bell.slash.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }

                        if connection.pendingContractVersion != nil {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                        }

                        ServiceConnectionStatusBadge(status: connection.status)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Service Connection Status Badge

struct ServiceConnectionStatusBadge: View {
    let status: ServiceConnectionStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundColor(textColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .cornerRadius(4)
    }

    private var textColor: Color {
        switch status {
        case .pending: return .orange
        case .active: return .green
        case .suspended: return .red
        case .revoked, .expired: return .gray
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .pending: return .orange.opacity(0.2)
        case .active: return .green.opacity(0.2)
        case .suspended: return .red.opacity(0.2)
        case .revoked, .expired: return .gray.opacity(0.2)
        }
    }
}

#if DEBUG
struct ServiceProfileCard_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            Text("Preview requires mock data")
                .foregroundColor(.secondary)
        }
        .padding()
    }
}
#endif
