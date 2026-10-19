#if os(iOS)
import SwiftUI
import VettIDUI

/// One of Help's rows that opens a page of the website.
struct HelpLink: Equatable {
    let label: String
    let url: String
    let icon: VettIDSymbol
    let identifier: String
}

/// Help (ANDROID-PLAN §4 "Drawer", the last destination): links to the website's explanations and contact page, opened
/// in the member's browser as vettid-android's `LocalUriHandler` does. "Learn" holds About and Security, then the iPhone's
/// own texts of IOS-PLAN §14 (Privacy, ID18; Keyboards, ID11) as read-only rows (where they go in Help is chosen; not in
/// the spec); "Support" holds Contact. Mirrors vettid-android `HelpScreen`.
public struct HelpScreen: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.openURL) private var openURL
    let onBack: @MainActor () -> Void

    public init(onBack: @escaping @MainActor () -> Void) {
        self.onBack = onBack
    }

    static var learn: [HelpLink] {
        [
            HelpLink(label: HelpStrings.about, url: HelpStrings.urlAbout, icon: .info, identifier: "help_about"),
            HelpLink(label: HelpStrings.security, url: HelpStrings.urlSecurity, icon: .security, identifier: "help_security"),
        ]
    }

    static var support: [HelpLink] {
        [HelpLink(label: HelpStrings.contact, url: HelpStrings.urlContact, icon: .email, identifier: "help_contact")]
    }

    public var body: some View {
        DetailScaffold(background: colors.groupedBackground, onBack: onBack) {
            ScrollView {
                VStack(spacing: 0) {
                    LargeTitle(HelpStrings.title)
                    SettingsSectionHeader(HelpStrings.sectionLearn)
                    SettingsGroup {
                        links(Self.learn)
                        SettingsDivider()
                        SettingsInfoRow(HelpStrings.privacy, value: HelpStrings.privacyBody, icon: .privacyTip)
                            .accessibilityIdentifier("help_privacy")
                        SettingsDivider()
                        SettingsInfoRow(HelpStrings.keyboards, value: HelpStrings.keyboardsBody, icon: .keyboard)
                            .accessibilityIdentifier("help_keyboards")
                    }
                    SettingsSectionHeader(HelpStrings.sectionSupport)
                    SettingsGroup { links(Self.support) }
                    Spacer().frame(height: Spacing.xxl)
                }
            }
        }
    }

    @ViewBuilder private func links(_ items: [HelpLink]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { i, link in
            if i > 0 { SettingsDivider() }
            SettingsRow(link.label, icon: link.icon, showChevron: false) {
                if let url = URL(string: link.url) { openURL(url) }
            }
            .accessibilityIdentifier(link.identifier)
        }
    }
}
#endif
