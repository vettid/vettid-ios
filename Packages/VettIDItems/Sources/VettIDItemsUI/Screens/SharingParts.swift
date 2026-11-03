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
            NoticeCard(.warning, title: error.title(or: ItemsStrings.errorItem), message: message, announce: .assertive) {
                Button(ItemsStrings.ok) { onDismiss() }
            }
            .padding(.horizontal, Spacing.s)
            .accessibilityIdentifier("sharing_error")
        }
    }
}

/// A read that failed: why, with "Try again" that reads again; in place of a list's empty-state text, or above what it
/// still shows. Spoken when it appears. Its title is the Vault list's ("Your vault could not be read").
struct LoadFailedNotice: View {
    let failure: LoadFailure
    var identifier = "load_error"
    /// The screen's view model reads again by itself once the daily check passes (it follows the owner check).
    var retriesByItself = false
    let onRetry: @MainActor () -> Void

    /// Whether "Try again" is offered: always, except for a vault on hold (VAULT-MESSAGING §3.6.3) on a screen that reads
    /// again by itself once the daily check passes.
    static func offersRetry(_ failure: LoadFailure, retriesByItself: Bool) -> Bool {
        !(retriesByItself && failure.kind == .ownerCheckRequired)
    }

    var body: some View {
        let retry = Self.offersRetry(failure, retriesByItself: retriesByItself)
        NoticeCard(
            retry ? .warning : .info, title: failure.kind.title(or: ItemsStrings.errorList),
            message: ItemsText.failure(failure.kind, shownCode: failure.code), announce: .polite
        ) {
            if retry { Button(ItemsStrings.retry) { onRetry() }.accessibilityIdentifier("\(identifier)_retry") }
        }
        .accessibilityIdentifier(identifier)
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
