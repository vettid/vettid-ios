#if DEBUG
import Foundation
import Observation
import VettIDData

/// TEST ONLY. The release update for view-model tests: the offer and the progress are set by the test; every call is
/// recorded in ``calls`` (the PIN is recorded as given, to check what was approved). Mirrors vettid-android
/// `FakeReleaseUpdates`.
@MainActor
@Observable
public final class FakeReleaseUpdates: ReleaseUpdateRepository {
    public private(set) var calls: [String] = []
    public var offer: ReleaseUpdateOffer?
    public var offerKnown: Bool
    public var progress: UpdateProgress?
    public var checkDue = false
    public var changeHold: FailureKind?
    public private(set) var dismissal: ReleaseDismissal?
    public private(set) var refreshed = 0
    /// What ``start(pin:offer:)`` answers when the check is not due.
    public var startResult = true

    public init(offer: ReleaseUpdateOffer? = nil) {
        self.offer = offer
        offerKnown = offer != nil
    }

    public func refreshOffer() async {
        refreshed += 1
        offerKnown = true
    }

    public func ownerCheckDue() -> Bool { checkDue }

    public func dismissBanner(at: Date) {
        guard let o = offer else { return }
        calls.append("dismiss:\(o.target.number)")
        dismissal = ReleaseDismissal(release: o.target.number, kind: o.kind, at: at)
    }

    public func start(pin: String, offer: ReleaseUpdateOffer) -> Bool {
        calls.append("start:\(pin):\(offer.target.number)")
        return startResult && !checkDue && changeHold == nil
    }

    public func retry(pin: String) { calls.append("retry:\(pin)") }

    public func abandon(pin: String) { calls.append("abandon:\(pin)") }

    public func finish() {
        calls.append("finish")
        progress = nil
    }
}

/// TEST ONLY. What's new for view-model tests: [answer], after [gate] when one is set; the releases asked for are recorded.
/// Mirrors vettid-android `FakeReleaseNotes`.
public final class FakeReleaseNotes: ReleaseNotesRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var answerValue: ReleaseNotes
    private var askedValue: [UInt64] = []
    private var gateValue: TestDeferred<ReleaseNotes>?

    public init(_ answer: ReleaseNotes = .unavailable) {
        answerValue = answer
    }

    public var answer: ReleaseNotes {
        get { lock.withLock { answerValue } }
        set { lock.withLock { answerValue = newValue } }
    }

    /// When set, the next answers wait for it and answer its value.
    public var gate: TestDeferred<ReleaseNotes>? {
        get { lock.withLock { gateValue } }
        set { lock.withLock { gateValue = newValue } }
    }

    public var asked: [UInt64] { lock.withLock { askedValue } }

    public func whatsNew(target: ReleaseView, between: [ReleaseView]) async -> ReleaseNotes {
        let gate = lock.withLock {
            askedValue.append(target.number)
            return gateValue
        }
        if let gate { return (try? await gate.value()) ?? .unavailable }
        return answer
    }
}
#endif
