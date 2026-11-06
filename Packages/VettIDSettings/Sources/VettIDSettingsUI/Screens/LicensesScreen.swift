#if os(iOS)
import SwiftUI
import VettIDSettings
import VettIDUI

/// Help > Licenses: the app's own license first (AGPL-3.0), then each third-party component the app bundles (packages,
/// vendored code and fonts), each with its license text from `Licences.json` (`scripts/licences.sh`). A row opens the text.
/// (chosen; not in the spec: vettid-android has no such screen.)
struct LicensesScreen: View {
    @Environment(\.vettIDColors) private var colors
    let entries: [LicenceEntry]
    let onBack: @MainActor () -> Void
    @State private var selected: LicenceEntry?

    init(entries: [LicenceEntry] = Licences.all(), onBack: @escaping @MainActor () -> Void) {
        self.entries = entries
        self.onBack = onBack
    }

    var body: some View {
        if let entry = selected {
            LicenseTextScreen(entry: entry) { selected = nil }
        } else {
            DetailScaffold(background: colors.groupedBackground, onBack: onBack) {
                ScrollView {
                    VStack(spacing: 0) {
                        LargeTitle(HelpStrings.licenses)
                        Text(HelpStrings.licensesIntro)
                            .vettIDFont(.bodyMedium)
                            .foregroundStyle(colors.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Spacing.gutter + Spacing.xs)
                            .padding(.bottom, Spacing.l)
                        SettingsGroup {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                                if i > 0 { SettingsDivider() }
                                SettingsRow(Self.title(entry), supporting: entry.licence) { selected = entry }
                                    .accessibilityIdentifier("license_\(entry.id)")
                            }
                        }
                        Spacer().frame(height: Spacing.xxl)
                    }
                }
            }
        }
    }

    /// "swift-crypto 5.0.1"; the name alone when the entry has no version.
    static func title(_ entry: LicenceEntry) -> String {
        entry.version.isEmpty ? entry.name : "\(entry.name) \(entry.version)"
    }
}

/// One component's license text.
private struct LicenseTextScreen: View {
    @Environment(\.vettIDColors) private var colors
    let entry: LicenceEntry
    let onBack: @MainActor () -> Void

    var body: some View {
        DetailScaffold(background: colors.groupedBackground, onBack: onBack) {
            ScrollView {
                // Paragraph by paragraph, built lazily: the AGPL is 34,000 characters, and VoiceOver moves a paragraph at a time.
                LazyVStack(spacing: Spacing.m) {
                    LargeTitle(LicensesScreen.title(entry))
                    Text(entry.url)
                        .vettIDFont(.bodySmall)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.gutter + Spacing.xs)
                    ForEach(Array(entry.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .vettIDFont(.bodySmall)
                            .foregroundStyle(colors.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Spacing.gutter + Spacing.xs)
                    }
                    Spacer().frame(height: Spacing.xxl)
                }
            }
        }
    }
}
#endif
