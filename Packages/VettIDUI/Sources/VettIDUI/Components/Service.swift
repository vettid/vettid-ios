import SwiftUI

/// The texts of a service connection (VAULT-MESSAGING §6.4 "Service connections"; IOS-PLAN §4.13, ANDROID-PLAN §4
/// "Service connections (0.1.90)"), shared by every screen that shows one: the keys and English values are Android's.
/// A connection is a service only when the vault says `peer_kind: "service"`; nothing here is inferred from a name.
public enum ServiceTexts {
    /// The small label beside a service's name.
    public static var label: String { String(localized: "service_label", defaultValue: "Service", bundle: .module) }

    /// The Connections section of the services, below the people.
    public static var sectionTitle: String {
        String(localized: "services_section_title", defaultValue: "Services", bundle: .module)
    }

    /// The connection request of a service, under its name and above the code.
    public static var requestLine: String {
        String(localized: "service_request_line", defaultValue: "This is a service, not a person.", bundle: .module)
    }

    /// The request line's small print.
    public static var requestCaveat: String {
        String(
            localized: "service_request_caveat", defaultValue: "The invitation says so. VettID has not checked who runs it.",
            bundle: .module
        )
    }

    /// A service's name, labelled so (never "the name on their VettID account").
    public static var nameLabel: String {
        String(localized: "service_name_label", defaultValue: "Name given by the service", bundle: .module)
    }

    /// The label of the fingerprint of a service's `ik` on its connection request: the approved words of the connection
    /// page's "Vault key fingerprint" (ANDROID-PLAN 0.1.118), under Android's key.
    public static var fingerprintLabel: String {
        String(localized: "core_ui_vault_key_fingerprint", defaultValue: "Vault key fingerprint", bundle: .module)
    }

    /// The card of a service's page that says what it can ask.
    public static var canAskTitle: String {
        String(localized: "service_detail_can_ask_title", defaultValue: "What this service can ask", bundle: .module)
    }

    /// The vault's rule for this release (VAULT-MESSAGING §6.4).
    public static var canAskBody: String {
        String(
            localized: "service_detail_can_ask_body",
            defaultValue: """
                It can ask you to confirm a sign-in or approve an action. It can't message or call you, and it can't ask \
                for your data.
                """,
            bundle: .module
        )
    }

    /// [canAskBody] where the vault has the vote feature (ANDROID-PLAN §4 "Votes", 0.1.102).
    public static var canAskBodyVotes: String {
        String(
            localized: "service_detail_can_ask_body_votes",
            defaultValue: """
                It can ask you to confirm a sign-in, approve an action or vote. It can't message or call you, and it \
                can't ask for your data.
                """,
            bundle: .module
        )
    }

    /// The vault answered `forbidden` to something sent to a service: said once, and the action goes.
    public static var forbidden: String {
        String(localized: "service_forbidden", defaultValue: "Services can't do that.", bundle: .module)
    }
}

/// The small "Service" label beside a service's name (IOS-PLAN §4.13: in a row's trailing view). It never truncates; the
/// element that holds the name combines the two for VoiceOver ("Example Bank, Service").
public struct ServiceLabel: View {
    @Environment(\.vettIDColors) private var colors

    public init() {}

    public var body: some View {
        Text(ServiceTexts.label)
            .vettIDFont(.labelSmall)
            .foregroundStyle(colors.onSurfaceVariant)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(colors.outline, lineWidth: 1))
            .accessibilityIdentifier("service_label")
    }
}

/// A page's name (a connection's title, an approval's "From") and, for a service, its ``ServiceLabel``: one element for
/// VoiceOver. On one line when both fit at their full width; otherwise the label goes under the name, so neither is cut.
/// List rows use ``ServiceRowLine`` instead, which keeps rows one line high.
public struct ServiceNamed<Name: View>: View {
    let service: Bool
    let alignment: HorizontalAlignment
    let name: Name

    /// [alignment]: of the name and the label when they stack (a centred page title, a leading row).
    public init(service: Bool, alignment: HorizontalAlignment = .leading, @ViewBuilder name: () -> Name) {
        self.service = service
        self.alignment = alignment
        self.name = name()
    }

    public var body: some View {
        if service {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) { name; ServiceLabel() }
                VStack(alignment: alignment, spacing: Spacing.xs) { name; ServiceLabel() }
            }
            .accessibilityElement(children: .combine)
        } else {
            name
        }
    }
}

/// A list row's line that names a service, with its ``ServiceLabel`` at the trailing end (IOS-PLAN §4.13: in the row's
/// trailing view): one line, the text truncating before the label, which is never cut. One element for VoiceOver
/// ("Example Bank, Service"). Without [service], the line alone.
public struct ServiceRowLine<Line: View>: View {
    let service: Bool
    let line: Line

    public init(service: Bool, @ViewBuilder line: () -> Line) {
        self.service = service
        self.line = line()
    }

    public var body: some View {
        if service {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                line.layoutPriority(0)
                ServiceLabel().layoutPriority(1)
            }
            .accessibilityElement(children: .combine)
        } else {
            line
        }
    }
}

/// A service's connection request, under its name and above the code (VAULT-MESSAGING §6.4): "This is a service, not a
/// person." with its small print. Shown only when the request carries `peer_kind: "service"`.
public struct ServiceRequestLines: View {
    @Environment(\.vettIDColors) private var colors

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(ServiceTexts.requestLine).vettIDFont(.bodyLarge, weight: .semibold)
            Text(ServiceTexts.requestCaveat).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("service_request")
    }
}

/// The fingerprint of a service's `ik` on its connection request, under the service lines and above the code (VAULT-MESSAGING
/// §6.4 "What the member sees before approving", §10.8): the label "Vault key fingerprint" and the fingerprint as the
/// connection's page shows it. The member can compare it with one the service publishes where they trust it; the safety
/// code does not say who holds the key. Shown only with an `ik`.
public struct ServiceFingerprintLine: View {
    @Environment(\.vettIDColors) private var colors
    let fingerprint: String
    let labelColor: ThemeColor?

    /// [labelColor]: the label's colour where the screen's labels have one (nil: the text colour).
    public init(fingerprint: String, labelColor: ThemeColor? = nil) {
        self.fingerprint = fingerprint
        self.labelColor = labelColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(ServiceTexts.fingerprintLabel).vettIDFont(.labelLarge).foregroundStyle(labelColor ?? colors.onSurface)
            Text(fingerprint).font(.system(.body, design: .monospaced)).accessibilityIdentifier("request_fingerprint")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
