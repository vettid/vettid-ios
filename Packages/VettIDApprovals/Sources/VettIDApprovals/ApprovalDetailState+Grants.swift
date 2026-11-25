import Foundation
import VettIDData

// A grant request's choices and what a decision needs (ANDROID-PLAN §4 Approvals).
extension ApprovalDetailState {
    /// The grant entries that will be granted: chosen, and for a category answered.
    public var grantIndexes: Set<Int> {
        guard case .grant(let g)? = approval else { return [] }
        let chosen = grantSelected ?? Set(g.grantable)
        return chosen.filter { i in
            guard g.entries.indices.contains(i) else { return false }
            let e = g.entries[i]
            return (e.kind == "item" && e.available) || grantAnswers[i] != nil
        }
    }

    /// Items the member may answer with: never `critical` (§10.12).
    public var answerable: [AnswerItem] { items.filter { !$0.critical } }

    /// Critical actions ask for the credential password (ANDROID-PLAN §4 Approvals).
    public var needs: ApprovalNeeds {
        switch approval {
        case .authentication?, .critical?: .password
        default: .nothing
        }
    }
}
