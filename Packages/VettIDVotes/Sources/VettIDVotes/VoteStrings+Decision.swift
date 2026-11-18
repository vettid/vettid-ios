import Foundation

// One text per line, as in VoteStrings.swift.
// swiftlint:disable line_length

/// How a vote is decided, and its outcome (BALLOT-PROTOCOL 0.14.0 §3.5, §7.1): the owner's words (a on #14031, #14043). The
/// three `cast` lines are the draft's own words until the owner says otherwise (#14049); they are here and in the catalog only.
extension VoteStrings {
    public static var voteRuleMajorityCast: String {
        String(localized: "vote_rule_majority_cast", defaultValue: "Decided by more than half of the votes for a choice. Abstaining doesn't count.", bundle: .module)
    }

    public static var voteRuleMajorityVoted: String {
        String(localized: "vote_rule_majority_voted", defaultValue: "Decided by more than half of all ballots. Abstaining counts against.", bundle: .module)
    }

    public static var voteRuleMajorityElig: String {
        String(localized: "vote_rule_majority_elig", defaultValue: "Decided by more than half of all eligible members. Not voting counts against.", bundle: .module)
    }

    public static func voteRuleThresholdCast(_ a1: String) -> String {
        String(localized: "vote_rule_threshold_cast", defaultValue: "Decided by at least \(a1) of the votes for a choice. Abstaining doesn't count.", bundle: .module)
    }

    public static func voteRuleThresholdVoted(_ a1: String) -> String {
        String(localized: "vote_rule_threshold_voted", defaultValue: "Decided by at least \(a1) of all ballots. Abstaining counts against.", bundle: .module)
    }

    public static func voteRuleThresholdElig(_ a1: String) -> String {
        String(localized: "vote_rule_threshold_elig", defaultValue: "Decided by at least \(a1) of all eligible members. Not voting counts against.", bundle: .module)
    }

    public static var voteRuleAllCast: String {
        String(localized: "vote_rule_all_cast", defaultValue: "Decided only if every vote for a choice is for the same one. Abstaining doesn't count.", bundle: .module)
    }

    public static var voteRuleAllVoted: String {
        String(localized: "vote_rule_all_voted", defaultValue: "Decided only if all ballots are for one choice. Abstaining counts against.", bundle: .module)
    }

    public static var voteRuleAllElig: String {
        String(localized: "vote_rule_all_elig", defaultValue: "Decided only if all eligible members vote for one choice. Not voting counts against.", bundle: .module)
    }

    public static var voteRulePlurality: String {
        String(localized: "vote_rule_plurality", defaultValue: "Decided by the most votes. A tie at the top decides nothing.", bundle: .module)
    }

    public static func voteOutcomeDecided(_ a1: String) -> String {
        String(localized: "vote_outcome_decided", defaultValue: "Decided: \(a1)", bundle: .module)
    }

    public static var voteOutcomeNotDecided: String {
        String(localized: "vote_outcome_not_decided", defaultValue: "Not decided: no choice met the rule.", bundle: .module)
    }

    public static var voteOutcomeTied: String {
        String(localized: "vote_outcome_tied", defaultValue: "Tied: no choice decided.", bundle: .module)
    }

    public static var voteOutcomeNoQuorum: String {
        String(localized: "vote_outcome_no_quorum", defaultValue: "No quorum: too few members voted.", bundle: .module)
    }
}
// swiftlint:enable line_length
