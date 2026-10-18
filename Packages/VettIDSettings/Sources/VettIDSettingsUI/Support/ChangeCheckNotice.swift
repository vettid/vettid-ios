import Foundation
import VettIDData

/// The one-time notice of a lost answer's decision reached while its screen was closed (VAULT-MESSAGING §11.14.9 "A lost
/// answer": the member is told). The shell shows it above every screen until the member acknowledges it
/// (``VaultRepository/acknowledgeChangeCheck()``); a change screen that was waiting shows and acknowledges it itself, and
/// one opened later does not show it again (chosen; not in the spec).
public enum ChangeCheckNotice {
    /// The text of a decided change, nil while undecided.
    public static func text(_ c: ChangeCheck) -> String? {
        switch (c.type, c.status) {
        case (_, .checking), (_, .unreachable): nil
        case (.pin, .applied): PinStrings.pinDone
        case (.password, .applied): CredentialStrings.changeDone
        case (.pin, .notApplied): PinStrings.pinNotChanged
        case (.password, .notApplied): CredentialStrings.passwordNotChanged
        case (_, .refused(let kind, _)): kind.message
        case (_, .ended): FailureKind.other.message
        }
    }

    /// A refusal, or a check that ended without a decision.
    public static func urgent(_ c: ChangeCheck) -> Bool {
        switch c.status {
        case .refused, .ended: true
        default: false
        }
    }
}
