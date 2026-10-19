import SwiftUI

/// A small secondary line under what it qualifies, or nothing when [text] is nil: the staging time scale's "Staging: 1
/// day = 1 hour" where a scaled wait is shown (STAGING-TIME-SCALE §5.2).
public struct SmallNote: View {
    @Environment(\.vettIDColors) private var colors
    let text: String?
    let identifier: String

    public init(_ text: String?, identifier: String = "staging_time_scale") {
        self.text = text
        self.identifier = identifier
    }

    public var body: some View {
        if let text {
            Text(text)
                .vettIDFont(.bodySmall)
                .foregroundStyle(colors.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(identifier)
        }
    }
}
