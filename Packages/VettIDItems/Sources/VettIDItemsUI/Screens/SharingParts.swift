#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// The vault failure a sharing screen shows, with "OK" to put it away. Mirrors vettid-android `SharingErrorNotice`.
struct SharingErrorNotice: View {
    let error: FailureKind?
    let limit: VaultLimit?
    let code: String?
    let onDismiss: @MainActor () -> Void

    var body: some View {
        if let error {
            let message = ItemsText.failure(error, limit: limit, shownCode: code)
            NoticeCard(.warning, title: error.title(or: ItemsStrings.errorItem), message: message) {
                Button(ItemsStrings.ok) { onDismiss() }
            }
            .padding(.horizontal, Spacing.s)
            .accessibilityIdentifier("sharing_error")
        }
    }
}

/// "This connection has the most share rules it can have (64)": the named limit (§10.12 `share_rules_subject`). Mirrors
/// vettid-android `RuleLimitNotice`.
struct RuleLimitNotice: View {
    static let limitName = "share_rules_subject"

    var body: some View {
        NoticeCard(
            .info, title: ItemsStrings.ruleLimitTitle,
            message: VaultLimit(Self.limitName, max: Int64(RuleDraft.maxRulesPerSubject)).message
        )
        .accessibilityIdentifier("rule_limit")
    }
}

extension RuleExpiry {
    /// The id suffix of an end's chip (`rule_end_three_months`), as vettid-android's test tags.
    var identifier: String {
        switch self {
        case .never: "never"
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .threeMonths: "three_months"
        case .year: "year"
        case .custom: "custom"
        case .keep: "keep"
        }
    }
}
#endif
