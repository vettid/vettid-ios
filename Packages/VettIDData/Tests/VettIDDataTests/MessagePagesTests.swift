import Foundation
import Testing
@testable import VettIDData

/// Merging `message.list` pages (VAULT-MESSAGING 0.32.0 §10.5.2): vettid-android `MessagePagesTest`, case for case.
@Suite struct MessagePagesTests {
    func m(_ n: Int) -> MessageInfo {
        MessageInfo(
            connectionID: "c1", messageID: String(format: "m%02d", n), outgoing: n % 2 == 0, text: "t\(n)",
            sentAt: Date(timeIntervalSince1970: 1_000 + Double(n))
        )
    }

    func ms(_ r: some Sequence<Int>) -> [MessageInfo] { r.map(m) }

    func ids(_ l: [MessageInfo]) -> [Int] { l.compactMap { Int($0.messageID.dropFirst()) } }

    @Test func theFirstNewestPageAnnouncesOlderMessages() {
        let r = MessagePages.newest(ms(6...10), nextBefore: "m06", current: [], paging: MessagePaging())
        #expect(ids(r.messages) == Array(6...10))
        #expect(r.paging.nextBefore == "m06" && r.paging.hasOlder && !r.paging.olderLoaded)
    }

    @Test func anOlderPageIsAddedAtTheTop() {
        let first = MessagePages.newest(ms(6...10), nextBefore: "m06", current: [], paging: MessagePaging())
        let r = MessagePages.older(ms(1...5), nextBefore: nil, current: first.messages)
        #expect(ids(r.messages) == Array(1...10))
        #expect(r.paging.nextBefore == nil && r.paging.olderLoaded)
    }

    @Test func reloadingTheNewestPageKeepsTheOlderPagesItJoins() {
        let first = MessagePages.newest(ms(6...10), nextBefore: "m06", current: [], paging: MessagePaging())
        let older = MessagePages.older(ms(3...5), nextBefore: "m03", current: first.messages)
        // Two new messages since; message 8 was deleted on another device; 9 is now read.
        let page = ms([7, 9, 10, 11, 12]).map { x in
            var y = x
            if x.messageID == "m09" { y.read = true }
            return y
        }
        let r = MessagePages.newest(page, nextBefore: "m07", current: older.messages, paging: older.paging)
        #expect(ids(r.messages) == [3, 4, 5, 6, 7, 9, 10, 11, 12])
        #expect(r.messages.first { $0.messageID == "m09" }?.read == true)
        #expect(r.paging.nextBefore == "m03", "the scrolled position is kept")
        #expect(r.paging.olderLoaded)
    }

    @Test func aNewestPageThatDoesNotJoinDropsTheOlderPagesRatherThanLeaveAHole() {
        let first = MessagePages.newest(ms(6...10), nextBefore: "m06", current: [], paging: MessagePaging())
        let older = MessagePages.older(ms(3...5), nextBefore: "m03", current: first.messages)
        let r = MessagePages.newest(ms(20...24), nextBefore: "m20", current: older.messages, paging: older.paging)
        #expect(ids(r.messages) == Array(20...24))
        #expect(r.paging.nextBefore == "m20" && !r.paging.olderLoaded)
    }

    @Test func messagesArrivedMeanwhileStay() {
        let r = MessagePages.newest(ms(6...10), nextBefore: "m06", current: ms(6...12), paging: MessagePaging())
        #expect(ids(r.messages) == Array(6...12))
    }

    @Test func aWholeHistoryInOnePageHasNothingOlder() {
        let r = MessagePages.newest(ms(1...4), nextBefore: nil, current: [], paging: MessagePaging())
        #expect(!r.paging.hasOlder)
        let empty = MessagePages.newest([], nextBefore: nil, current: [], paging: MessagePaging())
        #expect(empty.messages.isEmpty && !empty.paging.hasOlder)
    }

    @Test func anOlderPageDoesNotDuplicateWhatIsShown() {
        let r = MessagePages.older(ms(4...6), nextBefore: "m04", current: ms(6...8))
        #expect(ids(r.messages) == Array(4...8))
    }

    @Test func pagesJoinByTheVaultsOrderNotTheSendersClock() {
        // Message 30 arrived last but its sender's clock was behind: it was appended (arrival order), and it stays after
        // the page, where it arrived.
        var late = m(30)
        late.sentAt = Date(timeIntervalSince1970: 1)
        let r = MessagePages.newest(ms(6...10), nextBefore: "m06", current: ms(6...10) + [late], paging: MessagePaging())
        #expect(ids(r.messages) == [6, 7, 8, 9, 10, 30])
    }

    /// (Not in vettid-android's test.) An empty newest page (every message deleted) keeps what arrived since and forgets
    /// the position; a reload whose page lost a message keeps no copy of it.
    @Test func anEmptyNewestPageAndADeletionInThePage() {
        let scrolled = MessagePaging(nextBefore: "m01", olderLoaded: true)
        let empty = MessagePages.newest([], nextBefore: nil, current: ms(1...3), paging: scrolled)
        #expect(ids(empty.messages) == [1, 2, 3] && empty.paging == MessagePaging())
        let r = MessagePages.newest(ms([1, 3]), nextBefore: nil, current: ms(1...3), paging: MessagePaging())
        #expect(ids(r.messages) == [1, 3])
    }
}
