import Foundation

// MARK: - Peer Catalog Entry

/// One row in a peer's published data or secret catalog. The value is
/// never carried — the catalog advertises *what exists*; values flow via
/// the Grants subsystem (Phase 3) when the owner approves a request.
/// Mirrors Android's `PeerDataCatalogEntry` / `PeerPublicSecretMetadata`.
struct PeerCatalogEntry: Identifiable, Equatable {
    /// Namespace (data) or vault id (secret).
    let id: String
    /// Display label — e.g. "Mobile Phone", "Trading Wallet — BTC".
    let label: String
    /// Optional alias (secrets) for grouped display.
    let alias: String?
    /// Optional category tag for grouping / glyph selection.
    let category: String?
    /// SF Symbol or category icon name.
    let icon: String?
    /// Discoverability tier — drives the row's affordance.
    /// "PROFILE" → "Shown publicly", "CATALOG" → "Available to request",
    /// "USE_ONLY" → "Available for operations only" (critical secrets).
    let visibility: String
}

// MARK: - Business Card Data

/// Unified peer-profile view-model for `BusinessCardView`.
///
/// Surfaces that need to render someone's "business card" — Connection
/// Review, Connection Detail, the own-profile preview — converted to
/// this shape and let `BusinessCardView` do the rendering. Mirrors
/// Android's single `BusinessCardView` surface.
///
/// One struct, two adapters (from `PeerProfilePreview` for peer cases,
/// from `Profile` for the user's own card).
struct BusinessCardData: Equatable {

    let displayName: String
    let email: String?
    /// Base64-encoded JPEG for peers (vault-published) or `Data` for the
    /// local user's profile photo. We carry all three so the view can
    /// render whichever source is available without an extra encode/
    /// decode hop. Preference order at render time: photoData →
    /// photoBase64 → avatarUrl → initials.
    let photoBase64: String?
    let photoData: Data?
    let avatarUrl: String?

    let bio: String?
    let location: String?

    /// The peer's Ed25519 identity public key (peer cards only); nil for
    /// the user's own card.
    let identityKey: String?

    /// Published wallet addresses ordered as the vault returned them.
    let wallets: [WalletPreview]

    /// Custom profile fields, keyed by namespace. Each entry is a
    /// `{ display_name, value }` dict matching the vault wire shape.
    let profileFields: [String: [String: String]]?

    /// Vault-supplied stable display order for `profileFields`. Empty
    /// means "fall back to sorted key order".
    let fieldOrder: [String]

    /// Phase 2.10: peer-published data catalog rows — what the peer
    /// has made available for request. Each entry is the namespace +
    /// display name; values are NOT carried (held in trust until the
    /// owner approves a Grants request).
    let dataCatalog: [PeerCatalogEntry]

    /// Phase 2.10: peer-published secret catalog rows — same shape as
    /// `dataCatalog` but for `MinorSecret`s the peer has marked
    /// PROFILE / CATALOG / USE_ONLY.
    let secretsCatalog: [PeerCatalogEntry]

    /// True when the card represents the local user's own profile —
    /// renderers use this to drop peer-only affordances (e.g. the
    /// identity-key block doesn't show on the own card).
    let isOwnProfile: Bool

    // MARK: - Adapters

    /// Build from a peer-profile preview (the shape Connection Review
    /// and the connection list both work with).
    init(from preview: PeerProfilePreview, isOwnProfile: Bool = false) {
        self.displayName = preview.displayName
        self.email = preview.email
        self.photoBase64 = preview.photoBase64
        self.photoData = nil
        self.avatarUrl = nil
        self.bio = nil
        self.location = nil
        self.identityKey = preview.publicKey
        self.wallets = preview.wallets
        self.profileFields = preview.profileFields
        self.fieldOrder = []
        self.dataCatalog = []
        self.secretsCatalog = []
        self.isOwnProfile = isOwnProfile
    }

    /// Build from the user's locally stored `Profile`. Used for the own-
    /// profile preview surface (no identity key — that lives in the
    /// credential, not the profile).
    init(from profile: Profile, isOwnProfile: Bool = true) {
        self.displayName = profile.displayName
        self.email = profile.email
        self.photoBase64 = nil
        self.photoData = profile.photoData
        self.avatarUrl = profile.avatarUrl
        self.bio = profile.bio
        self.location = profile.location
        self.identityKey = nil
        self.wallets = []
        self.profileFields = nil
        self.fieldOrder = []
        self.dataCatalog = []
        self.secretsCatalog = []
        self.isOwnProfile = isOwnProfile
    }

    /// Memberwise init for tests / previews.
    init(
        displayName: String,
        email: String? = nil,
        photoBase64: String? = nil,
        photoData: Data? = nil,
        avatarUrl: String? = nil,
        bio: String? = nil,
        location: String? = nil,
        identityKey: String? = nil,
        wallets: [WalletPreview] = [],
        profileFields: [String: [String: String]]? = nil,
        fieldOrder: [String] = [],
        dataCatalog: [PeerCatalogEntry] = [],
        secretsCatalog: [PeerCatalogEntry] = [],
        isOwnProfile: Bool = false
    ) {
        self.displayName = displayName
        self.email = email
        self.photoBase64 = photoBase64
        self.photoData = photoData
        self.avatarUrl = avatarUrl
        self.bio = bio
        self.location = location
        self.identityKey = identityKey
        self.wallets = wallets
        self.profileFields = profileFields
        self.fieldOrder = fieldOrder
        self.dataCatalog = dataCatalog
        self.secretsCatalog = secretsCatalog
        self.isOwnProfile = isOwnProfile
    }

    /// Iterate `profileFields` in the vault-supplied order if available,
    /// otherwise alphabetically. Skips fields with empty values so empty
    /// rows don't render.
    var orderedFieldEntries: [(namespace: String, displayName: String, value: String)] {
        let fields = profileFields ?? [:]
        let keys: [String]
        if !fieldOrder.isEmpty {
            keys = fieldOrder.filter { fields[$0] != nil }
        } else {
            keys = fields.keys.sorted()
        }
        return keys.compactMap { ns in
            guard let entry = fields[ns] else { return nil }
            let value = entry["value"] ?? ""
            guard !value.isEmpty else { return nil }
            return (ns, entry["display_name"] ?? ns, value)
        }
    }
}
