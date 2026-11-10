import Foundation
import Testing
@testable import VettIDData
@testable import VettIDDevices

/// How the Devices & agents screens say a device's facts (ANDROID-PLAN 0.1.53 AA1; VAULT-MESSAGING 0.76.0 §10.8): the role, the name
/// in a row and in a sentence, the access and the last activity. Mirrors vettid-android `DevicesScreenTest`'s text checks.
@Suite struct DeviceTextsTests {
    let now = Samples.now
    let utc = Samples.calendar()

    func device(_ kind: String, _ name: String, thisPhone: Bool = false) -> DeviceInfo {
        DeviceInfo(id: "x", kind: kind, name: name, thisPhone: thisPhone)
    }

    @Test func theRoleIsAgentDesktopPhoneOrTheKindItself() {
        #expect(DeviceTexts.role(Samples.agent) == "Agent" && DeviceTexts.role(Samples.desktop) == "Desktop")
        #expect(DeviceTexts.role(device("app", "Old phone")) == "Phone" && DeviceTexts.role(Samples.phone) == "This phone")
        #expect(DeviceTexts.role(device("toaster", "Odd")) == "toaster")
        // A kind that shows nothing, or nothing at all: "Device".
        #expect(DeviceTexts.role(device("", "Odd")) == "Device" && DeviceTexts.role(device("\u{200B}\u{3164}", "Odd")) == "Device")
        // A kind is cleaned as received text: its controls and overrides go.
        #expect(DeviceTexts.role(device("to\u{202E}as\u{0007}ter", "Odd")) == "toaster")
    }

    @Test func aDeviceWithoutANameIsNamedByItsRole() {
        #expect(DeviceTexts.name(device("agent", "")) == "An agent")
        #expect(DeviceTexts.name(device("desktop", "")) == "A desktop")
        #expect(DeviceTexts.name(device("app", "")) == "Unnamed phone")
        #expect(DeviceTexts.name(device("toaster", "")) == "Unnamed toaster")
        #expect(DeviceTexts.name(device("", "")) == "Unnamed device")
        #expect(DeviceTexts.name(Samples.agent) == "Claude")
    }

    @Test func inASentenceAnUnnamedDeviceIsLowerCaseAndANamedOneIsIsolated() {
        #expect(DeviceTexts.sentenceName(device("agent", "")) == "an agent")
        #expect(DeviceTexts.sentenceName(device("desktop", "")) == "a desktop")
        #expect(DeviceTexts.sentenceName(device("app", "")) == "\u{2068}Unnamed phone\u{2069}")
        #expect(DeviceTexts.sentenceName(Samples.agent) == "\u{2068}Claude\u{2069}")
        // The role label of a lookalike is inside the isolate too.
        #expect(DeviceTexts.sentenceName(device("agent", "VettID")) == "\u{2068}VettID (Agent)\u{2069}")
    }

    @Test func aNameThatCouldPassForThePhoneOrVettIdIsShownWithItsRole() {
        #expect(DeviceTexts.name(device("agent", "this PHONE")) == "this PHONE (Agent)")
        #expect(DeviceTexts.name(device("desktop", "VettID")) == "VettID (Desktop)")
        // Inner spaces, no-break spaces and U+2800 cannot slip past; a plain different name is shown as it is.
        for lookalike in ["This  phone", "This\u{00A0}phone", "This\u{2800}phone", "\u{2800}VettID", "Vett\u{2800}ID"] {
            #expect(DeviceTexts.name(device("agent", lookalike)).hasSuffix("(Agent)"), "\(lookalike.unicodeScalars.map(\.value))")
        }
        #expect(DeviceTexts.name(device("agent", "Vett ID")) == "Vett ID")
        #expect(DeviceTexts.name(device("agent", "My phone")) == "My phone")
    }

    @Test func theAccessIsTheTimeTodayAndTheDateWithItOnAnotherDay() {
        let today = DeviceInfo(id: "a", kind: "agent", name: "A", sessionExpiresAt: now.addingTimeInterval(3 * 3_600 + 40 * 60))
        let text = DeviceTexts.access(today, now: now, calendar: utc)
        #expect(text.hasPrefix("Access until ") && text.contains("3:40") && !text.contains("Oct"), "\(text)")
        let later = DeviceInfo(id: "a", kind: "agent", name: "A", sessionExpiresAt: now.addingTimeInterval(3 * 86_400))
        let other = DeviceTexts.access(later, now: now, calendar: utc)
        let onDate = other.hasPrefix("Access until ") && other.contains("Oct 24") && other.contains("2026")
        #expect(onDate && other.contains("12:00"), "\(other)")
    }

    @Test func theTimeIsInThePhonesZone() {
        let end = DeviceInfo(id: "a", kind: "agent", name: "A", sessionExpiresAt: now.addingTimeInterval(3 * 3_600 + 40 * 60))
        // 15:40 UTC is 20:40 at +5: still the 21st there, the time alone.
        let text = DeviceTexts.access(end, now: now, calendar: Samples.calendar(offsetHours: 5))
        #expect(text.contains("8:40") && !text.contains("3:40"), "\(text)")
        // At +14, now (12:00 UTC) is 02:00 on the 22nd and the end (15:40 UTC) is 05:40 on the 22nd: the same day, the time alone.
        let far = Samples.calendar(offsetHours: 14)
        let sameDay = DeviceTexts.access(end, now: now, calendar: far)
        #expect(!sameDay.contains("Oct"), "\(sameDay)")
        // Over midnight in that zone: now is the 21st at -5 (07:00) and the end (11:40 on the 21st) too, but 20 h later is the 22nd.
        let night = DeviceInfo(id: "a", kind: "agent", name: "A", sessionExpiresAt: now.addingTimeInterval(20 * 3_600))
        let across = DeviceTexts.access(night, now: now, calendar: Samples.calendar(offsetHours: -5))
        #expect(across.contains("Oct 22"), "\(across)")
    }

    @Test func noSessionOrAPastOneIsNoAccess() {
        #expect(DeviceTexts.access(Samples.desktop, now: now, calendar: utc) == "No access")
        let past = DeviceInfo(id: "a", kind: "agent", name: "A", sessionExpiresAt: now.addingTimeInterval(-1))
        #expect(DeviceTexts.access(past, now: now, calendar: utc) == "No access")
        // The very end is no access (it ends at that second, as `hasAccess` says).
        let atEnd = DeviceInfo(id: "a", kind: "agent", name: "A", sessionExpiresAt: now)
        #expect(DeviceTexts.access(atEnd, now: now, calendar: utc) == "No access")
    }

    @Test func lastActiveSaysHowLongAgoUntilThirtyDaysThenTheDate() {
        func ago(_ s: TimeInterval) -> String { DeviceTexts.ago(Samples.before(s), now: now, calendar: utc) }
        #expect(ago(0) == "just now" && ago(59) == "just now" && ago(-120) == "just now")
        #expect(ago(60) == "1 min ago" && ago(3_599) == "59 min ago")
        #expect(ago(3_600) == "1 h ago" && ago(86_399) == "23 h ago")
        #expect(ago(86_400) == "1 d ago" && ago(29 * 86_400 + 86_399) == "29 d ago")
        let old = ago(30 * 86_400)
        #expect(old == "Sep 21, 2026", "\(old)")
        #expect(DeviceTexts.lastActive(Samples.agent, now: now, calendar: utc) == "Last active 10 min ago")
        #expect(DeviceTexts.lastActive(Samples.desktop, now: now, calendar: utc) == "Not active yet")
    }

    @Test func pairedOnIsTheFullDateAndTime() {
        let text = DeviceTexts.full(Samples.before(86_400), utc)
        #expect(text.contains("Oct 20") && text.contains("2026") && text.contains("12:00"), "\(text)")
    }
}
