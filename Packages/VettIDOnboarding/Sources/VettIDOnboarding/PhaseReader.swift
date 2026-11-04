import Foundation
import VettIDData

/// The app's read of the phase (``AppPhase``), one at a time whoever asks. A start that could not read it (still `.starting`, or
/// an iPhone that was locked) is read again when the app launches, comes to the foreground or protected data becomes available
/// ([ask]); the member's own "Try again" ([tryAgain]) is always answered, whatever failed the read.
@MainActor
public final class PhaseReader {
    private let flight = SingleFlight()
    private let phase: @MainActor () -> AppPhase
    private let refresh: @MainActor () async -> Void

    public init(phase: @escaping @MainActor () -> AppPhase, refresh: @escaping @MainActor () async -> Void) {
        self.phase = phase
        self.refresh = refresh
    }

    /// Whether [phase] is a start that could not read this phone's state yet.
    public static func readsAgain(_ phase: AppPhase) -> Bool {
        switch phase {
        case .starting, .unreachable(.phoneLocked, _): true
        default: false
        }
    }

    /// The launch, the foreground, protected data: reads only while the phase is one that could not be read. An ask made during a
    /// read gets one more read after it, only while the phase still needs one.
    public func ask() async {
        guard Self.readsAgain(phase()) else { return }
        await flight.run(stillNeeded: { [phase] in Self.readsAgain(phase()) }, refresh)
    }

    /// The member's "Try again" (on the start or the unreachable screen): always answered, with the extra read too.
    public func tryAgain() async {
        await flight.run(forced: true, stillNeeded: { [phase] in Self.readsAgain(phase()) }, refresh)
    }

    /// TEST ONLY: a read is under way.
    var running: Bool { flight.running }
}
