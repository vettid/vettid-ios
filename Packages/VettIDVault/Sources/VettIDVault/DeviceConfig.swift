import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDRelay

/// How a device is set up.
public struct DeviceConfig: Sendable {
    public static let roleApp = "app"
    /// Interactive requests time out after 30 s (§8.1); a request is re-sent with the same inner id at most twice (§8.6).
    public static let defaultTimeout: TimeInterval = 30

    public let role: String
    /// The name the vault shows for this device (`profile.name`).
    public let name: String
    /// The device's own relay base URL, as tokens name it (`aud`).
    public let relayURL: String
    public let transport: HTTPTransport
    public let store: DeviceStateStore
    /// vault.enrolled's attestation check (§11.3).
    public let enrolledAttestation: EnrolledAttestation
    public let now: @Sendable () -> Date
    public let collectMode: MailboxCollector.Mode
    public let pollWait: TimeInterval
    public let requestTimeout: TimeInterval
    /// TEST ONLY. The request timeout for a request of the given type instead of [requestTimeout] (nil: none): a test
    /// that makes the answers to one type go missing waits briefly for those alone, and keeps room for every other answer
    /// on a loaded machine.
    public let requestTimeoutOf: (@Sendable (String) -> TimeInterval)?
    /// The phone's monotonic clock in seconds, counting the time the phone sleeps (the vault's clock as last seen is the
    /// newest answer's `ts` plus the time elapsed on it since, VAULT-MESSAGING §11.14.9 "A lost answer").
    public let uptime: @Sendable () -> TimeInterval

    /// `CLOCK_MONOTONIC`, which on Apple's systems keeps counting while the phone sleeps (`systemUptime` does not).
    @Sendable public static func monotonicNow() -> TimeInterval { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

    public init(
        role: String = roleApp,
        name: String,
        relayURL: String,
        transport: HTTPTransport,
        store: DeviceStateStore,
        enrolledAttestation: EnrolledAttestation,
        now: @escaping @Sendable () -> Date = { Date() },
        collectMode: MailboxCollector.Mode = .longPoll,
        pollWait: TimeInterval = RelayClient.defaultWait,
        requestTimeout: TimeInterval = defaultTimeout,
        requestTimeoutOf: (@Sendable (String) -> TimeInterval)? = nil,
        uptime: @escaping @Sendable () -> TimeInterval = DeviceConfig.monotonicNow
    ) {
        self.role = role
        self.name = name
        self.relayURL = relayURL.hasSuffix("/") ? String(relayURL.dropLast()) : relayURL
        self.transport = transport
        self.store = store
        self.enrolledAttestation = enrolledAttestation
        self.now = now
        self.collectMode = collectMode
        self.pollWait = pollWait
        self.requestTimeout = requestTimeout
        self.requestTimeoutOf = requestTimeoutOf
        self.uptime = uptime
    }

    /// How long a request of [type] waits for its answer before it is sent again (VAULT-MESSAGING §8.6).
    func requestTimeout(for type: String) -> TimeInterval { requestTimeoutOf?(type) ?? requestTimeout }
}
