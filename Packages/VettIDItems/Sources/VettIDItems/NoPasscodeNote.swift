import Foundation

/// Whether the one-time note on revealing with no passcode has been shown: a flag of this device, not a secret and not
/// vault data, kept in `UserDefaults` as the theme is (``ItemDetailViewModel/askReveal(noPasscode:_:)``). The app's wipe
/// clears the whole `UserDefaults` domain, so the note is due again after one.
public struct NoPasscodeNote {
    /// The `UserDefaults` key.
    public static let key = "hints.reveal_no_passcode"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// True the first time only: the note is due, and is marked shown.
    func takeFirst() -> Bool {
        if defaults.bool(forKey: Self.key) { return false }
        defaults.set(true, forKey: Self.key)
        return true
    }
}
