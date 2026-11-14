import Foundation

// CallKit for the calls, in the foreground (no PushKit yet). CallKit does not exist on macOS, so the coordinator speaks in the
// small types below and runs (and is tested) anywhere; ``SystemCallKit`` (iOS only) turns them into `CXProvider` and
// `CXCallController` calls.

/// What CallKit shows of the other member: only what the app passes in. Never a phone number.
package struct CallParty: Equatable, Sendable {
    /// The handle (a generic CallKit handle): an opaque text, not a number.
    package var handle: String
    package var name: String

    package init(handle: String, name: String) {
        self.handle = handle
        self.name = name
    }
}

/// The call as CallKit is told about it (`CXCallUpdate`). Audio only, no holding, grouping or tones.
package struct CallKitUpdate: Equatable, Sendable {
    package var handle: String
    package var name: String
    package var hasVideo = false
    package var supportsHolding = false
    package var supportsGrouping = false
    package var supportsUngrouping = false
    package var supportsDTMF = false
}

/// `CXCallEndedReason`.
package enum CallKitEndReason: Equatable, Sendable {
    case failed, remoteEnded, unanswered, answeredElsewhere, declinedElsewhere
}

/// The actions the app asks of CallKit (`CXStartCallAction` and the others).
package enum CallKitAction: Equatable, Sendable {
    case start(UUID, handle: String)
    case answer(UUID)
    case end(UUID)
    case mute(UUID, Bool)
}

/// How CallKit took an incoming call.
package enum CallKitReport: Equatable, Sendable {
    case reported
    /// Do Not Disturb or a block list stopped it: that is respected (no ringtone of the app's own).
    case filtered
    case failed
}

@MainActor
package protocol CallKitProviding: AnyObject {
    func reportNewIncomingCall(uuid: UUID, update: CallKitUpdate) async -> CallKitReport
    func reportCall(uuid: UUID, updated: CallKitUpdate)
    func reportOutgoingCall(uuid: UUID, startedConnectingAt: Date)
    func reportOutgoingCall(uuid: UUID, connectedAt: Date)
    func reportCall(uuid: UUID, endedAt: Date, reason: CallKitEndReason)
}

@MainActor
package protocol CallKitControlling: AnyObject {
    /// One action as a transaction. Throws if CallKit refuses it.
    func request(_ action: CallKitAction) async throws
}

/// What the system's delegate reports; the answer is whether the action is fulfilled.
@MainActor
package protocol CallKitEvents: AnyObject {
    func performStart(uuid: UUID) -> Bool
    func performAnswer(uuid: UUID) -> Bool
    func performEnd(uuid: UUID) -> Bool
    func performMute(uuid: UUID, muted: Bool) -> Bool
    func audioDidActivate()
    func audioDidDeactivate()
    func providerDidReset()
    /// CallKit gave up waiting for an action: the call ends.
    func actionTimedOut()
}

/// The provider's settings (`CXProviderConfiguration`; spec-silent values are chosen here, see the PR text).
package struct CallKitSettings: Equatable, Sendable {
    package var localizedName = "VettID"
    package var maximumCallGroups = 1
    package var maximumCallsPerCallGroup = 1
    /// Audio only in C1.
    package var supportsVideo = false
    package var supportsGenericHandles = true
    /// Owner decision: calls appear in VettID's history only, never in the Phone app's Recents (nor iCloud's).
    package var includesCallsInRecents = false
    package var ringtoneSound = "vettid_ringtone.caf"

    package static let standard = CallKitSettings()
}

extension CallEnd {
    /// What CallKit is told when a call ends without the member ending it in CallKit's own screen.
    package var callKitReason: CallKitEndReason {
        switch self {
        case .hungUp, .peerHungUp, .declined, .busy: .remoteEnded
        case .declinedHere: .declinedElsewhere
        case .noAnswer, .missed: .unanswered
        case .answeredElsewhere: .answeredElsewhere
        case .unavailable, .ownVaultBusy, .callsOff, .ownerCheckRequired, .notSupported, .noAddress, .couldNotConnect,
             .connectionLost, .notEncrypted, .locked, .failed: .failed
        }
    }
}
