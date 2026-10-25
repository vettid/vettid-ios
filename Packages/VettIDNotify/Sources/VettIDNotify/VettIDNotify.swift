/// Local notifications now; the notification content rules shared with the notification service extension in phase P.
///
/// Mirrors vettid-android `:core:notify` (IOS-PLAN §5). Until phase P (IOS-PLAN §6.7) nothing is posted: the app asks for
/// no notification permission, and what the notifications would say is here, ready and tested, while the screens say the
/// same in the app (the unlock screen for the idle lock).
public enum VettIDNotify {
    /// The package name, used by the skeleton's smoke test.
    public static let name = "VettIDNotify"
}
