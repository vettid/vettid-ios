import Foundation

// The defaults of the move's members of ``VaultRepository`` (VAULT-MESSAGING §11.14.9, §11.14.10), here to keep
// Repositories.swift short.
public extension VaultRepository {
    /// Safe by default: a PIN taken before a change is sent nothing; a real repository overrides it.
    func finishMove(pin: String, taken: Int?) async throws -> UnlockAttempt {
        if let taken, taken != pinGeneration { return .failed(.credentialUnsettled, code: "pin_taken_before_change") }
        return try await finishMove(pin: pin)
    }

    var pinGeneration: Int { 0 }
    var finishMoveHold: FailureKind? { nil }
    var transferKeepSeconds: Int64 { KeptTransfer.keepMs(timeScale: timeScale) / 1000 }
    var keptCheckPending: Bool { false }
}
