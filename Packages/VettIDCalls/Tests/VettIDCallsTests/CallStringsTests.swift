import Foundation
import Testing
@testable import VettIDCalls

// swiftlint:disable line_length

/// The microphone texts of the calls, word for word (the owner approved them in Ground Control #10653, answer a); a changed text
/// is the owner's to approve. Each row is a text's key, what its accessor gives (the name "Example"), and the expected text.
@Suite struct CallStringsTests {
    struct Row {
        let key: String
        let got: String
        let want: String

        init(_ key: String, _ got: String, _ want: String) {
            self.key = key
            self.got = got
            self.want = want
        }
    }

    static let table: [Row] = [
        Row("calls_microphone_title", CallStrings.microphoneTitle, "Allow the microphone"),
        Row("calls_microphone_body", CallStrings.microphoneBody("Example"), "VettID needs the microphone so Example can hear you. It is used only during calls."),
        Row("calls_name_unknown", CallStrings.nameUnknown, "Your connection"),
        Row("calls_microphone_allow", CallStrings.microphoneAllow, "Allow"),
        Row("calls_microphone_not_now", CallStrings.microphoneNotNow, "Not now"),
        Row("calls_microphone_blocked_title", CallStrings.microphoneBlockedTitle, "The microphone is turned off for VettID"),
        Row("calls_microphone_blocked_body", CallStrings.microphoneBlockedBody, "iOS doesn't ask again. To make and answer calls, allow the microphone for VettID in Settings."),
        Row("calls_microphone_open_settings", CallStrings.microphoneOpenSettings, "Open Settings"),
        Row("calls_microphone_close", CallStrings.microphoneClose, "Close"),
    ]

    @Test func everyTextIsWordForWord() {
        #expect(Self.table.count == 9)
        for row in Self.table { #expect(row.got == row.want, "\(row.key)") }
    }

    /// The catalog holds exactly the keys of the table: no text without a row, no row without a text.
    @Test func theTableHoldsEveryKeyOfTheCatalog() throws {
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.catalog)) as? [String: Any])
        let keys = Set(try #require((doc["strings"] as? [String: Any])?.keys))
        #expect(keys == Set(Self.table.map(\.key)))
        // The catalog's own values, not only the defaults in the code.
        let strings = try #require(doc["strings"] as? [String: [String: Any]])
        for row in Self.table where row.key != "calls_microphone_body" {
            let en = (((strings[row.key]?["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])
            #expect(en?["value"] as? String == row.want, "\(row.key)")
        }
    }

    static var catalog: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDCalls/Resources/Localizable.xcstrings")
    }

    /// The system prompt's text is for the build that links calls: not in the app's Info.plist yet.
    @Test func theUsageDescriptionIsTheApprovedText() {
        #expect(CallStrings.microphoneUsageDescription == "VettID uses the microphone only during calls, so the person you're talking to can hear you.")
    }
}
// swiftlint:enable line_length
