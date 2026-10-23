import SwiftUI

/// Views side by side, wrapping to the next line when a line is full (Compose's `FlowRow`). Shared by the Vault's sharing
/// screens and the connection page's rule rows.
public struct ChipFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    public init(spacing: CGFloat = Spacing.s, lineSpacing: CGFloat = Spacing.xs) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

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

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ls = lines(subviews, width: proposal.width ?? .infinity)
        let h = ls.reduce(0) { $0 + $1.height } + CGFloat(max(0, ls.count - 1)) * lineSpacing
        return CGSize(width: proposal.width ?? ls.map(\.width).max() ?? 0, height: h)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
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
