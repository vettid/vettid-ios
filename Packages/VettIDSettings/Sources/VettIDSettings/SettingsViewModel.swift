import Foundation
import Observation
import VettIDData
import VettIDKeys

/// The Settings screen's state (vettid-android `SettingsUiState`, as far as the iPhone app has its rows yet): the account
/// read-only, the app lock and its method and timeout, and the last failure.
public struct SettingsState: Equatable, Sendable {
    public var account: AccountInfo?
    public var appLockOn = false
    /// The lock turned itself off because Face ID or Touch ID changed: the notice.
    public var appLockInvalidated = false
    /// How the app lock asks: the chosen method, also while the lock is off.
    public var appLockMethod: AppLockMethod = .biometrics
    public var appLockTimeout: AppLockTimeout = .standard
    public var busy = false
    public var error: FailureKind?
    /// The app lock could not be turned on: this iPhone cannot make its key (vettid-android's `app_lock_enable_failed`
    /// toast).
    public var appLockUnavailable = false
    /// Face ID and Touch ID are not set up but a passcode is: the notice suggests the passcode method.
    public var appLockSuggestPasscode = false
    /// "Allow screenshots" (IOS-PLAN §4): on, and whether it stays on (a development build).
    public var screenshotsAllowed = false
    public var screenshotsStayOn = false
    /// (Release R) This phone holds a phone secret: New phone secret is offered.
    public var phoneSecret = false

    public init(
        account: AccountInfo? = nil,
        appLockOn: Bool = false,
        appLockInvalidated: Bool = false,
        appLockMethod: AppLockMethod = .biometrics,
        appLockTimeout: AppLockTimeout = .standard,
        busy: Bool = false,
        error: FailureKind? = nil,
        appLockUnavailable: Bool = false,
        appLockSuggestPasscode: Bool = false,
        screenshotsAllowed: Bool = false,
        screenshotsStayOn: Bool = false,
        phoneSecret: Bool = false
    ) {
        self.account = account
        self.appLockOn = appLockOn
        self.appLockInvalidated = appLockInvalidated
        self.appLockMethod = appLockMethod
        self.appLockTimeout = appLockTimeout
        self.busy = busy
        self.error = error
        self.appLockUnavailable = appLockUnavailable
        self.appLockSuggestPasscode = appLockSuggestPasscode
        self.screenshotsAllowed = screenshotsAllowed
        self.screenshotsStayOn = screenshotsStayOn
        self.phoneSecret = phoneSecret
    }
}

/// Settings (ANDROID-PLAN §4): the app lock and its timeout (D6, IOS-PLAN ID17), the vault's lock, "Allow screenshots"
/// (IOS-PLAN §4, a local choice only: never stored or sent to the vault); the account read-only. Mirrors vettid-android
/// `SettingsViewModel`.
@MainActor
@Observable
public final class SettingsViewModel {
    private var busy = false
    private var error: FailureKind?
    private var appLockUnavailable = false
    private var appLockSuggestPasscode = false

    @ObservationIgnored private let account: any AccountRepository
    @ObservationIgnored private let vault: any VaultRepository
    @ObservationIgnored private let appLock: any AppLockSettings
    @ObservationIgnored private let promptReason: String
    @ObservationIgnored private let deviceAuthentication: @MainActor () -> DeviceAuthentication
    @ObservationIgnored private let screenshots: ScreenshotAllowance?
    @ObservationIgnored private let work = Work()
    /// Turning the app lock on: its prompt is the app lock's, never cancelled with the screen.
    @ObservationIgnored private let prompts = Work()

    /// [promptReason]: what the Face ID, Touch ID or passcode prompt says when the lock is turned on. [deviceAuthentication]:
    /// what the iPhone can ask for, read when the lock is turned on. [screenshots]: the app's "Allow screenshots" (nil: the
    /// row shows off and changes nothing).
    public init(
        account: any AccountRepository,
        vault: any VaultRepository,
        appLock: any AppLockSettings,
        promptReason: String,
        screenshots: ScreenshotAllowance? = nil,
        deviceAuthentication: @escaping @MainActor () -> DeviceAuthentication = { DeviceAuthentication.current() }
    ) {
        self.account = account
        self.vault = vault
        self.appLock = appLock
        self.promptReason = promptReason
        self.screenshots = screenshots
        self.deviceAuthentication = deviceAuthentication
    }

    deinit { work.cancelAll() }

    /// The state now: the repositories' and the app lock's, observed through them, with this screen's own.
    public var state: SettingsState {
        SettingsState(
            account: account.account, appLockOn: appLock.state.isOn, appLockInvalidated: appLock.invalidated,
            appLockMethod: appLock.method, appLockTimeout: appLock.timeout, busy: busy, error: error,
            appLockUnavailable: appLockUnavailable, appLockSuggestPasscode: appLockSuggestPasscode,
            screenshotsAllowed: screenshots?.allowed ?? false, screenshotsStayOn: screenshots?.staysOn ?? false,
            phoneSecret: vault.usesPhoneSecret
        )
    }

    /// "Allow screenshots": on after the member confirmed (the screen asks first), for at most an hour and until the vault
    /// locks; off at once.
    public func setScreenshotsAllowed(_ on: Bool) {
        if on { screenshots?.allow() } else { screenshots?.disallow() }
    }

    /// The switch: on asks for Face ID, Touch ID or the passcode at once (a new key); off needs no prompt (the app is
    /// open).
    public func setAppLock(_ on: Bool) {
        if on {
            enable(appLock.method)
        } else {
            act { try $0.appLock.disable() }
        }
    }

    /// The method: while the lock is on, a new key with one prompt; while it is off, only the choice.
    public func setAppLockMethod(_ m: AppLockMethod) {
        guard m != appLock.method else { return }
        if appLock.state.isOn {
            enable(m)
        } else {
            act { try $0.appLock.chooseMethod(m) }
        }
    }

    public func setAppLockTimeout(_ t: AppLockTimeout) { act { try $0.appLock.setTimeout(t) } }

    public func acknowledgeInvalidated() { appLock.acknowledgeInvalidated() }

    public func dismissAppLockUnavailable() {
        appLockUnavailable = false
        appLockSuggestPasscode = false
    }

    /// Locks the vault: this phone is locked at once; whether the vault confirmed it is the unlock screen's notice.
    public func lockVault() {
        busy = true
        error = nil
        // The lock itself runs to its end in the vault manager (VAULT-LOCK); this only waits to say how it went.
        let vault = vault
        work.launch { [weak self] in
            var failed: FailureKind?
            do {
                try await vault.lock()
            } catch {
                failed = failureKind(error)
            }
            self?.busy = false
            self?.error = failed
        }
    }

    public func dismissError() { error = nil }

    /// Face ID and Touch ID only, never the passcode in their place (the key is bound to the enrolled faces or fingers): an
    /// iPhone without them is not asked; it is told to choose the passcode method, or, without a passcode either, that the
    /// lock cannot be used.
    private func enable(_ m: AppLockMethod) {
        appLockUnavailable = false
        appLockSuggestPasscode = false
        let can = deviceAuthentication()
        if m == .biometrics, !can.biometrics {
            if can.passcode { appLockSuggestPasscode = true } else { appLockUnavailable = true }
            return
        }
        if m == .passcode, !can.passcode {
            appLockUnavailable = true
            return
        }
        let lock = appLock
        let reason = promptReason
        // Not cancelled when the screen goes (``prompts``): the app lock owns this work, and a prompt cut short would leave
        // it off without the member having chosen that.
        prompts.launch { [weak self] in
            do {
                // False: the member cancelled the prompt; nothing to say.
                _ = try await lock.enable(m, reason: reason)
            } catch {
                self?.appLockUnavailable = true
            }
        }
    }

    /// A local change of the app lock's settings: one that cannot be written is the screen's failure.
    private func act(_ body: (SettingsViewModel) throws -> Void) {
        do {
            try body(self)
        } catch {
            self.error = (error as? VaultFailure)?.kind ?? .localState
        }
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async {
        await work.settle()
        await prompts.settle()
    }
}
