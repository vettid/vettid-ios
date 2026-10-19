import Testing
@testable import VettID
import VettIDData
import VettIDUI

/// The stored theme choice and the theme the app applies (vettid-android `MainActivity`'s `toMode` and `toPreference`).
struct ThemeChoiceTests {
    @Test func eachChoiceAppliesItsTheme() {
        #expect(ThemePreference.allCases.map(\.mode) == [.system, .light, .dark])
        for mode in ThemeMode.allCases {
            #expect(ThemePreference(mode).mode == mode)
        }
    }
}
