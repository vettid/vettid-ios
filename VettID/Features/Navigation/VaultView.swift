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

    var icon: String {
        switch self {
        case .data:    return "folder.fill"
        case .secrets: return "lock.fill"
        case .wallets: return "bitcoinsign.circle.fill"
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

    private var segmentPicker: some View {
        Picker("Vault section", selection: $segment) {
            ForEach(VaultSegment.allCases) { seg in
                Text(seg.title).tag(seg)
            }
        }
        .pickerStyle(.segmented)
    }
}
