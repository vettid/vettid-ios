import Foundation

// The texts of the network failures (relay refusals, no connection, a wrong clock seen by the relay): drafts for the owner's
// wording, not in vettid-android's strings (chosen; not in the spec).
extension DataStrings {
    static var failureOffline: String {
        String(
            localized: "data_failure_offline",
            defaultValue: """
                There is no connection to the internet. Connect, then try again.
                """,
            bundle: .module
        )
    }
    static var failureRelayQuota: String {
        String(
            localized: "data_failure_relay_quota",
            defaultValue: """
                VettID's message relay is full for now. This wasn't sent. Try again later.
                """,
            bundle: .module
        )
    }
    static var failurePayloadTooLarge: String {
        String(
            localized: "data_failure_payload_too_large",
            defaultValue: """
                This is too large to send. Make it smaller and try again.
                """,
            bundle: .module
        )
    }
    static var failureRelayRefused: String {
        String(
            localized: "data_failure_relay_refused",
            defaultValue: """
                VettID's message relay refused this. Try again; if it keeps happening, contact VettID.
                """,
            bundle: .module
        )
    }
    static var failureClockOff: String {
        String(
            localized: "data_failure_clock_off",
            defaultValue: """
                This phone's date and time look wrong, so VettID's relay or your vault will not accept its messages. \
                Turn on automatic date and time in the phone's settings, then try again.
                """,
            bundle: .module
        )
    }
}
