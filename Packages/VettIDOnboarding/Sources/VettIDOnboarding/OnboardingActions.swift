import Foundation

/// What the onboarding screens can ask for: ``OnboardingViewModel``, or ``NoOnboardingActions`` in previews and the
/// screen catalog. Mirrors vettid-android `OnboardingActions`.
@MainActor
public protocol OnboardingActions: AnyObject, Sendable {
    func start()
    func startRecovery()
    func startTransfer()
    func recover()
    func transfer()
    func leaveMove()
    func newVaultAfterMove()
    func typeCode()
    func scanned(_ text: String)
    func setEmail(_ v: String)
    func setCode(_ v: String)
    func submitCode()
    func confirmAccount()
    @discardableResult func back() -> Bool
    func useAnotherCode()
    func enrollAnyway()
    func setPin(_ v: String)
    func submitPin()
    func setPinConfirm(_ v: String)
    func submitPinConfirm()
    func setPassword(_ v: String)
    func setPasswordConfirm(_ v: String)
    func submitPassword()
    func setBackup(_ on: Bool)
    func acknowledgeBackupOff(_ ack: Bool)
    func submitBackup()
    func run()
    func editAfterFailure()
    func finish()
    /// (IOS-PLAN §4.2) The member has seen "Your vault was deleted…" on the welcome screen.
    func dismissDeletedNotice()
}

/// Actions that do nothing: the screens rendered with sample states (previews, the screen catalog).
@MainActor
public final class NoOnboardingActions: OnboardingActions {
    public init() {}

    public func start() {}
    public func startRecovery() {}
    public func startTransfer() {}
    public func recover() {}
    public func transfer() {}
    public func leaveMove() {}
    public func newVaultAfterMove() {}
    public func typeCode() {}
    public func scanned(_ text: String) {}
    public func setEmail(_ v: String) {}
    public func setCode(_ v: String) {}
    public func submitCode() {}
    public func confirmAccount() {}
    public func back() -> Bool { false }
    public func useAnotherCode() {}
    public func enrollAnyway() {}
    public func setPin(_ v: String) {}
    public func submitPin() {}
    public func setPinConfirm(_ v: String) {}
    public func submitPinConfirm() {}
    public func setPassword(_ v: String) {}
    public func setPasswordConfirm(_ v: String) {}
    public func submitPassword() {}
    public func setBackup(_ on: Bool) {}
    public func acknowledgeBackupOff(_ ack: Bool) {}
    public func submitBackup() {}
    public func run() {}
    public func editAfterFailure() {}
    public func finish() {}
    public func dismissDeletedNotice() {}
}
