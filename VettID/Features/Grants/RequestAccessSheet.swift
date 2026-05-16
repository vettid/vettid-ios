import SwiftUI

// MARK: - Request Access Sheet

/// Outbound-side companion to the inbound approval screens
/// (Phase 3.5, parity with Android `RequestAccessSheet`).
///
/// Presented from `BusinessCardView`'s peer-catalog rows (Phase 2.10):
/// the user taps an item the peer has published as PROFILE / CATALOG /
/// USE_ONLY and this sheet collects the request shape — `mode`,
/// `expiresAt`, `maxUses`, and an optional `reason` — before firing
/// `grant.request` via the repository.
///
/// USE_ONLY items swap "Request" semantics for "Ask to use": the
/// vault treats the request as a `critical-secret-use.request-use`
/// rather than a `grant.request`, so this sheet quietly dispatches to
/// the right verb based on the entry's visibility tier.
struct RequestAccessSheet: View {

    let peer: RequestAccessSheet.Peer
    let entry: PeerCatalogEntry

    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = RequestAccessViewModel()
    @Environment(\.dismiss) private var dismiss

    // Form state
    @State private var mode: GrantMode = .oneShot
    @State private var expiresIn: ExpiryPreset = .week
    @State private var maxUses: Int = 1
    @State private var reason: String = ""

    /// Compact peer identification — the sheet doesn't need the whole
    /// `Connection`; just enough to label the destination.
    struct Peer: Hashable {
        let connectionId: String
        let label: String
    }

    var body: some View {
        Form {
            Section {
                header
            }

            Section("Item") {
                detailRow("Kind", kindDisplay)
                detailRow("Item", entry.label)
                if let alias = entry.alias, !alias.isEmpty {
                    detailRow("Alias", alias)
                }
            }

            // USE_ONLY surfaces don't get expiry/max-uses controls —
            // critical-secret-use requests are one-shot operations, not
            // long-lived value grants.
            if !isUseOnly {
                Section("Access") {
                    Picker("Mode", selection: $mode) {
                        ForEach(GrantMode.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    }

                    Picker("Expires in", selection: $expiresIn) {
                        ForEach(ExpiryPreset.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }

                    if mode != .oneShot {
                        Stepper("Max uses: \(maxUses)", value: $maxUses, in: 1...100)
                    }

                    Text(mode.explainer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(isUseOnly ? "Why you need this" : "Reason (optional)") {
                TextField(
                    isUseOnly ? "What's the operation for?" : "Optional note to \(peer.label.isEmpty ? "the connection" : peer.label)",
                    text: $reason,
                    axis: .vertical
                )
                .lineLimit(3...6)
            }

            if let error = viewModel.errorMessage {
                Section {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(isUseOnly ? "Ask to use" : "Request access")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(viewModel.isProcessing)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(isUseOnly ? "Ask" : "Send") {
                    Task {
                        let ok = await submit()
                        if ok { dismiss() }
                    }
                }
                .disabled(viewModel.isProcessing || (isUseOnly && reason.isEmpty))
            }
        }
        .onAppear {
            viewModel.client = appState.grantsClient
        }
    }

    // MARK: - Header + helpers

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: entry.icon ?? "lock.shield")
                        .foregroundStyle(Color.accentColor)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.label.isEmpty ? "Connection" : peer.label)
                    .font(.headline)
                Text(isUseOnly
                     ? "Ask to use this for an operation"
                     : "Ask to access this item")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var isUseOnly: Bool {
        entry.visibility.uppercased() == "USE_ONLY"
    }

    private var kindDisplay: String {
        switch entry.visibility.uppercased() {
        case "PROFILE":  return "Public data"
        case "CATALOG":  return "Cataloged"
        case "USE_ONLY": return "Operation-only"
        default:          return entry.visibility
        }
    }

    // MARK: - Submit

    private func submit() async -> Bool {
        // The repository handles the routing — grant.request for value
        // grants, critical-secret-use.request-use for USE_ONLY.
        let kind: GrantItemKind = isUseOnly
            ? .criticalSecretUse
            : (entry.category?.lowercased() == "secret" ? .minorSecret : .data)

        return await viewModel.submit(
            connectionId: peer.connectionId,
            kind: kind,
            itemRef: entry.id,
            itemLabel: entry.label,
            mode: isUseOnly ? .oneShot : mode,
            expiresAt: expiresIn.date(),
            maxUses: isUseOnly ? 1 : (mode == .oneShot ? 1 : maxUses),
            reason: reason
        )
    }
}

// MARK: - Expiry presets

private enum ExpiryPreset: String, CaseIterable, Identifiable {
    case oneHour, oneDay, week, month, threeMonths, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneHour:     return "1 hour"
        case .oneDay:      return "1 day"
        case .week:        return "1 week"
        case .month:       return "1 month"
        case .threeMonths: return "3 months"
        case .never:       return "Never"
        }
    }

    func date() -> Date? {
        switch self {
        case .oneHour:     return Date().addingTimeInterval(3600)
        case .oneDay:      return Date().addingTimeInterval(86_400)
        case .week:        return Date().addingTimeInterval(7  * 86_400)
        case .month:       return Date().addingTimeInterval(30 * 86_400)
        case .threeMonths: return Date().addingTimeInterval(90 * 86_400)
        case .never:       return nil
        }
    }
}

// MARK: - View Model

@MainActor
final class RequestAccessViewModel: ObservableObject {

    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?

    var client: GrantsClient?

    private let repository: GrantsRepository

    init(repository: GrantsRepository = .shared) {
        self.repository = repository
    }

    /// Submit a request. Routes to `grant.request` or
    /// `critical-secret-use.request-use` depending on `kind`. Returns
    /// true on success so the caller can dismiss.
    func submit(
        connectionId: String,
        kind: GrantItemKind,
        itemRef: String,
        itemLabel: String,
        mode: GrantMode,
        expiresAt: Date?,
        maxUses: Int,
        reason: String
    ) async -> Bool {
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }

        do {
            switch kind {
            case .criticalSecretUse:
                // Operation request: the receiver-side verb. The
                // `payloadBase64` would carry actual bytes-to-operate-
                // on in a real flow; this sheet doesn't have any, so
                // we pass an empty payload and let the responder's
                // CriticalUseApprovalView reflect the context.
                guard let client = client else {
                    errorMessage = "Grants client not configured"
                    return false
                }
                _ = try await client.requestCriticalUse(
                    connectionId: connectionId,
                    itemRef: itemRef,
                    itemLabel: itemLabel,
                    operation: "USE",
                    payloadBase64: "",
                    context: reason
                )
            default:
                _ = try await repository.sendRequest(
                    connectionId: connectionId,
                    kind: kind,
                    itemRef: itemRef,
                    itemLabel: itemLabel,
                    mode: mode,
                    deliverTo: "value",
                    requestedExpiresAt: expiresAt,
                    requestedMaxUses: maxUses,
                    reason: reason
                )
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
