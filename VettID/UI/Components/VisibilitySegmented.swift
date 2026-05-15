import SwiftUI

// MARK: - Visibility Segmented

/// Four-tier visibility picker used on every "who can see this?" surface
/// in the app (Phase 2.4). Matches Android's `VisibilitySegmented`.
///
/// Tiers, in increasing privacy:
///   - PROFILE  — peers see the value (lands in the published profile).
///   - CATALOG  — peers see that the secret/field *exists*, can request
///                it via Grants, but the value is held in trust.
///   - USE_ONLY — peers can request an operation (sign / decrypt / auth)
///                that uses the secret, but the value is never disclosed.
///                Maps to vault `cataloged-for-use`. Critical secrets
///                only.
///   - PRIVATE  — neither value nor existence is exposed.
///
/// Pass `allowedTiers` to restrict the picker (e.g. minor secrets get
/// PROFILE / CATALOG / PRIVATE; critical secrets get CATALOG / USE_ONLY
/// / PRIVATE — they're never published as a value). Defaults to all
/// four.
struct VisibilitySegmented: View {
    @Binding var selection: SecretVisibility
    var allowedTiers: [SecretVisibility] = SecretVisibility.allCases

    var body: some View {
        Picker("Visibility", selection: $selection) {
            ForEach(allowedTiers, id: \.self) { tier in
                Text(tier.shortLabel).tag(tier)
            }
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - Labels / descriptions

extension SecretVisibility: CaseIterable, Identifiable {
    public static var allCases: [SecretVisibility] {
        [.profile, .catalog, .useOnly, .private]
    }
    public var id: String { wireValue }

    /// Short label for the segmented picker — 1-2 words, sentence case.
    var shortLabel: String {
        switch self {
        case .profile:   return "Public"
        case .catalog:   return "Catalog"
        case .useOnly:   return "Use only"
        case .`private`: return "Private"
        }
    }

    /// One-line description under the picker explaining what the
    /// selected tier means. Surfaces on AddSecretView / SecretsView's
    /// detail editor.
    var explainer: String {
        switch self {
        case .profile:
            return "Visible in your published profile. Connections see the value."
        case .catalog:
            return "Connections see that this exists and can request it. You approve each share."
        case .useOnly:
            return "Connections can ask to use this in an operation, but never receive the value."
        case .`private`:
            return "Hidden. Connections don't know this exists."
        }
    }

    /// Glyph for the chip / list row that summarizes the current tier.
    var icon: String {
        switch self {
        case .profile:   return "eye.fill"
        case .catalog:   return "doc.text"
        case .useOnly:   return "wand.and.stars"
        case .`private`: return "lock.fill"
        }
    }
}
