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

    /// Connection id to attach catalog-row "Request access" sheets to.
    /// Only relevant on peer cards; nil for own-card surfaces. When nil,
    /// catalog rows render but don't surface the request affordance.
    var connectionId: String? = nil

    /// Phase 3.5: tracks the peer-catalog entry the user tapped — drives
    /// the `RequestAccessSheet` presentation. Owned here so every peer
    /// surface that embeds a BusinessCardView gets the request flow for
    /// free.
    @State private var requestingEntry: PeerCatalogEntry? = nil

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
            // Phase 2.10: peer-published catalog sections. Only render
            // for peer cards — the user's own card has dedicated
            // "Available Personal Data" / "Available Secrets" sheets
            // (Phase 2.7) and doesn't need the inline summary.
            if !card.isOwnProfile {
                if !card.dataCatalog.isEmpty {
                    catalogSection(title: "Available data", entries: card.dataCatalog)
                }
                if !card.secretsCatalog.isEmpty {
                    catalogSection(title: "Available secrets", entries: card.secretsCatalog)
                }
            }
        }
        .frame(maxWidth: .infinity)
        // Phase 3.5: present the RequestAccessSheet when a catalog row
        // is tapped. Only fires when a peer connectionId is configured;
        // own-card embeds (which suppress the catalog anyway) don't.
        .sheet(item: $requestingEntry) { entry in
            if let connectionId = connectionId {
                NavigationView {
                    RequestAccessSheet(
                        peer: .init(connectionId: connectionId, label: card.displayName),
                        entry: entry
                    )
                }
            }
        }
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

    // MARK: - Peer catalog sections (Phase 2.10)

    private func catalogSection(title: String, entries: [PeerCatalogEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(entries) { entry in
                catalogRow(entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private func catalogRow(_ entry: PeerCatalogEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.icon ?? glyphForVisibility(entry.visibility))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                if let alias = entry.alias, !alias.isEmpty {
                    Text("\(entry.label) — \(alias)").font(.subheadline)
                } else {
                    Text(entry.label).font(.subheadline)
                }
                Text(visibilityLabel(entry.visibility))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if connectionId != nil {
                // Phase 3.5: tap the row to open the RequestAccessSheet
                // (or Ask-to-Use for USE_ONLY entries). The chevron is
                // a visual affordance; the whole row is tappable.
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if connectionId != nil { requestingEntry = entry }
        }
    }

    private func glyphForVisibility(_ wire: String) -> String {
        switch wire.uppercased() {
        case "PROFILE":  return "eye.fill"
        case "CATALOG":  return "doc.text"
        case "USE_ONLY": return "wand.and.stars"
        default:          return "circle"
        }
    }

    private func visibilityLabel(_ wire: String) -> String {
        switch wire.uppercased() {
        case "PROFILE":  return "Shown publicly"
        case "CATALOG":  return "Available to request"
        case "USE_ONLY": return "Available for operations"
        default:          return wire.capitalized
        }
    }
}
