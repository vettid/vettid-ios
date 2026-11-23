import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// AA8 "How a string is shown", the fingerprints and the program advice, the vault's reason, the events of the pages and the
/// additions of the screens' PR to the reading of an answer. Mirrors vettid-android `ItemWaysTextTest` (the part that is not a
/// text of a screen) and the added cases of `AgentPermissionsTest` and `ItemWaysTest`.
@Suite struct ItemWaysTextTests {
    func cp(_ c: UInt32...) -> String { String(String.UnicodeScalarView(c.compactMap(Unicode.Scalar.init))) }

    @Test func plainAsciiIsOneRun() {
        #expect(ShownString.pieces("/usr/bin/git") == [.text("/usr/bin/git", plain: true)])
        #expect(!ShownString.lookalike(ShownString.pieces("git")))
        #expect(ShownString.pieces("").isEmpty)
    }

    @Test func spacesAreMarked() {
        #expect(ShownString.pieces(" a  ") == [.space, .text("a", plain: true), .space, .space])
    }

    /// Every class AA8 names is escaped: controls, formats (bidi), separators, ignorables, other blanks, the braille blank.
    @Test func escapes() {
        for c: UInt32 in [0x01, 0x7F, 0x202E, 0x200B, 0x2066, 0x2028, 0x2029, 0x00A0, 0x3000, 0x3164, 0x115F, 0xFE0F, 0x2800, 0xE000, 0xFEFF] {
            #expect(ShownString.pieces("a" + cp(c) + "b") == [.text("a", plain: true), .escape(c), .text("b", plain: true)], "U+\(String(c, radix: 16))")
        }
        #expect(ShownPiece.label(0x202E) == "U+202E")
        #expect(ShownPiece.label(0xE0041) == "U+E0041")
        #expect(ShownPiece.label(0x7F) == "U+007F")
    }

    /// A combining mark at the start, after a separator, an escape or a space is escaped; after a letter it is shown.
    @Test func combiningMarksAtAnEdge() {
        let acute: UInt32 = 0x0301
        #expect(ShownString.pieces(cp(acute) + "a").first == .escape(acute))
        #expect(ShownString.pieces("/" + cp(acute))[1] == .escape(acute))
        #expect(ShownString.pieces("\\" + cp(acute))[1] == .escape(acute))
        #expect(ShownString.pieces(" " + cp(acute))[1] == .escape(acute))
        #expect(ShownString.pieces(cp(0x200B, acute))[1] == .escape(acute))
        #expect(ShownString.pieces("e" + cp(acute)) == [.text("e", plain: true), .text(cp(acute), plain: false)])
    }

    /// Right-to-left letters and look-alikes are shown in their order, highlighted, with the look-alike line.
    @Test func lookAlikesAndRightToLeft() {
        let cyrillicA = cp(0x0430)
        let p = ShownString.pieces("b" + cyrillicA + "sh")
        #expect(p == [.text("b", plain: true), .text(cyrillicA, plain: false), .text("sh", plain: true)])
        #expect(ShownString.lookalike(p))
        let hebrew = cp(0x05D0, 0x05D1)
        #expect(ShownString.pieces(hebrew) == [.text(hebrew, plain: false)])
    }

    @Test func fingerprints() {
        let sha = "1a2b3c4d5e6f7a8b" + String(repeating: "0", count: 48)
        #expect(Fingerprints.short(sha) == "1a2b 3c4d 5e6f 7a8b")
        #expect(Fingerprints.full(sha).split(separator: " ").count == 16)
    }

    /// vettid/vettid.org#636: compared as the `shell` flag compares (any case, endings and trailing dots and spaces).
    @Test func programsThatRunCommands() {
        for p in ["git", "/usr/bin/git", "GIT.EXE", "C:/Program Files/Git/cmd/git.exe", "npm.cmd", "npm.cmd.", "pip3.12", "pip3", "docker", "gh", "zip.exe.cmd", "\u{212A}ubectl"] {
            #expect(ProgramAdvice.runsCommands(p), "\(p)")
        }
        for p in ["gitk", "python", "pipx", "bash", ".cmd", "pip-audit", "/usr/bin/curl"] {
            #expect(!ProgramAdvice.runsCommands(p), "\(p)")
        }
    }

    @Test func batchFiles() {
        for p in ["C:/tools/run.cmd", "RUN.BAT", "x.cmd. ", "C:\\a\\b.Bat"] { #expect(ProgramAdvice.batchFile(p), "\(p)") }
        for p in ["run.exe", "cmd", "/usr/bin/batch"] { #expect(!ProgramAdvice.batchFile(p), "\(p)") }
    }

    /// AA7 "Saving" (0.1.138): 1 to 200 bytes of printable ASCII are shown as they are; anything else is not.
    @Test func theVaultsReasonIsShownOnlyWhenPrintableAscii() {
        #expect(VaultReason.shown("run.programs[0].env[1]: VETTID_IN is reserved") == "run.programs[0].env[1]: VETTID_IN is reserved")
        #expect(VaultReason.shown(String(repeating: "x", count: 200)) == String(repeating: "x", count: 200))
        #expect(VaultReason.shown(" ~") == " ~")
        for bad in [nil, "", String(repeating: "x", count: 201), "a\tb", "a\nb", "caf\u{00e9}", "a\u{007f}b"] {
            #expect(VaultReason.shown(bad) == nil, "\(String(describing: bad))")
        }
    }

    /// The string rule inside a sentence: isolated and forced left to right, escapes as markers, spaces marked.
    @Test func theInlineFormOfTheStringRule() {
        #expect(ShownString.inline("git", empty: "(empty)") == "\u{2066}\u{202D}git\u{202C}\u{2069}")
        #expect(ShownString.inline("g\u{202E}it x", empty: "(empty)") == "\u{2066}\u{202D}g⟨U+202E⟩it·x\u{202C}\u{2069}")
    }

    /// Nothing is highlighted inline, so every character outside printable ASCII is a marker, a literal one included.
    @Test func theInlineFormMarksEverythingOutsideAscii() {
        func inner(_ s: String) -> String { String(ShownString.inline(s, empty: "(empty)").dropFirst(2).dropLast(2)) }
        #expect(inner("g\u{0456}t") == "g⟨U+0456⟩t")
        #expect(inner("a\u{00B7}b") == "a⟨U+00B7⟩b")
        #expect(inner("\u{27E8}U+202E\u{27E9}") == "⟨U+27E8⟩U+202E⟨U+27E9⟩")
        #expect(inner("caf\u{00E9}") == "caf⟨U+00E9⟩")
        #expect(inner("") == "⟨(empty)⟩")
    }

    @Test func theAgentsPageListsUseFirstAndThenTheWaysItAllows() {
        #expect(shownWays([]) == [.use])
        #expect(shownWays(["reveal", "run"]) == [.use, .run, .reveal])
        #expect(shownWays(["use", "proxy", "teleport"]) == [.use, .proxy])
    }

    // MARK: Events

    func sync(_ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: "sync.event", ts: Date(), body: Array(body.utf8)))
    }

    /// `leash.item.changed` is an item event, a deletion only without a `version`; a `version` that does not read is not one.
    @Test func anItemEventIsADeletionOnlyWithoutAVersion() {
        let kind = { (body: String) in ItemWaysEvent.of(self.sync(body), seq: 1)?.kind }
        #expect(kind(#"{"kind":"leash.item.changed","agent_id":"a1","item_id":"i1","version":3}"#) == .item(agentID: "a1", itemID: "i1", version: 3, deleted: false))
        #expect(kind(#"{"kind":"leash.item.changed","agent_id":"a1","item_id":"i1"}"#) == .item(agentID: "a1", itemID: "i1", version: nil, deleted: true))
        #expect(kind(#"{"kind":"leash.item.changed","agent_id":"a1","item_id":"i1","version":"x"}"#) == .item(agentID: "a1", itemID: "i1", version: nil, deleted: false))
        #expect(kind(#"{"kind":"leash.item.changed","item_id":"i1","version":3}"#) == nil)
        #expect(kind(#"{"kind":"leash.item.changed","agent_id":"a1","item_id":"","version":3}"#) == nil)
        #expect(kind(#"{"kind":"share.rule.changed","rule_id":"r1"}"#) == .rule)
        #expect(kind(#"{"kind":"share.rule.deleted"}"#) == .rule)
        #expect(kind(#"{"kind":"leash.grant.changed","agent_id":"a1"}"#) == nil)
    }

    @Test func anEventConcernsItsAgentAndARuleEventEveryAgent() {
        let item = ItemWaysEvent(seq: 1, kind: .item(agentID: "a1", itemID: "i1", version: 2, deleted: false))
        #expect(item.concerns("a1") && !item.concerns("a2"))
        #expect(ItemWaysEvent(seq: 2, kind: .rule).concerns("a2"))
    }

    @MainActor
    @Test func theManagerKeepsTheLastEventAndForgetsItAtLock() {
        let m = ItemWaysManager(ops: { throw VaultFailure(.other) })
        m.onEvent(sync(#"{"kind":"leash.item.changed","agent_id":"a1","item_id":"i1","version":3}"#))
        #expect(m.event?.seq == 1)
        m.onEvent(sync(#"{"kind":"leash.grant.changed","agent_id":"a1"}"#))
        #expect(m.event?.seq == 1, "an event the pages do not read for leaves it")
        m.onEvent(sync(#"{"kind":"leash.item.changed","agent_id":"a1","item_id":"i1","version":3}"#))
        #expect(m.event?.seq == 3, "the same event twice is two events")
        m.clear()
        #expect(m.event == nil)
        #expect(!m.listed)
    }

    // MARK: What a screen's PR adds to the reading

    /// The answer's `run.folders` is known, read or not.
    @Test func theAnswerSaysWhetherItCarriesFolders() throws {
        let with = try #require(ItemWaysRules.one(Array(#"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","run"],"run":{"programs":[],"each":true,"folders":[]}}"#.utf8)))
        let without = try #require(ItemWaysRules.one(Array(#"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","run"],"run":{"programs":[],"each":true}}"#.utf8)))
        let unread = try #require(ItemWaysRules.one(Array(#"{"agent_id":"a1","item_id":"i1","ways":["use","run"],"run":{"programs":[],"each":true,"folders":[{"path":"/a","write":false}],"x":1}}"#.utf8)))
        #expect(with.answerHasFolders && !without.answerHasFolders)
        #expect(unread.readOnly && unread.answerHasFolders)
        #expect(with.asForeign().foreign && with.asForeign().readOnly && with.asForeign().answerHasFolders)
    }

    /// `"folders": null` is no folders: only a real value counts.
    @Test func aNullFoldersIsNotInTheAnswer() throws {
        let r = try #require(ItemWaysRules.one(Array(#"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","run"],"run":{"programs":[],"each":true,"folders":null}}"#.utf8)))
        #expect(!r.answerHasFolders)
    }

    @Test func aFoldersListOfNothingIsTheSameSettings() throws {
        let a = ItemWays(agentID: "a1", itemID: "i1", version: 1, ways: [.use, .run], run: RunSettings(programs: [RunProgram(program: "gh")], each: true, folders: []))
        var b = a
        b.run?.folders = nil
        #expect(ItemWaysRules.sameSettings(a, b))
        b.run?.each = false
        #expect(!ItemWaysRules.sameSettings(a, b))
    }

    /// "The same settings" is byte for byte: canonically equivalent spellings are different strings.
    @Test func identicalSettingsAreComparedByTheirBytes() {
        func ways(_ program: String, header: String = "Authorization") -> ItemWays {
            ItemWays(
                agentID: "a1", itemID: "i1", version: 1, ways: [.use, .run, .proxy],
                run: RunSettings(programs: [RunProgram(program: program, env: ["A"])], each: true),
                proxy: ProxySettings(hosts: ["a.example.com"], header: header, prefix: "Bearer ")
            )
        }
        #expect(ItemWaysRules.identical(ways("caf\u{00E9}"), ways("caf\u{00E9}")))
        #expect("caf\u{00E9}" == "cafe\u{0301}", "Swift's == takes them for one")
        #expect(!ItemWaysRules.identical(ways("caf\u{00E9}"), ways("cafe\u{0301}")))
        #expect(!ItemWaysRules.sameSettings(ways("caf\u{00E9}"), ways("cafe\u{0301}")))
        #expect(!ItemWaysRules.identical(ways("git"), ways("git", header: "X-Api-Key")))
        #expect(ItemWaysRules.identical(nil, nil) && !ItemWaysRules.identical(ways("git"), nil))
    }

    @Test func theVaultsCapabilityIsItemWays() {
        #expect(Capabilities.itemWays == "item_ways")
    }
}
// swiftlint:enable line_length
