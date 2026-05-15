import SwiftUI

// MARK: - Business Card View

/// Shared peer-profile renderer. One component, used by Connection
/// Review, Connection Detail, and the own-profile preview. Matches
/// Android's single `BusinessCardView` surface — eliminates the
/// ad-hoc `profileContent` / `ProfileInfoSection` split that iOS had
/// before Phase 1.5.
///
/// Layout sections (each conditional on the data being present):
///   - Avatar + display name + email
///   - Bio + location (own-profile path)
///   - Identity key (peer-only)
///   - Wallet addresses
///   - Custom profile fields (vault `field_order` respected)
struct BusinessCardView: View {

    let card: BusinessCardData

    /// Avatar diameter — callers can shrink it for compact row layouts.
    var avatarSize: CGFloat = 80

    var body: some View {
        VStack(spacing: 16) {
            header
            if let bio = card.bio, !bio.isEmpty {
                bioSection(bio)
            }
            if let location = card.location, !location.isEmpty {
                locationRow(location)
            }
            if let key = card.identityKey, !key.isEmpty {
                identityKeySection(key)
            }
            if !card.wallets.isEmpty {
                walletsSection
            }
            if !card.orderedFieldEntries.isEmpty {
                profileFieldsSection
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Header (avatar + name + email)

    private var header: some View {
        VStack(spacing: 8) {
            avatar
            Text(card.displayName)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            if let email = card.email, !email.isEmpty {
                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let data = card.photoData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(Circle())
        } else if let base64 = card.photoBase64,
                  let data = Data(base64Encoded: base64),
                  let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(Circle())
        } else if let urlString = card.avatarUrl,
                  let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                initialsPlaceholder
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())
        } else {
            initialsPlaceholder
        }
    }

    private var initialsPlaceholder: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.15))
            .frame(width: avatarSize, height: avatarSize)
            .overlay(
                Text(String(card.displayName.prefix(1)).uppercased())
                    .font(.system(size: avatarSize * 0.4, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            )
    }

    // MARK: - Bio / Location

    private func bioSection(_ bio: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bio")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(bio)
                .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private func locationRow(_ location: String) -> some View {
        HStack {
            Image(systemName: "location")
                .foregroundStyle(.secondary)
            Text(location)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
    }

    // MARK: - Identity Key

    private func identityKeySection(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Identity Key")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(key)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    // MARK: - Wallets

    private var walletsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wallet Addresses")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(card.wallets) { wallet in
                walletRow(wallet)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private func walletRow(_ wallet: WalletPreview) -> some View {
        HStack {
            Text(wallet.network.capitalized)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15))
                .foregroundStyle(Color.orange)
                .cornerRadius(4)
            Text(wallet.truncatedAddress)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Profile Fields

    private var profileFieldsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profile")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(card.orderedFieldEntries, id: \.namespace) { entry in
                profileFieldRow(entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private func profileFieldRow(_ entry: (namespace: String, displayName: String, value: String)) -> some View {
        HStack {
            Text(entry.displayName)
                .font(.subheadline)
            Spacer()
            Text(entry.value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
