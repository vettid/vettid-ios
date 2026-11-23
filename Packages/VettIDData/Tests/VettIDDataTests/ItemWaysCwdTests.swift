import Foundation
import Testing
@testable import VettIDData

// Test data: long literal rows are clearer than wrapped ones.
// swiftlint:disable line_length

/// AA8: a run's plain `cwd` is allowed only by settings that carry `run` without `folders` (`ItemWaysRules.runCwdAllowed`, the one
/// rule the approval check and the screen share). Mirrors vettid-android `ItemWaysTest.runCwdAllowedOnlyWithRunAndNoFolders`.
@Suite struct ItemWaysCwdTests {
    func read(_ json: String) -> ItemWaysRead? { ItemWaysRules.one(Array(#"{"agent_id":"a1","item_id":"i1",\#(json)}"#.utf8)) }

    @Test func runCwdAllowedOnlyWithRunAndNoFolders() {
        #expect(ItemWaysRules.runCwdAllowed(read(#""ways":["use","run"],"run":{"programs":[],"each":true}"#)))
        #expect(!ItemWaysRules.runCwdAllowed(read(#""ways":["use","run"],"run":{"programs":[],"each":true,"folders":[]}"#)), "folders, even empty")
        #expect(!ItemWaysRules.runCwdAllowed(read(#""ways":["use"]"#)), "no run")
        #expect(!ItemWaysRules.runCwdAllowed(read(#""ways":["use","run"],"run":[]"#)), "run not an object")
        #expect(!ItemWaysRules.runCwdAllowed(nil), "no read")
        // Settings shown read only (an unknown member) judge the same way: the rule reads the answer as it is.
        #expect(ItemWaysRules.runCwdAllowed(read(#""ways":["use","run"],"run":{"programs":[],"each":true},"later":1"#)))
    }

    /// Chosen; not in the spec: Android judges the lenient reading of a duplicate-member answer; here such an answer has no strict
    /// reading, so it is not allowed.
    @Test func anAnswerThatDoesNotReadStrictlyAllowsNothing() {
        #expect(!ItemWaysRules.runCwdAllowed(read(#""ways":["use","run"],"run":{"programs":[],"each":true},"run":{"programs":[],"each":true}"#)))
    }
}

// swiftlint:enable line_length
