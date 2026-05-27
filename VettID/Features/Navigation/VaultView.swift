import SwiftUI

// MARK: - Vault Segment

/// Sub-section of the Vault destination. Matches Android's
/// "Data / Secrets / Wallets" segmented control inside the VAULT
/// scaffold.
enum VaultSegment: String, CaseIterable, Identifiable {
    case data
    case secrets
    case wallets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .data:    return "Data"
        case .secrets: return "Secrets"
        case .wallets: return "Wallets"
        }
    }

    /// SF Symbol equivalents of the icons Android uses in
    /// `NavigationModels.VaultSegment`:
    ///   - DATA    → `Icons.Default.Person`           → `person.fill`
    ///   - SECRETS → `Icons.Default.Lock`             → `lock.fill`
    ///   - WALLETS → `Icons.Default.AccountBalance`   → `building.columns.fill`
    var icon: String {
        switch self {
        case .data:    return "person.fill"
        case .secrets: return "lock.fill"
        case .wallets: return "building.columns.fill"
        }
    }
}

// MARK: - Vault View

/// The VAULT destination — one of the two top-level destinations in the
/// collapsed nav (Phase 1.3). Hosts a segmented picker for
/// Data / Secrets / Wallets and renders the corresponding sub-view.
///
/// Parity with Android `MainScaffold` VAULT pane. The other top-level
/// destination, ACTIVITY, is the connection-centric `FeedView`.
struct VaultView: View {
    @Binding var segment: VaultSegment
    let searchText: String

    var body: some View {
        VStack(spacing: 0) {
            // Phase 2.10: persistent profile strip — avatar + name +
            // "Available data" affordance — stays visible across all
            // three segments. Parity with Android VaultProfileSection.
            VaultProfileSection(segment: $segment)

            segmentPicker
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Group {
                switch segment {
                case .data:
                    PersonalDataView()
                case .secrets:
                    SecretsView(searchText: searchText)
                case .wallets:
                    WalletListView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Icon-and-small-label tab strip, matching Android's
    /// `IconTabSelector` (TabRow + Tab with `Icon(...)` and
    /// `Text(fontSize=10.sp)`). Each tab takes equal width; the
    /// selected one gets a 2pt accent-colored underline.
    private var segmentPicker: some View {
        HStack(spacing: 0) {
            ForEach(VaultSegment.allCases) { seg in
                segmentTab(seg)
            }
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private func segmentTab(_ seg: VaultSegment) -> some View {
        let isSelected = segment == seg
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { segment = seg }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: seg.icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(seg.title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Rectangle()
                    .fill(isSelected ? Color.accentColor : .clear)
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(seg.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
