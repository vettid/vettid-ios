/// TEST ONLY. Fakes, the dev stack helpers and the TEST App Attest attester. Linked by test targets only; the release check refuses it in Release and Staging builds.
///
/// Mirrors vettid-android `:core:testing` (IOS-PLAN §5). Empty until its phase.
public enum VettIDTesting {
    /// The package name, used by the skeleton's smoke test.
    public static let name = "VettIDTesting"
}
