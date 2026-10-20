import Foundation

/// Where a conversation's loaded history stands (VAULT-MESSAGING 0.32.0 §10.5.2): [nextBefore] the `before` of the next
/// older page, nil when the start of the conversation is loaded (or nothing older was announced); [olderLoaded] whether
/// at least one older page was merged in, so that a reload of the newest page keeps it. Mirrors vettid-android
/// `MessagePaging`.
struct MessagePaging: Equatable, Sendable {
    var nextBefore: String?
    var olderLoaded = false

    var hasOlder: Bool { nextBefore != nil }
}

/// A conversation after a page was merged.
struct PagedMessages: Equatable, Sendable {
    var messages: [MessageInfo]
    var paging: MessagePaging
}

/// Merging pages of `message.list` into what the conversation shows (vettid-android `MessagePages`). The vault's page
/// wins over the range it covers (deletions and receipts included); messages that arrived meanwhile, newer than the
/// page's newest, are kept; and older pages the member scrolled to stay when the newest page is loaded again, as long as
/// the new page joins them (its oldest message is among them). A page that does not join them (more new messages arrived
/// than a page holds) drops them and continues from the page's own `next_before`, so that the list never has a hole.
enum MessagePages {
    /// The newest page ([page] oldest first, [nextBefore] as the vault answered) over [current] and its [paging]. Pages
    /// are joined by the vault's order (a message's position), never by `sent_at`, which is the sender's clock: what
    /// [current] holds before the page's first message is older, what it holds after the page's last one arrived since.
    static func newest(
        _ page: [MessageInfo], nextBefore: String?, current: [MessageInfo], paging: MessagePaging
    ) -> PagedMessages {
        let ids = Set(page.map(\.messageID))
        let firstAt = page.first.flatMap { f in current.firstIndex { $0.messageID == f.messageID } }
        // The last position in [current] of any message of the page (one deleted meanwhile is simply not in it).
        let lastAt = current.lastIndex { ids.contains($0.messageID) }
        guard !page.isEmpty else { return PagedMessages(messages: current, paging: MessagePaging()) }
        let arrived = lastAt.map { Array(current[($0 + 1)...]) } ?? []
        guard let nextBefore else {
            return PagedMessages(messages: page + arrived, paging: MessagePaging(nextBefore: nil, olderLoaded: paging.olderLoaded))
        }
        guard paging.olderLoaded, let firstAt else {
            return PagedMessages(messages: page + arrived, paging: MessagePaging(nextBefore: nextBefore))
        }
        let older = current[..<firstAt].filter { !ids.contains($0.messageID) }
        return PagedMessages(messages: older + page + arrived, paging: paging)
    }

    /// An older page ([page] oldest first, answered for `before` = ``MessagePaging/nextBefore``) put before [current].
    static func older(_ page: [MessageInfo], nextBefore: String?, current: [MessageInfo]) -> PagedMessages {
        let have = Set(current.map(\.messageID))
        return PagedMessages(
            messages: page.filter { !have.contains($0.messageID) } + current,
            paging: MessagePaging(nextBefore: nextBefore, olderLoaded: true)
        )
    }
}
