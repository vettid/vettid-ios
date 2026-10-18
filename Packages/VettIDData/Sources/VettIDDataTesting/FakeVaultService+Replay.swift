#if DEBUG
import Foundation
import VettIDCrypto

// TEST ONLY. How vettid-vault meets a request again (VAULT-MESSAGING §5.3, §8.2), for a lost answer to `pin.change` or
// `credential.password.change` (§11.14.9 "A lost answer"), as `vault/inbound.go` does: a request whose `exp` has passed
// by the vault's clock is dropped unanswered before the dedupe and any handler; a request whose inner id was seen
// already is never run again, and its cached answer is sent again in a new envelope (the same inner id and `ts`). The
// test can lose answers or requests of a type on their way, stamp the vault's answers with its own clock, and move the
// blob without the app.
extension FakeVaultService {
    /// The clock the vault's answers are stamped with: the vault's own (``advanceVaultClock(_:)``) with
    /// ``stampsOnVaultClock``, else the real one.
    var stampNow: Date { stampsOnVaultClockValue ? vaultNow : Date() }

    /// Stamps the vault's answers with its own clock and drops the requests whose `exp` it has passed (the owner-check
    /// tests, which move that clock by days, keep the real one; and the lock tests, whose `vault.lock` is valid for a
    /// fraction of a second, no `exp` check).
    public var stampsOnVaultClock: Bool {
        get { locked { stampsOnVaultClockValue } }
        set { locked { stampsOnVaultClockValue = newValue } }
    }

    /// The answers to requests of these types are made (and cached) but lost on their way to the app.
    public func loseAnswers(_ types: Set<String>) { locked { lostAnswerTypes = types } }

    /// The requests of these types never reach the vault (nothing is done or answered).
    public func loseRequests(_ types: Set<String>) { locked { lostRequestTypes = types } }

    /// The type of every request that reached the vault in the session, in order (lost ones excepted; repeats included).
    public var requestsSeen: [String] { locked { requestsSeenValue } }

    /// The `exp` of the last request of [type] that reached the vault.
    public func lastExp(_ type: String) -> Date? { locked { lastExpValue[type] } }

    /// The password failures the vault counted (§3.5.3).
    public var passwordFailureCount: Int { locked { passwordFailures } }

    /// The blob moves on without the app (an earlier credential operation applied without its answer): the app's next
    /// operation with its blob is answered `stale_credential`.
    public func moveCredentialWithoutTheApp() { locked { credentialVersion += 1 } }

    /// Whether [m] is handled: not lost on its way, not expired, and not seen before (whose cached answer goes again).
    /// Callers hold ``cond``.
    func arrives(_ m: Inner) throws -> Bool {
        if lostRequestTypes.contains(m.type) { return false }
        requestsSeenValue.append(m.type)
        if let exp = m.exp { lastExpValue[m.type] = exp }
        if stampsOnVaultClockValue, let exp = m.exp, vaultNow > exp { return false }
        guard !seenRequests.contains(m.id) else {
            if let cached = responses[m.id], !lostAnswerTypes.contains(m.type), let epoch = keyring.current() {
                queue(try epoch.seal(cached))
            }
            return false
        }
        seenRequests.insert(m.id)
        return true
    }
}
#endif
