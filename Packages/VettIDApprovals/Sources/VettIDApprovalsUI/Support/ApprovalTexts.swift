import Foundation
import VettIDApprovals
import VettIDData

/// What the Approvals screens say about a request, from its kind and fields, in vettid-android's words
/// (`ApprovalsScreen.kt`'s `titleOf`, `whoOf`, `summaryOf`, `bodyOf`, `approveLabel`). [name] is the requesting
/// connection's "First Last" when there is one. Kept free of SwiftUI so that the tests read them on any platform.
enum ApprovalTexts {
    /// The kind of request, as a row title; a challenge with a purpose (§10.4, 0.65.0) names [name] in it.
    static func title(_ a: PendingApproval, name: String? = nil) -> String {
        switch a {
        case .authentication(let x) where x.purpose == .signin:
            ApprovalsStrings.authSigninTitle(AccountNames.isolateOrNull(name) ?? ApprovalsStrings.aConnectionInline)
        case .authentication(let x) where x.purpose == .approval:
            ApprovalsStrings.authApprovalTitle(AccountNames.isolateOrNull(name) ?? ApprovalsStrings.aConnection)
        case .connection(.incoming(let r)): r.remote ? ApprovalsStrings.typeConnectionRemote : ApprovalsStrings.typeConnection
        case .connection(.outgoing): ApprovalsStrings.typeOutgoing
        case .authentication: ApprovalsStrings.typeAuthentication
        case .grant: ApprovalsStrings.typeGrant
        case .critical: ApprovalsStrings.typeCritical
        case .share: ApprovalsStrings.typeShare
        case .device(let d): d.type == "device.session.pending" ? ApprovalsStrings.typeSession : ApprovalsStrings.typeDevice
        }
    }

    /// Who asks: the request's name, the connection, the device, or an agent; received names cleaned (§10.8).
    static func who(_ a: PendingApproval, name: String?) -> String? {
        switch a {
        case .connection(let r): AccountNames.cleaned(r.name) ?? ApprovalsStrings.nameNotShared
        case .device(let d): AccountNames.cleaned(d.deviceName)
        case .share(let s): name ?? (s.subjectAgentID != nil ? ApprovalsStrings.anAgent : nil)
        default: name ?? ApprovalsStrings.aConnection
        }
    }

    /// The row's second part: the safety code and where the request stands, the count of items, the critical item.
    static func summary(_ a: PendingApproval) -> String? {
        switch a {
        case .connection(.incoming(let r)) where r.state == .approved: ApprovalsStrings.summaryWaitingPeer(r.sas)
        case .connection(.incoming(let r)): ApprovalsStrings.summarySas(r.sas)
        case .connection(.outgoing(let r)):
            r.sas.map { r.state == .approved ? ApprovalsStrings.summaryWaitingPeer($0) : ApprovalsStrings.summarySas($0) }
                ?? ApprovalsStrings.summaryHandshake
        case .authentication(let x): x.context.map(firstLine)
        case .grant(let g): ApprovalsStrings.summaryItems(g.entries.count)
        case .critical(let c): "\(c.itemName) · \(c.fieldLabel)"
        case .share(let s): ApprovalsStrings.summaryItems(s.items.count)
        case .device(let d): d.requestType
        }
    }

    /// The row's second line: who and the summary, joined, each bidi-isolated (§10.8) since either can come from the
    /// other side.
    static func supporting(_ a: PendingApproval, name: String?) -> String {
        [who(a, name: name), summary(a)].compactMap { AccountNames.isolateOrNull($0) }.joined(separator: " · ")
    }

    /// A challenge's note on its screen: the connection's own words in full (lines kept, isolated, §10.4); without them,
    /// a `signin` or `approval` challenge says no details were given, and one without a purpose shows nothing.
    static func contextNote(_ x: AuthenticationRequest) -> String? {
        x.context.flatMap(AuthContext.isolated) ?? (x.purpose == .absent ? nil : ApprovalsStrings.authNoDetails)
    }

    /// [s] cleaned (``AuthContext/plain(_:)``), from its first visible line up to the next line break: a row shows one line.
    static func firstLine(_ s: String) -> String {
        String(AuthContext.plain(s).drop { $0.isWhitespace }.prefix { !$0.isNewline })
    }

    /// The decision screen's body. An `approval` challenge has none: its title says who asks, and its note follows in full
    /// (chosen; not in the spec).
    static func body(_ a: PendingApproval, name: String?) -> String? {
        let conn = AccountNames.isolateOrNull(name) ?? ApprovalsStrings.aConnection
        switch a {
        case .authentication(let x) where x.purpose == .signin: return ApprovalsStrings.authSigninBody
        case .authentication(let x) where x.purpose == .approval: return nil
        case .connection(.incoming(let r)):
            let n = AccountNames.isolateOrNull(r.name) ?? ApprovalsStrings.someone
            return r.remote ? ApprovalsStrings.connectionBodyRemote(n) : ApprovalsStrings.connectionBody(n)
        case .connection(.outgoing(let r)):
            guard r.sas != nil else { return ApprovalsStrings.outgoingWaiting }
            let n = AccountNames.isolateOrNull(r.name) ?? ApprovalsStrings.them
            return r.remote ? ApprovalsStrings.outgoingBodyRemote(n) : ApprovalsStrings.outgoingBody(n)
        case .authentication: return ApprovalsStrings.authBody(conn)
        case .grant: return ApprovalsStrings.grantBody(conn)
        case .critical: return ApprovalsStrings.criticalBody(conn)
        case .share(let s):
            let fallback = s.subjectAgentID != nil ? ApprovalsStrings.anAgent : ApprovalsStrings.aConnection
            return ApprovalsStrings.shareBody(AccountNames.isolateOrNull(name) ?? fallback)
        case .device: return ApprovalsStrings.deviceBody
        }
    }

    /// The approve button's label; nil where there is nothing to approve (a request already approved, a device's).
    static func approveLabel(_ a: PendingApproval) -> String? {
        switch a {
        case .connection(.incoming(let r)): r.state == .pending ? ApprovalsStrings.connectionApprove : nil
        case .connection(.outgoing(let r)): r.state == .pending && r.sas != nil ? ApprovalsStrings.outgoingApprove : nil
        case .authentication(let x): x.purpose == .absent ? ApprovalsStrings.authApprove : ApprovalsStrings.authPurposeApprove
        case .grant: ApprovalsStrings.grantApprove
        case .critical: ApprovalsStrings.criticalApprove
        case .share: ApprovalsStrings.shareApprove
        case .device: nil
        }
    }

    /// The deny button's label: "Not me" for a sign-in (§10.4), which declines it as "Deny" does.
    static func denyLabel(_ a: PendingApproval) -> String {
        switch a {
        case .share: ApprovalsStrings.shareDecline
        case .authentication(let x) where x.purpose == .signin: ApprovalsStrings.authSigninDeny
        default: ApprovalsStrings.deny
        }
    }

    /// A requester's name inside a sentence (bidi-isolated, §10.8), or "them".
    static func them(_ name: String?) -> String { AccountNames.isolateOrNull(name) ?? ApprovalsStrings.them }

    /// A refusal in words: a named limit (§10.1) says which; a password backoff counts down to [retryUntil] at [now].
    static func failure(_ kind: FailureKind, retryUntil: Date?, limit: VaultLimit?, now: Date, timeScale: UInt64 = 1) -> String {
        if kind == .limit, let limit { return limit.message }
        guard kind == .backoff, let retryUntil else { return kind.message(timeScale: timeScale) }
        let left = Int(max(0, retryUntil.timeIntervalSince(now)).rounded(.up))
        return left > 0 ? ApprovalsStrings.backoff(left) : ApprovalsStrings.backoffOver
    }

    /// What a critical-item use came to (§10.13 `status`).
    static func criticalResult(_ status: String, name: String?) -> (title: String, body: String) {
        switch status {
        case "ok": (ApprovalsStrings.criticalDoneTitle, ApprovalsStrings.criticalDoneBody(them(name)))
        case "unsuitable": (ApprovalsStrings.criticalFailedTitle, ApprovalsStrings.criticalUnsuitable)
        default: (ApprovalsStrings.criticalFailedTitle, ApprovalsStrings.criticalUnavailable)
        }
    }

    /// A field kind in the member's words (§10.7 kinds).
    static func kind(_ k: String) -> String { // swiftlint:disable:this cyclomatic_complexity
        switch k {
        case "password": ApprovalsStrings.kindPassword
        case "text": ApprovalsStrings.kindText
        case "multiline": ApprovalsStrings.kindMultiline
        case "number": ApprovalsStrings.kindNumber
        case "date": ApprovalsStrings.kindDate
        case "email": ApprovalsStrings.kindEmail
        case "phone": ApprovalsStrings.kindPhone
        case "url": ApprovalsStrings.kindUrl
        case "otp": ApprovalsStrings.kindOtp
        case "address": ApprovalsStrings.kindAddress
        default: ApprovalsStrings.kindOther
        }
    }

    static func operation(_ op: String) -> String { op == "auth" ? ApprovalsStrings.operationAuth : ApprovalsStrings.operationSign }

    /// A grant entry's line: a category the member answers, a named item, or one missing from the vault.
    static func grantEntry(_ e: GrantEntry) -> String {
        if e.kind == "category" { return ApprovalsStrings.grantCategory(AccountNames.isolateOrNull(e.label) ?? humanize(e.ref)) }
        if e.available, let n = AccountNames.isolateOrNull(e.name) { return n }
        return ApprovalsStrings.grantItemMissing(AccountNames.isolateOrNull(e.label) ?? AccountNames.isolate(e.ref))
    }

    /// A category identifier in words: underscores as spaces, the first letter capitalized (chosen; not in the spec: the
    /// categories' names come with the Vault screens, IOS-PLAN §8 I3.1).
    static func humanize(_ id: String) -> String {
        let s = id.replacingOccurrences(of: "_", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// One explanation line of a share question's item, in the member's words (§10.12, rules named by their tags); a rule the
    /// question does not know reads "another of your rules".
    static func shareLine(
        _ line: ShareExplanations.Line, in d: ShareDecision, names: [String: RuleNames.Name], who: String, zone: TimeZone = .current
    ) -> String {
        let id: String? = switch line {
        case .asksFirst(let id), .alsoCovered(let id): id
        case .alreadyShared: nil
        }
        let named = id.flatMap { id in d.rules.first { $0.ruleID == id } }.map { ruleNamed($0, names: names, zone: zone) }
            ?? ApprovalsStrings.anotherRule
        switch line {
        case .asksFirst: return ApprovalsStrings.shareAlsoAsks(named)
        case .alsoCovered: return ApprovalsStrings.shareAlso(named)
        case .alreadyShared: return ApprovalsStrings.shareAlready(who)
        }
    }

    /// "your “medical” rule" (§10.12: a rule is named by its tags), told apart when two of the subject read the same.
    static func ruleNamed(_ r: ShareRule, names: [String: RuleNames.Name], zone: TimeZone = .current) -> String {
        let n = names[r.ruleID] ?? RuleNames.Name(text: RuleNames.text(r))
        switch n.qualifier {
        case nil: return ApprovalsStrings.ruleName(n.text)
        case .mode(let m)?: return m == .ask ? ApprovalsStrings.ruleNameAsks(n.text) : ApprovalsStrings.ruleNameAuto(n.text)
        case .ends(let at)?:
            let day = { (d: Date) in d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: zone)) }
            return at.map { ApprovalsStrings.ruleNameUntil(n.text, day($0)) } ?? ApprovalsStrings.ruleNameNoEnd(n.text)
        }
    }

    static let day = 86_400
    /// §10.12: a one-off grant lasts 7 days unless the request says otherwise.
    static let defaultGrantSeconds = 7 * day

    /// The uses offered: the request's (nil), 1, 3, 10, each value once.
    static func usesOptions(requested: Int?) -> [Int?] {
        distinct([nil, 1, 3, 10]) { $0 ?? (requested ?? 1) }
    }

    /// The lifetimes offered: the request's (nil), a day, a week, 30 days, each value once.
    static func expiryOptions(requested: Int?) -> [Int?] {
        distinct([nil, day, 7 * day, 30 * day]) { $0 ?? (requested ?? defaultGrantSeconds) }
    }

    static func usesLabel(_ u: Int?, requested: Int?) -> String { ApprovalsStrings.grantUses(u ?? requested ?? 1) }

    static func expiryLabel(_ x: Int?, requested: Int?) -> String {
        ApprovalsStrings.grantDays(max(1, (x ?? requested ?? defaultGrantSeconds) / day))
    }

    private static func distinct(_ values: [Int?], by key: (Int?) -> Int) -> [Int?] {
        var seen = Set<Int>()
        return values.filter { seen.insert(key($0)).inserted }
    }

    /// "<First>'s requests are paused", or without a name.
    static func pausedTitle(_ c: ConnectionInfo) -> String {
        AccountNames.isolateOrNull(c.displayName).map(ApprovalsStrings.pausedTitle) ?? ApprovalsStrings.pausedTitleUnnamed
    }

    static func removeTitle(_ c: ConnectionInfo) -> String {
        ApprovalsStrings.removeTitle(AccountNames.isolateOrNull(c.displayName) ?? ApprovalsStrings.aConnection)
    }

    /// The other member's decline (0.10.5): the accepter "<name> declined your connection request", the inviter "<name>
    /// declined the connection".
    static func peerDeclined(_ d: PeerDecline) -> String {
        let name = AccountNames.isolateOrNull(d.name) ?? ApprovalsStrings.peerDeclinedSomeone
        return d.outgoing ? ApprovalsStrings.peerDeclinedOutgoing(name) : ApprovalsStrings.peerDeclinedIncoming(name)
    }

    static func batchTitle(asks: Int, name: String?) -> String {
        ApprovalsStrings.batchTitle(AccountNames.isolateOrNull(name) ?? ApprovalsStrings.aConnection, asks)
    }
}
