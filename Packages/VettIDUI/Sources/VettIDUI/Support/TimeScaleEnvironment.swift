import SwiftUI

public extension EnvironmentValues {
    /// The vault's time scale (STAGING-TIME-SCALE §5.2), set once at the app's root from the vault manager, for the texts
    /// that name a scaled wait wherever a failure is shown (as vettid-android's `failureText()` reads its scale): 1 (real
    /// time) until a vault says otherwise.
    @Entry var vettIDTimeScale: UInt64 = 1
}
