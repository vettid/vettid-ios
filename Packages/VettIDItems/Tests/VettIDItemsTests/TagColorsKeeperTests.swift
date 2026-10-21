import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDItems

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The colour keeper (owner decision 2026-10-09): a dropped registry is read again quietly, a listed one gets colours for
/// its tags without one, never while the vault is held or due. Mirrors vettid-android's `TagColorsViewModel`.
@MainActor
@Suite struct TagColorsKeeperTests {
    let sharing = FakeSharing()
    /// The palette's stand-in: the first tag without a colour (never `@`) gets `#00000n`.
    let next: ([TagView]) -> (tag: String, color: String)? = { tags in
        tags.filter { !$0.tag.hasPrefix("@") && $0.color == nil }.min { $0.tag < $1.tag }.map { ($0.tag, "#00000\(tags.count { $0.color != nil })") }
    }

    @Test func aDroppedRegistryIsReadAgainAndColoured() async {
        sharing.registry = TagRegistry(version: 1, tags: [TagView(tag: "@profile"), TagView(tag: "travel"), TagView(tag: "home", color: "#ff0000")])
        var gated = false
        let keeper = TagColorsKeeper(sharing: sharing, gated: { gated }, next: next, rereadDelay: .milliseconds(10))
        #expect(await eventually { sharing.calls.contains("refreshTagsQuietly") && sharing.calls.contains("assignColors") })
        #expect(await eventually { keeper.colors == ["home": "#ff0000", "travel": "#000001"] })
        // Held or due: a registry listed then gets no colours.
        gated = true
        let assigned = sharing.calls.count { $0 == "assignColors" }
        sharing.registry.tags.append(TagView(tag: "garden"))
        sharing.tags = nil
        #expect(await eventually { sharing.calls.count { $0 == "refreshTagsQuietly" } == 2 && sharing.tags != nil })
        #expect(sharing.calls.count { $0 == "assignColors" } == assigned, "nothing stored while gated")
        _ = keeper
    }

    @Test func aGatedQuietReadKeepsTheHashColours() async {
        sharing.gated = true
        let keeper = TagColorsKeeper(sharing: sharing, gated: { true }, next: next, rereadDelay: .milliseconds(10))
        #expect(await eventually { sharing.calls.contains("refreshTagsQuietly") })
        #expect(sharing.tags == nil && keeper.colors.isEmpty && !sharing.calls.contains("assignColors"))
    }
}

// swiftlint:enable line_length
