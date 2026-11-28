import SwiftUI
import Testing
import UIKit
@testable import VettIDUI

/// The approvals indicator (ANDROID-PLAN §4 "The approvals indicator", D9; IOS-PLAN §4.12, ID19): its VoiceOver label, the
/// countdown and its end, the badge, when it is the capsule, its colors, its target, and nothing without the shell's value.
/// Mirrors vettid-android `ApprovalsIndicatorTest`.
@MainActor
struct ApprovalsIndicatorTests {
    static let now = Date(timeIntervalSince1970: 1_795_996_800)

    static func indicator(
        _ count: Int, critical: Bool = false, urgent: Bool = false, in s: TimeInterval? = nil, label: String? = nil
    ) -> ApprovalsIndicator {
        ApprovalsIndicator(
            count: count, critical: critical, urgent: urgent, deadline: s.map { now.addingTimeInterval($0) }, label: label
        ) {}
    }

    private func size(_ view: some View, type: DynamicTypeSize = .large) -> CGSize {
        let root = view.environment(\.dynamicTypeSize, type).vettIDTheme(.light)
        return UIHostingController(rootView: root).sizeThatFits(in: CGSize(width: 390, height: 4_000))
    }

    /// The owner-approved Android texts (GC #17779): the count, and which entry expires in how long once that is known.
    @Test func theVoiceOverLabel() {
        #expect(Self.indicator(1).description(nil) == "Approvals, 1 waiting")
        #expect(Self.indicator(3).description(nil) == "Approvals, 3 waiting")
        let shop = Self.indicator(1, critical: true, urgent: true, in: 80, label: "\u{2068}Shop\u{2069}")
        #expect(shop.description(80) == "Approvals, 1 waiting. \u{2068}Shop\u{2069} expires in \(spokenDuration(80))")
        #expect(spokenDuration(80) == "1 minute, 20 seconds", "DateComponentsFormatter's words, comma included")
        #expect(shop.description(0) == "Approvals, 1 waiting", "at its end: the count alone")
        #expect(Self.indicator(1, critical: true, in: 80).description(80) == "Approvals, 1 waiting", "an entry that names nothing")
    }

    @Test func theCountdownRoundsUpAndEndsAtZero() {
        let deadline = Self.now.addingTimeInterval(80.4)
        #expect(ApprovalsIndicator.secondsUntil(deadline, Self.now) == 81)
        #expect(ApprovalsIndicator.face(81) == "1:21" && ApprovalsIndicator.face(80) == "1:20" && ApprovalsIndicator.face(9) == "0:09")
        #expect(ApprovalsIndicator.secondsUntil(deadline, deadline) == 0)
        #expect(ApprovalsIndicator.secondsUntil(deadline, deadline.addingTimeInterval(30)) == 0)
        #expect(ApprovalsIndicator.face(0) == "0:00")
    }

    @Test func theBadgeSays99PlusAbove99() {
        #expect(badgeText(99) == "99" && badgeText(100) == "99+")
    }

    /// Time-critical with room: the capsule; compact, at an accessibility size or narrower than 360 pt: the icon with a clock.
    @Test func whenItIsTheCapsule() {
        let critical = Self.indicator(1, critical: true, urgent: true, in: 60)
        #expect(critical.capsule(compact: false, typeSize: .large, width: 390))
        #expect(
            critical.capsule(compact: false, typeSize: .xxxLarge, width: 360), "the largest size below the accessibility ones, at 360 pt"
        )
        #expect(!critical.capsule(compact: true, typeSize: .large, width: 390))
        #expect(!critical.capsule(compact: false, typeSize: .accessibility1, width: 390))
        #expect(!critical.capsule(compact: false, typeSize: .large, width: 359))
        #expect(!Self.indicator(3).capsule(compact: false, typeSize: .large, width: 390), "not time-critical: the icon")
    }

    /// Only an urgent entry gets the urgency colors; a sign-in alone is neutral. Never the error color itself ("never red").
    @Test func onlyUrgentGetsTheUrgencyColors() {
        let c = VettIDColors.light
        #expect(ApprovalsIndicator.timeColors(urgent: true, c) == (c.errorContainer, c.onErrorContainer))
        #expect(ApprovalsIndicator.timeColors(urgent: false, c) == (c.surfaceVariant, c.onSurfaceVariant))
        #expect(c.errorContainer != c.error && VettIDColors.dark.errorContainer != VettIDColors.dark.error)
    }

    @Test func itTicksOnlyWhileShownAndNotCovered() {
        let capsule = ApprovalsIndicatorButton(Self.indicator(1, critical: true, in: 60, label: "Bank"))
        #expect(capsule.ticks(voiceOver: false))
        let icon = ApprovalsIndicatorButton(Self.indicator(1, critical: true, in: 60, label: "Bank"), compact: true)
        #expect(!icon.ticks(voiceOver: false) && icon.ticks(voiceOver: true), "the icon ticks only for VoiceOver's label")
        #expect(!ApprovalsIndicatorButton(Self.indicator(1, critical: true)).ticks(voiceOver: true), "no deadline: the clock alone")
        #expect(!ApprovalsIndicatorButton(Self.indicator(2)).ticks(voiceOver: true))
        // Under the daily check, drawn over the shell: no tick at all (vettid-android `noTickUnderTheDailyCheck`).
        let critical = Self.indicator(1, critical: true, in: 60, label: "Bank")
        #expect(ApprovalsIndicatorButton.ticks(critical, capsule: true, covered: false, voiceOver: false))
        #expect(!ApprovalsIndicatorButton.ticks(critical, capsule: true, covered: true, voiceOver: true))
        #expect(!ApprovalsIndicatorButton.ticks(critical, capsule: false, covered: true, voiceOver: true))
    }

    /// Equal on what it shows, whatever its tap: the bars are not drawn again when the shell rebuilds the same indicator.
    @Test func equalOnWhatItShows() {
        var tapped = 0
        let a = ApprovalsIndicator(count: 2, critical: true, urgent: true, deadline: Self.now, label: "Bank") {}
        let b = ApprovalsIndicator(count: 2, critical: true, urgent: true, deadline: Self.now, label: "Bank") { tapped += 1 }
        #expect(a == b && tapped == 0)
        #expect(a != Self.indicator(3) && Self.indicator(1, critical: true, in: 60) != Self.indicator(1, critical: true, in: 61))
    }

    @Test func itIsAtLeastATarget() {
        for i in [Self.indicator(3), Self.indicator(1, critical: true, urgent: true, in: 80)] {
            for type in [DynamicTypeSize.large, .accessibility3] {
                let s = size(ApprovalsIndicatorButton(i, typeSize: type))
                #expect(s.width >= Spacing.minTarget && s.height >= Spacing.minTarget)
            }
        }
    }

    /// Without the shell's value the bars draw no indicator: the same size as before.
    @Test func withoutTheShellsValueNothingIsDrawn() {
        // At its own width (the spacer collapsed), the indicator adds its 48 pt target.
        let bar = VettIDBackTopBar(onBack: {}).fixedSize()
        let plain = size(bar)
        let with = size(bar.environment(\.vettIDApprovalsIndicator, Self.indicator(3)))
        let without = size(bar.withoutApprovalsIndicator().environment(\.vettIDApprovalsIndicator, Self.indicator(3)))
        #expect(with.width >= plain.width + Spacing.touchTarget)
        #expect(without == plain, "a screen's opt-out wins over the shell's value")
        let removed = size(bar.environment(\.vettIDApprovalsIndicator, nil))
        #expect(removed == plain)
    }
}
