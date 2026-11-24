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
        #expect(WayGate.endReached(end: 500, viewport: 600) && WayGate.endReached(end: 600, viewport: 600))
        #expect(!WayGate.endReached(end: 601, viewport: 600) && !WayGate.endReached(end: 1_200, viewport: 600))
    }

    @Test func onceReachedItStaysReachedAndAChangeOfWhatIsShownArmsItAgain() {
        var g = WayGate(key: "a")
        g.update(end: nil, viewport: 600)
        #expect(!g.reached, "not laid out")
        g.update(end: 1_000, viewport: 600)
        #expect(!g.reached)
        g.update(end: 590, viewport: 600)
        #expect(g.reached)
        g.update(end: 1_000, viewport: 600)
        #expect(g.reached, "scrolled back up: still reached")
        g.rearm("a")
        #expect(g.reached, "the same content: nothing changes")
        g.rearm("b")
        #expect(!g.reached && g.key == "b")
        // Content that fits is reached once it is laid out, judged again from the geometry of the new content.
        g.update(end: 300, viewport: 600)
        #expect(g.reached)
        g.rearm("c")
        g.update(end: 300, viewport: 600)
        g.rearm("d")
        g.rejudge()
        #expect(!g.reached, "the old geometry is not the new content's")
    }
}

// swiftlint:enable line_length
