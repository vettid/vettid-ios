import Foundation

// The texts of an approval's document (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents"): the titles, labels and
// warnings §10.4 gives, and the headings, notices and accessibility labels it leaves to IOS-PLAN (chosen; not in the
// spec, until IOS-PLAN has them).
extension ApprovalsStrings {
    static var docAsked: String { String(localized: "approvals_doc_asked", defaultValue: "What is asked", bundle: .module) }

    static var docDescription: String {
        String(localized: "approvals_doc_description", defaultValue: "The service's description", bundle: .module)
    }

    static var docDescriptionNote: String {
        String(localized: "approvals_doc_description_note", defaultValue: "What you approve is the request below", bundle: .module)
    }

    static var docSummary: String { String(localized: "approvals_doc_summary", defaultValue: "The service's summary", bundle: .module) }

    static var docRequest: String { String(localized: "approvals_doc_request", defaultValue: "The request", bundle: .module) }

    static var docDetails: String { String(localized: "approvals_doc_details", defaultValue: "Request details", bundle: .module) }

    static var docTitleProposalCreate: String {
        String(localized: "approvals_doc_title_proposal_create", defaultValue: "New vote", bundle: .module)
    }

    static var docTitleVoteExtend: String {
        String(localized: "approvals_doc_title_vote_extend", defaultValue: "Extend a vote", bundle: .module)
    }

    static var docTitleAdminSetAdd: String {
        String(localized: "approvals_doc_title_admin_set_add", defaultValue: "Add an admin", bundle: .module)
    }

    static var docTitleAdminSetRemove: String {
        String(localized: "approvals_doc_title_admin_set_remove", defaultValue: "Remove an admin", bundle: .module)
    }

    static var docTitleAdminRepin: String {
        String(localized: "approvals_doc_title_admin_repin", defaultValue: "Re-pin an admin's key", bundle: .module)
    }

    static var docTitleContractTemplateChange: String {
        String(localized: "approvals_doc_title_contract_template_change", defaultValue: "Change the contract template", bundle: .module)
    }

    static var docTitleAssignmentPush: String {
        String(localized: "approvals_doc_title_assignment_push", defaultValue: "Send an assignment", bundle: .module)
    }

    static var docCantShow: String {
        String(localized: "approvals_doc_cant_show", defaultValue: "This request can't be shown", bundle: .module)
    }

    static var docLoading: String { String(localized: "approvals_doc_loading", defaultValue: "Getting the request…", bundle: .module) }

    static var docRetry: String { String(localized: "approvals_doc_retry", defaultValue: "Try again", bundle: .module) }

    static var docReadToEnd: String {
        String(localized: "approvals_doc_read_to_end", defaultValue: "Scroll to the end of the request to approve it.", bundle: .module)
    }

    static var docFieldTitle: String { String(localized: "approvals_doc_field_title", defaultValue: "Title", bundle: .module) }

    static var docFieldMotion: String { String(localized: "approvals_doc_field_motion", defaultValue: "Motion", bundle: .module) }

    static var docNone: String { String(localized: "approvals_doc_none", defaultValue: "None", bundle: .module) }

    static var docFieldChoices: String { String(localized: "approvals_doc_field_choices", defaultValue: "Choices", bundle: .module) }

    static var docAbstain: String { String(localized: "approvals_doc_abstain", defaultValue: "Abstain", bundle: .module) }

    static var docAbstainAdded: String {
        String(localized: "approvals_doc_abstain_added", defaultValue: "added by the service", bundle: .module)
    }

    static var docFieldQuorum: String { String(localized: "approvals_doc_field_quorum", defaultValue: "Quorum", bundle: .module) }

    static var docBinding: String { String(localized: "approvals_doc_binding", defaultValue: "Binding", bundle: .module) }

    static var docAdvisory: String { String(localized: "approvals_doc_advisory", defaultValue: "Advisory", bundle: .module) }

    static var docFieldRemovedMayVote: String {
        String(
            localized: "approvals_doc_field_removed_may_vote", defaultValue: "Members removed after the roster date may vote",
            bundle: .module
        )
    }

    static var docYes: String { String(localized: "approvals_doc_yes", defaultValue: "Yes", bundle: .module) }

    static var docNo: String { String(localized: "approvals_doc_no", defaultValue: "No", bundle: .module) }

    static var docFieldOpens: String { String(localized: "approvals_doc_field_opens", defaultValue: "Opens", bundle: .module) }

    static var docFieldCloses: String { String(localized: "approvals_doc_field_closes", defaultValue: "Closes", bundle: .module) }

    static var docFieldOutageRule: String {
        String(localized: "approvals_doc_field_outage_rule", defaultValue: "Outage rule", bundle: .module)
    }

    static var docFieldVote: String { String(localized: "approvals_doc_field_vote", defaultValue: "Vote", bundle: .module) }

    static var docFieldNewClose: String { String(localized: "approvals_doc_field_new_close", defaultValue: "New close", bundle: .module) }

    static var docFieldOutageFrom: String {
        String(localized: "approvals_doc_field_outage_from", defaultValue: "Outage from", bundle: .module)
    }

    static var docFieldOutageTo: String { String(localized: "approvals_doc_field_outage_to", defaultValue: "Outage to", bundle: .module) }

    static var docFieldReportedBy: String {
        String(localized: "approvals_doc_field_reported_by", defaultValue: "Reported by", bundle: .module)
    }

    static func docUnknownWarning(_ value: String) -> String {
        String(
            localized: "approvals_doc_unknown_warning",
            defaultValue: "\(value) asks for something this app doesn't know. Read all of it before you approve.",
            bundle: .module
        )
    }

    /// VoiceOver: a raw view's line's nesting level ("level 2").
    static func docLevelSpoken(_ n: Int) -> String {
        String(localized: "approvals_doc_level_spoken", defaultValue: "level \(n)", bundle: .module)
    }

    /// Quorum's ballots: "1 ballot", "10 ballots".
    static func docBallots(_ n: Int) -> String {
        String(localized: "approvals_doc_ballots", defaultValue: "\(n) ballots", bundle: .module)
    }
}
