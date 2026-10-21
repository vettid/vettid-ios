#if os(iOS)
import SwiftUI
import VettIDData
import VettIDHistory
import VettIDUI

/// What an entry's screen can ask for.
public struct HistoryEntryActions {
    public var onBack: @MainActor () -> Void = {}
    public var onRetry: @MainActor () -> Void = {}
    /// Opens the entry's connection, while it is still in the vault.
    public var onOpenConnection: @MainActor (String) -> Void = { _ in }
    /// Opens the entry's item, while it is still in the vault; nil until the Vault screens (IOS-PLAN §8 I3.1).
    public var onOpenItem: (@MainActor (String) -> Void)?

    public init() {}
}

/// An audit entry (§10.9), read-only: what, when, the details of IOS-PLAN §4.1, the connection, item and device, the
/// kind, the reference (copied on request) and the chain fields, and the note that the log is append-only. Mirrors
/// vettid-android `HistoryEntryScreen`.
public struct HistoryEntryScreen: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.colorScheme) private var scheme
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: HistoryEntryState
    let actions: HistoryEntryActions

    public init(state: HistoryEntryState, actions: HistoryEntryActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        DetailScaffold(onBack: actions.onBack) {
            if state.loading {
                ProgressView().tint(colors.primary.color).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = state.error {
                NoticeCard(.warning, title: error.title(or: HistoryStrings.errorTitle), message: error.message(timeScale: timeScale)) {
                    Button(HistoryStrings.retry, action: actions.onRetry).accessibilityIdentifier("history_retry")
                }
                .padding(Spacing.xl)
            } else if let e = state.entry {
                detail(e)
            } else {
                NoticeCard(.info, title: HistoryStrings.title, message: HistoryStrings.detailMissing)
                    .padding(Spacing.xl)
                    .accessibilityIdentifier("history_entry_missing")
            }
        }
        .accessibilityIdentifier("history_entry")
    }

    private func detail(_ e: AuditRecord) -> some View {
        ScrollView {
            VStack(spacing: Spacing.m) {
                InitialTile(e.kind, size: 72, icon: HistoryVisuals.symbol(e.category), colors: HistoryVisuals.colors(e.category, scheme))
                    .padding(.top, Spacing.l)
                CenteredTitle(state.title).accessibilityIdentifier("history_entry_title")
                DetailCard {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        ForEach(Array(state.fields(timeScale: timeScale).enumerated()), id: \.offset) { _, f in
                            field(f)
                            buttons(after: f, e)
                        }
                    }
                }
                .padding(.horizontal, Spacing.s)
                Text(HistoryStrings.detailNote)
                    .vettIDFont(.bodySmall)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.l)
            }
            .padding(.bottom, Spacing.xxl)
        }
    }

    private func field(_ f: HistoryField) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(f.label).vettIDFont(.labelLarge).foregroundStyle(colors.onSurfaceVariant)
            Text(f.value)
                .vettIDFont(.bodyLarge)
                .fontDesign(f.mono ? .monospaced : nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(f.id ?? "history_entry_field")
    }

    /// "Open connection" under the connection while it is there, "Open the item" under the item, "Copy reference" under
    /// the reference.
    @ViewBuilder private func buttons(after f: HistoryField, _ e: AuditRecord) -> some View {
        switch f.id {
        case "history_entry_connection":
            if state.connectionExists, let id = e.entry.connectionID {
                Button(HistoryStrings.detailOpenConnection) { actions.onOpenConnection(id) }
                    .frame(minHeight: Spacing.touchTarget)
                    .accessibilityIdentifier("history_open_connection")
            }
        case "history_entry_item":
            if state.itemExists, let open = actions.onOpenItem, let id = AuditKinds.itemOf(e.kind, e.entry.ref) {
                Button(HistoryStrings.detailOpenItem) { open(id) }
                    .frame(minHeight: Spacing.touchTarget)
                    .accessibilityIdentifier("history_open_item")
            }
        case "history_entry_ref":
            if let ref = e.entry.ref {
                Button(HistoryStrings.detailCopy(HistoryStrings.detailRef.lowercased())) { SecurePasteboard.copy(ref) }
                    .frame(minHeight: Spacing.touchTarget)
                    .accessibilityIdentifier("history_copy_ref")
            }
        default:
            EmptyView()
        }
    }
}
#endif
