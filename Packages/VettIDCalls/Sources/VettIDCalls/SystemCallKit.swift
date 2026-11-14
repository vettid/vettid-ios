#if os(iOS)
import AVFoundation
import CallKit
import Foundation

extension CallKitSettings {
    /// `iconTemplateImage` is PNG data of a template image (CallKit's lock-screen button); none is set when nil.
    package func configuration(iconTemplateImage: Data? = nil) -> CXProviderConfiguration {
        let c = CXProviderConfiguration(localizedName: localizedName)
        c.maximumCallGroups = maximumCallGroups
        c.maximumCallsPerCallGroup = maximumCallsPerCallGroup
        c.supportsVideo = supportsVideo
        c.supportedHandleTypes = supportsGenericHandles ? [.generic] : []
        c.includesCallsInRecents = includesCallsInRecents
        c.ringtoneSound = ringtoneSound
        c.iconTemplateImageData = iconTemplateImage
        return c
    }
}

extension CallKitEndReason {
    var system: CXCallEndedReason {
        switch self {
        case .failed: .failed
        case .remoteEnded: .remoteEnded
        case .unanswered: .unanswered
        case .answeredElsewhere: .answeredElsewhere
        case .declinedElsewhere: .declinedElsewhere
        }
    }
}

extension CallKitUpdate {
    var system: CXCallUpdate {
        let u = CXCallUpdate()
        u.remoteHandle = CXHandle(type: .generic, value: handle)
        u.localizedCallerName = name
        u.hasVideo = hasVideo
        u.supportsHolding = supportsHolding
        u.supportsGrouping = supportsGrouping
        u.supportsUngrouping = supportsUngrouping
        u.supportsDTMF = supportsDTMF
        return u
    }
}

extension CallKitAction {
    var system: CXAction {
        switch self {
        case .start(let uuid, let handle): CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        case .answer(let uuid): CXAnswerCallAction(call: uuid)
        case .end(let uuid): CXEndCallAction(call: uuid)
        case .mute(let uuid, let muted): CXSetMutedCallAction(call: uuid, muted: muted)
        }
    }
}

/// `CXProvider` and `CXCallController`, with the provider's delegate on the main queue.
@MainActor
package final class SystemCallKit: CallKitProviding, CallKitControlling {
    private let provider: CXProvider
    private let controller = CXCallController()
    private let events = Events()

    package init(settings: CallKitSettings = .standard, iconTemplateImage: Data? = nil) {
        provider = CXProvider(configuration: settings.configuration(iconTemplateImage: iconTemplateImage))
        provider.setDelegate(events, queue: .main)
    }

    /// The coordinator that answers CallKit's actions (the provider is made first, the coordinator needs it).
    package func attach(_ target: any CallKitEvents) { events.target = target }

    package func reportNewIncomingCall(uuid: UUID, update: CallKitUpdate) async -> CallKitReport {
        await withCheckedContinuation { c in
            provider.reportNewIncomingCall(with: uuid, update: update.system) { error in
                guard let error = error as NSError? else { return c.resume(returning: .reported) }
                let filters = [CXErrorCodeIncomingCallError.filteredByDoNotDisturb, .filteredByBlockList].map(\.rawValue)
                let filtered = error.domain == CXErrorDomainIncomingCall && filters.contains(error.code)
                c.resume(returning: filtered ? .filtered : .failed)
            }
        }
    }

    package func reportCall(uuid: UUID, updated: CallKitUpdate) { provider.reportCall(with: uuid, updated: updated.system) }

    package func reportOutgoingCall(uuid: UUID, startedConnectingAt: Date) {
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: startedConnectingAt)
    }

    package func reportOutgoingCall(uuid: UUID, connectedAt: Date) { provider.reportOutgoingCall(with: uuid, connectedAt: connectedAt) }

    package func reportCall(uuid: UUID, endedAt: Date, reason: CallKitEndReason) {
        provider.reportCall(with: uuid, endedAt: endedAt, reason: reason.system)
    }

    package func request(_ action: CallKitAction) async throws { try await controller.request(CXTransaction(action: action.system)) }

    /// The delegate. CallKit calls it on the main queue (set above); each action is fulfilled or failed by the coordinator's answer.
    private final class Events: NSObject, CXProviderDelegate, @unchecked Sendable {
        nonisolated(unsafe) weak var target: (any CallKitEvents)?

        func providerDidReset(_ provider: CXProvider) {
            MainActor.assumeIsolated { target?.providerDidReset() }
        }

        func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
            MainActor.assumeIsolated { target?.actionTimedOut() }
        }

        func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
            let uuid = action.callUUID
            let ok = MainActor.assumeIsolated { target?.performStart(uuid: uuid) } ?? false
            if ok { action.fulfill() } else { action.fail() }
        }

        func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
            let uuid = action.callUUID
            let ok = MainActor.assumeIsolated { target?.performAnswer(uuid: uuid) } ?? false
            if ok { action.fulfill() } else { action.fail() }
        }

        func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
            let uuid = action.callUUID
            let ok = MainActor.assumeIsolated { target?.performEnd(uuid: uuid) } ?? false
            if ok { action.fulfill() } else { action.fail() }
        }

        func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
            let (uuid, muted) = (action.callUUID, action.isMuted)
            let ok = MainActor.assumeIsolated { target?.performMute(uuid: uuid, muted: muted) } ?? false
            if ok { action.fulfill() } else { action.fail() }
        }

        // The audio session is the app's only between these two (CallKit activates and deactivates it).
        func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
            MainActor.assumeIsolated { target?.audioDidActivate() }
        }

        func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
            MainActor.assumeIsolated { target?.audioDidDeactivate() }
        }
    }
}
#endif
