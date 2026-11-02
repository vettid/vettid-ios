import Foundation

/// The connect flow's texts for a service connection (VAULT-MESSAGING §6.4 "Service connections"): vettid-android #237's
/// keys and approved English values. The texts every screen shares are ``ServiceTexts`` of VettIDUI.
extension ConnectStrings {
    /// "You are connected" to a service: it cannot message the member, so the sentence says what it can do instead.
    static func connectedBodyService(_ name: String) -> String {
        String(
            localized: "connections_connected_body_service",
            defaultValue: "You're connected to \(name). It can ask you to sign in, vote and update your profile.",
            bundle: .module
        )
    }

    static var connectedBodyServiceUnnamed: String {
        String(
            localized: "connections_connected_body_service_unnamed",
            defaultValue: "You're connected. The service can ask you to sign in, vote and update your profile.",
            bundle: .module
        )
    }
}
