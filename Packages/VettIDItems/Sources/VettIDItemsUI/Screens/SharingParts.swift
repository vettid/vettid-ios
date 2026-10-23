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

/// Views side by side, wrapping to the next line when a line is full (Compose's `FlowRow`).
struct ChipFlow: Layout {
    var spacing: CGFloat = Spacing.s
    var lineSpacing: CGFloat = Spacing.xs

    struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var out = [Line()]
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.init(width: width.isFinite ? width : nil, height: nil))
            let add = (out[out.count - 1].items.isEmpty ? 0 : spacing) + size.width
            if !out[out.count - 1].items.isEmpty, out[out.count - 1].width + add > width { out.append(Line()) }
            let gap = out[out.count - 1].items.isEmpty ? 0 : spacing
            out[out.count - 1].items.append((i, size))
            out[out.count - 1].width += gap + size.width
            out[out.count - 1].height = max(out[out.count - 1].height, size.height)
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ls = lines(subviews, width: proposal.width ?? .infinity)
        let h = ls.reduce(0) { $0 + $1.height } + CGFloat(max(0, ls.count - 1)) * lineSpacing
        return CGSize(width: proposal.width ?? ls.map(\.width).max() ?? 0, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            var x = bounds.minX
            for (i, size) in line.items {
                subviews[i].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: .init(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
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
