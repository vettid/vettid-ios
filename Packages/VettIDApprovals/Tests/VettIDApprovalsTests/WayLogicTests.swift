import Foundation
import Testing
@testable import VettIDApprovals
@testable import VettIDData

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// AA8: a run's size in its summary, the gate's re-arm key and the scroll gate's rule. Mirrors vettid-android `WaySizesTest`,
/// the `WayKey` and `endReached` parts of `AgentWayScreenTest`.
@Suite struct WayLogicTests {
    private static let sha = String(repeating: "1a2b3c4d5e6f7a8b", count: 4)

    private func run(
        argv: [String] = ["git", "push"], env: [ItemRun.EnvEntry] = [], flags: Set<RunFlag> = [], previous: (String, String)? = nil
    ) -> ItemRun {
        ItemRun(
            itemID: "i1", fieldID: "f1", program: "/usr/bin/git", sha256: Self.sha, argv: argv, cwd: nil, how: .env, name: "T", env: env,
            flags: flags, previousSha256: previous?.0, previousPath: previous?.1, replaces: nil
        )
    }

    @Test func bytesKbAndMb() {
        #expect(WaySizes.unit(1_023) == .bytes(1_023))
        #expect(WaySizes.unit(1_024) == .kb(decimal("1.0")))
        #expect(WaySizes.unit(32_768) == .kb("32"))
        #expect(WaySizes.unit(1_572_864) == .mb(decimal("1.5")))
        #expect(WaySizes.unit(1_048_500) == .mb(decimal("1.0")), "after rounding")
        #expect(WaySizes.unit(10_230) == .kb("10"))
    }

    /// One decimal in the member's locale, as the unit's number is shown.
    private func decimal(_ s: String) -> String { String(format: "%.1f", locale: Locale.current, Double(s) ?? 0) }

    @Test func theBytesOfArgvAndEnvNamesAndValues() {
        #expect(WaySizes.runBytes(run(argv: ["git", "é"], env: [.init(name: "A", value: "bc")])) == 3 + 2 + 1 + 2)
    }

    private func show(_ r: ItemRun, item: String = "GitHub") -> HeldShow { .run(r, item: item, field: "Token") }

    @Test func theKeyFollowsEverythingShownAndNothingElse() {
        let base = WayKey.of(show(run()))
        #expect(base == WayKey.of(show(run())) && base.count == 64)
        #expect(base != WayKey.of(show(run(argv: ["git", "push", "x"]))))
        #expect(base != WayKey.of(show(run(argv: ["git", "pusH"]))), "a change of a value alone")
        #expect(base != WayKey.of(show(run(), item: "Other")))
        #expect(base != WayKey.of(show(run(env: [.init(name: "A", value: "b")]))))
        #expect(base != WayKey.of(show(run(flags: [.shell]))))
        #expect(WayKey.of(show(run(flags: [.shell, .inlineCode]))) == WayKey.of(show(run(flags: [.inlineCode, .shell]))), "a set has no order")
        // Parts are length-prefixed: moving a character from one to the next is another key.
        #expect(WayKey.of(show(run(argv: ["ab", "c"]))) != WayKey.of(show(run(argv: ["a", "bc"]))))
        #expect(WayKey.of(show(run(flags: [.programChanged], previous: (Self.sha, "/a")))) != WayKey.of(show(run(flags: [.programChanged], previous: (Self.sha, "/b")))))
    }

    @Test func theKeyFollowsTheProxyPrefixAndLength() {
        let p = ItemProxy(itemID: "i1", fieldID: "f1", host: "h.example.com", header: "Authorization", prefix: "Bearer ", seconds: 900, replaces: nil)
        func key(_ f: (inout ItemProxy) -> Void) -> String {
            var q = p
            f(&q)
            return WayKey.of(.proxy(q, item: "GitHub", field: "Token"))
        }
        let base = key { _ in }
        #expect(base != key { $0.prefix = "Bearer" } && base != key { $0.seconds = 901 } && base != key { $0.host = "i.example.com" })
        #expect(base != key { $0.header = "X-Key" } && base != key { $0.replaces = "h0" })
    }

    /// The end is reached when the bottom edge of the last element is inside the area above the buttons.
    @Test func theEndNeedsTheLastElementWhollyInside() {
        #expect(WayGate.endReached(end: 500, visibleBottom: 600) && WayGate.endReached(end: 600, visibleBottom: 600))
        #expect(!WayGate.endReached(end: 601, visibleBottom: 600) && !WayGate.endReached(end: 1_200, visibleBottom: 600))
    }

    @Test func onceReachedItStaysReachedAndAChangeOfWhatIsShownArmsItAgain() {
        var g = WayGate(key: "a")
        g.update(key: "a", top: nil, end: nil, visibleTop: 0, visibleBottom: 600)
        #expect(!g.reached, "not laid out")
        g.update(key: "a", top: 0, end: 1_000, visibleTop: 0, visibleBottom: 600)
        #expect(!g.reached)
        g.update(key: "a", top: -400, end: 590, visibleTop: 0, visibleBottom: 600)
        #expect(g.reached)
        g.update(key: "a", top: 0, end: 1_000, visibleTop: 0, visibleBottom: 600)
        #expect(g.reached, "scrolled back up: still reached")
        g.rearm("a")
        #expect(g.reached, "the same content: nothing changes")
        g.rearm("b")
        #expect(!g.reached && g.key == "b")
        g.update(key: "a", top: 0, end: 300, visibleTop: 0, visibleBottom: 600)
        #expect(!g.reached, "a reading of the old content")
    }

    /// Readings measured before the screen went back to the top are the old content's: they never open the new content's gate.
    @Test func staleReadingsAfterAChangeNeverOpenTheGateUntilTheTopIsSeen() {
        var g = WayGate(key: "a")
        g.update(key: "a", top: 0, end: 590, visibleTop: 0, visibleBottom: 600)
        #expect(g.reached)
        g.rearm("b")
        // The old offset (scrolled to the end) and the old end, delivered for the new key.
        g.update(key: "b", top: -900, end: 590, visibleTop: 0, visibleBottom: 600)
        g.update(key: "b", top: -900, end: 400, visibleTop: 0, visibleBottom: 600)
        #expect(!g.reached)
        // The top is back, the end is below the fold: still not reached.
        g.update(key: "b", top: 0, end: 1_500, visibleTop: 0, visibleBottom: 600)
        #expect(!g.reached)
        // Then the end, as the member scrolls.
        g.update(key: "b", top: -900, end: 590, visibleTop: 0, visibleBottom: 600)
        #expect(g.reached)
    }

    @Test func contentThatFitsAfterAChangeIsReachedWithoutADrag() {
        var g = WayGate(key: "a")
        g.update(key: "a", top: 0, end: 1_500, visibleTop: 0, visibleBottom: 600)
        g.rearm("b")
        g.update(key: "b", top: 0, end: 300, visibleTop: 0, visibleBottom: 600)
        #expect(g.reached, "a reading at the top whose end is visible")
    }

    /// The layout of the new content can be read before the change of key is seen: it is kept and judged when the gate is armed
    /// for it, so that content that fits needs no drag.
    @Test func aReadingOfTheNewContentThatCameBeforeTheChangeIsJudgedWhenItIsArmed() {
        var g = WayGate(key: "a")
        g.update(key: "a", top: 0, end: 1_500, visibleTop: 0, visibleBottom: 600)
        g.update(key: "b", top: 0, end: 300, visibleTop: 0, visibleBottom: 600)
        #expect(!g.reached, "not armed for b yet")
        g.rearm("b")
        #expect(g.reached, "judged at once, with no further reading")
        // A reading kept for a key that is not the one armed is not used.
        var h = WayGate(key: "a")
        h.update(key: "c", top: 0, end: 300, visibleTop: 0, visibleBottom: 600)
        h.rearm("b")
        #expect(!h.reached)
        // And one that is below the fold is kept as well, not opened.
        var k = WayGate(key: "a")
        k.update(key: "b", top: 0, end: 1_500, visibleTop: 0, visibleBottom: 600)
        k.rearm("b")
        #expect(!k.reached)
    }

    /// A bar or the safe area the content scrolls under: the top marker rests at the inset, and the end must clear the bottom one.
    @Test func theTopMarkerRestsAtTheInsetAndTheEndClearsTheBottomInset() {
        var g = WayGate(key: "a")
        // Resting at the top inset (59): that is the top. The end below the visible bottom (844 - 34).
        g.update(key: "a", top: 59, end: 1_000, visibleTop: 59, visibleBottom: 810)
        #expect(!g.reached)
        g.update(key: "a", top: -300, end: 812, visibleTop: 59, visibleBottom: 810)
        #expect(!g.reached, "under the bottom inset: not seen")
        g.update(key: "a", top: -300, end: 809, visibleTop: 59, visibleBottom: 810)
        #expect(g.reached)
        // After a change, a reading at 0 is not the top when the inset is 59, whatever the old offset was.
        g.rearm("b")
        g.update(key: "b", top: 0, end: 700, visibleTop: 59, visibleBottom: 810)
        #expect(!g.reached)
        g.update(key: "b", top: 59, end: 700, visibleTop: 59, visibleBottom: 810)
        #expect(g.reached)
        // A rotation changes the bounds: the last reading is judged against them.
        var r = WayGate(key: "a")
        r.update(key: "a", top: 0, end: 700, visibleTop: 0, visibleBottom: 600)
        #expect(!r.reached)
        r.area(visibleTop: 0, visibleBottom: 800)
        #expect(r.reached)
    }
}

// swiftlint:enable line_length
