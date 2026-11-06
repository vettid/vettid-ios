import Foundation
import VettIDCrypto
import VettIDVault

/// The rows a `vote.results.submit` carries (VAULT-MESSAGING 0.83.6 §10.19.8): the member's row and up to four more under
/// its tag, or none (`rows_unavailable`).
struct SubmittedRows: Sendable {
    let own: OwnRow?
    let others: [OwnRow]

    /// The member's row cannot be had (§10.19.6 step 1).
    static let unavailable = SubmittedRows(own: nil, others: [])

    var isUnavailable: Bool { own == nil }

    func with(others: [OwnRow]) -> SubmittedRows { SubmittedRows(own: own, others: others) }
}

/// `vote.results.submit`'s body (VAULT-MESSAGING 0.83.6 §10.19.8): the site's results as the standard base64 of their exact
/// bytes, and either the member's row (its choice included: a receipt cannot be checked without it) with its proof and
/// `other_rows` when there are more rows under its tag, or `rows_unavailable: true` and no row. Every ballot carries `pad`
/// (§10.19.5); nothing reads one back.
enum ResultsBody {
    /// Nil when the member's own row is not what the vault reads (a key of other than 32 bytes, a signature of other than 64,
    /// a choice id of other than `[a-z0-9-]{1,32}`): it would refuse the whole call. The extra rows are sent as published,
    /// whatever their lengths: the vault judges a second row under the tag whatever its choice id (§10.19.6 step 3), and an
    /// entry the app cannot make into a leaf never gets here.
    static func build(_ key: VoteKey, doc: [UInt8], sig: [UInt8], bundle: String, rows: SubmittedRows) -> [UInt8]? {
        var body = JsonBuilder().string("connection_id", key.connectionID).string("proposal_id", key.proposalID)
            .base64("results", doc).base64("results_sig", sig).raw("bundle", bundle)
        guard let own = rows.own else { return body.bool("rows_unavailable", true).bytes() }
        guard let row = rowJSON(own, strict: true) else { return nil }
        body = body.raw("row", row.build()).raw("row_proof", proofJSON(own).build())
        if !rows.others.isEmpty {
            var entries: [String] = []
            for other in rows.others {
                guard let r = rowJSON(other, strict: false) else { return nil }
                entries.append(JsonBuilder().raw("row", r.build()).raw("proof", proofJSON(other).build()).build())
            }
            body = body.raw("other_rows", JsonBuilder.array(entries))
        }
        return body.bytes()
    }

    /// `{"ballot": null}` for an empty row, else the ballot with its `pad`. [strict]: the member's own row, which must be
    /// what the vault reads.
    private static func rowJSON(_ r: OwnRow, strict: Bool) -> JsonBuilder? {
        let row = JsonBuilder()
        guard let b = r.ballot else { return row.raw("ballot", "null") }
        guard let vk = try? b.string("vk"), let choice = try? b.string("choice_id"), let sig = try? b.string("ballot_sig") else {
            return nil
        }
        if strict {
            guard (try? Base64s.decodeStd(vk, 32)) != nil, (try? Base64s.decodeStd(sig, VoteSiteLimits.sigLength)) != nil,
                  validChoice(choice)
            else { return nil }
        } else {
            guard (try? b.base64("vk")) != nil, (try? b.base64("ballot_sig")) != nil else { return nil }
        }
        let ballot = JsonBuilder().string("vk", vk).string("choice_id", choice).string("ballot_sig", sig)
            .string("pad", VotePad.of(choice))
        return row.raw("ballot", ballot.build())
    }

    private static func proofJSON(_ r: OwnRow) -> JsonBuilder {
        JsonBuilder().uint("index", r.index).uint("tree_size", r.treeSize)
            .raw("path", JsonBuilder.array(r.path.map { JsonBuilder.quote(Base64s.encodeStd($0)) }))
    }

    static func validChoice(_ s: String) -> Bool {
        (1...32).contains(s.utf8.count) && s.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
    }

    /// [rows] with its extra rows dropped one by one, the largest first, until the body of it is accepted by [fits]; at
    /// least one extra row is kept (one verifying extra row is enough for the vault's `row_duplicate`, a signed contradiction
    /// stronger than `rows_unavailable`). Nil when none fits (or there were none).
    static func fewer(_ rows: SubmittedRows, fits: ([UInt8]) -> Bool, body: (SubmittedRows) -> [UInt8]?) -> SubmittedRows? {
        var kept = rows.others
        while kept.count > 1 {
            guard let largest = kept.indices.max(by: { size(kept[$0]) < size(kept[$1]) }) else { break }
            kept.remove(at: largest)
            let fewer = rows.with(others: kept)
            if let b = body(fewer), fits(b) { return fewer }
        }
        return nil
    }

    private static func size(_ r: OwnRow) -> Int { (rowJSON(r, strict: false)?.build().utf8.count ?? 0) + r.path.count * 44 }
}
