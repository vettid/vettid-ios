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

/// A name and, for a service, its ``ServiceLabel`` on the same line: one element for VoiceOver. Large Dynamic Type sizes
/// put the label under the name rather than truncate either.
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
