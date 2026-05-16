import Foundation
import CryptoKit

// MARK: - Audit Chain Verifier

/// Verifies the vault's audit log signatures + hash chain client-side.
///
/// Parity with Android `AuditChainVerifier`. See
/// `vettid-dev/docs/audit-chain-verification.md`.
///
/// Trust model:
///   - The user's identity public key is the trust anchor (already held;
///     it's the same key that signs profiles, votes, contracts).
///   - The audit log's `binding_sig` is identity_priv's signature over
///     `"vettid-audit-binding-v1" || audit_pub`. Verifying this against
///     identity_pub proves audit_pub is bound to the user — even if an
///     attacker recovered audit_priv they couldn't forge the binding.
///   - Each row carries `entry_sig` = ed25519_sign(audit_priv, entry_hash).
///     Verifying against audit_pub proves the row was written by the
///     audit key (and thus by the vault while it had the identity key).
///   - `entry_hash` is deterministic over (previous_hash, event_id,
///     event_type, source_id, encrypted_payload, created_at). Walking
///     the chain catches insertion / deletion / reorder of any row.
///
/// The vault sends encrypted_payload as part of the chain input, but the
/// client doesn't have the DEK to recompute the payload locally — so the
/// client trusts the vault's reported `entry_hash` and only checks the
/// signature + the chain linkage (prev_hash continuity). That's the
/// right tradeoff for a privacy-first system: the vault is the only
/// thing that can decrypt, so it's the only thing that *could* produce
/// a valid signature; we just have to confirm the signature is real and
/// the chain isn't reordered.
struct AuditChainVerifier {

    // MARK: - Result types

    /// Per-row verification verdict.
    enum RowState: String {
        /// Row predates the chain shipment or was written pre-PIN-unlock.
        case unsigned
        /// Signature verified against bound audit_pub; chain linkage intact.
        case verified
        /// Signature failed, chain broke, or audit_pub binding failed.
        case tampered
    }

    struct RowVerification: Equatable {
        let rowIndex: Int
        let state: RowState
        let reason: String?
    }

    /// Aggregate chain status surfaced as a screen-level pill.
    enum ChainStatus: Equatable {
        case empty
        case verified(signedRows: Int, unsignedRows: Int)
        case unsigned(rows: Int)
        case tampered(firstBadRowIndex: Int, reason: String)
    }

    /// Anchor delivered alongside the audit query response. All three
    /// strings are base64; `identityPubB64` is the user's Ed25519
    /// identity public key (32 bytes raw). Empty/nil when the vault
    /// hasn't shipped the chain anchor yet for this session.
    struct ChainAnchor: Equatable {
        let auditPubB64: String?
        let bindingSigB64: String?
        let identityPubB64: String?

        var isPresent: Bool {
            (auditPubB64?.isEmpty == false)
                && (bindingSigB64?.isEmpty == false)
                && (identityPubB64?.isEmpty == false)
        }

        static let empty = ChainAnchor(
            auditPubB64: nil,
            bindingSigB64: nil,
            identityPubB64: nil
        )
    }

    // MARK: - Verification entry point

    private static let bindingDomain = "vettid-audit-binding-v1"

    /// Verify a list of rows in newest-first order (the natural query
    /// shape). The chain check walks oldest → newest, so the input
    /// is reversed internally.
    ///
    /// - Parameters:
    ///   - rows: rows from the vault response, newest-first
    ///   - anchor: response-level chain anchor (audit_pub, binding_sig, identity_pub, b64)
    ///   - entryHashOf: function returning (entryHash, prevHash, entrySig)
    ///                  for one row. Hex-encoded strings; nil/empty for
    ///                  pre-chain legacy rows.
    /// - Returns: (per-row verifications in original newest-first order, overall ChainStatus)
    static func verifyChain<T>(
        rows: [T],
        anchor: ChainAnchor,
        entryHashOf: (T) -> (entryHash: String?, prevHash: String?, entrySig: String?)
    ) -> (perRow: [RowVerification], chain: ChainStatus) {
        guard !rows.isEmpty else {
            return ([], .empty)
        }

        let auditPubData = anchor.auditPubB64.flatMap(decodeBase64Safe)
        let bindingSig   = anchor.bindingSigB64.flatMap(decodeBase64Safe)
        let identityPub  = anchor.identityPubB64.flatMap(decodeBase64Safe)

        // Binding verification: identity_pub must have signed
        // ("vettid-audit-binding-v1" || audit_pub).
        let anchorVerified: Bool = {
            guard let audit = auditPubData,
                  let sig = bindingSig,
                  let identity = identityPub else { return false }
            let message = Data(Self.bindingDomain.utf8) + audit
            return verifyEd25519(publicKey: identity, message: message, signature: sig)
        }()

        if !anchorVerified {
            let perRow = (0..<rows.count).map {
                RowVerification(rowIndex: $0, state: .unsigned, reason: "no verified audit anchor")
            }
            let anyChainRow = rows.contains { entryHashOf($0).entryHash?.isEmpty == false }
            return (perRow, anyChainRow ? .unsigned(rows: rows.count) : .empty)
        }

        // Walk oldest → newest so prev_hash continuity is checkable.
        let orderedOldFirst = Array(rows.reversed())
        var perRow = Array(repeating: RowVerification(rowIndex: 0, state: .unsigned, reason: nil),
                           count: rows.count)
        for i in 0..<rows.count {
            perRow[i] = RowVerification(rowIndex: i, state: .unsigned, reason: nil)
        }
        var prevHash: String? = nil
        var signedCount = 0
        var unsignedCount = 0

        for (idxOld, row) in orderedOldFirst.enumerated() {
            let triple = entryHashOf(row)
            let entryHash = triple.entryHash
            let prevHashReported = triple.prevHash
            let entrySig = triple.entrySig
            let newestFirstIdx = rows.count - 1 - idxOld

            // Pre-chain legacy row. Neither Verified nor Tampered —
            // the chain just doesn't exist for this row.
            if (entryHash?.isEmpty ?? true) && (entrySig?.isEmpty ?? true) {
                perRow[newestFirstIdx] = RowVerification(
                    rowIndex: newestFirstIdx,
                    state: .unsigned,
                    reason: "no chain fields"
                )
                unsignedCount += 1
                continue
            }

            // Chain linkage: prevHashReported should match the previous
            // row's entry_hash (or be empty for the oldest row on
            // this page — we don't require explicit "genesis" since
            // the chain can extend earlier than the received page).
            if let prev = prevHash,
               let reported = prevHashReported, !reported.isEmpty,
               reported != prev {
                let chain = ChainStatus.tampered(
                    firstBadRowIndex: newestFirstIdx,
                    reason: "previous_hash mismatch at row \(newestFirstIdx)"
                )
                perRow[newestFirstIdx] = RowVerification(
                    rowIndex: newestFirstIdx,
                    state: .tampered,
                    reason: "previous_hash mismatch"
                )
                // Mark all newer rows as suspect — they're downstream
                // of the first tampered row so the screen pill reflects
                // the earliest break.
                for j in 0..<newestFirstIdx {
                    perRow[j] = RowVerification(
                        rowIndex: j,
                        state: .tampered,
                        reason: "downstream of tampered row"
                    )
                }
                return (perRow, chain)
            }

            // Signature check: entry_sig should be a valid Ed25519
            // signature over entry_hash by audit_pub.
            if let sig = entrySig, !sig.isEmpty, let audit = auditPubData {
                let sigBytes = hexDecode(sig)
                let msgBytes = Data((entryHash ?? "").utf8)
                if verifyEd25519(publicKey: audit, message: msgBytes, signature: sigBytes) {
                    perRow[newestFirstIdx] = RowVerification(
                        rowIndex: newestFirstIdx,
                        state: .verified,
                        reason: nil
                    )
                    signedCount += 1
                } else {
                    let chain = ChainStatus.tampered(
                        firstBadRowIndex: newestFirstIdx,
                        reason: "entry_sig invalid at row \(newestFirstIdx)"
                    )
                    perRow[newestFirstIdx] = RowVerification(
                        rowIndex: newestFirstIdx,
                        state: .tampered,
                        reason: "entry_sig invalid"
                    )
                    for j in 0..<newestFirstIdx {
                        perRow[j] = RowVerification(
                            rowIndex: j,
                            state: .tampered,
                            reason: "downstream of tampered row"
                        )
                    }
                    return (perRow, chain)
                }
            } else {
                perRow[newestFirstIdx] = RowVerification(
                    rowIndex: newestFirstIdx,
                    state: .unsigned,
                    reason: "no entry_sig"
                )
                unsignedCount += 1
            }

            prevHash = entryHash
        }

        let chain: ChainStatus
        if signedCount > 0 {
            chain = .verified(signedRows: signedCount, unsignedRows: unsignedCount)
        } else if unsignedCount > 0 {
            chain = .unsigned(rows: unsignedCount)
        } else {
            chain = .empty
        }
        return (perRow, chain)
    }

    // MARK: - Crypto

    /// CryptoKit-backed Ed25519 verification. `publicKey` must be the
    /// raw 32-byte form. Signatures are 64 bytes raw.
    private static func verifyEd25519(publicKey: Data, message: Data, signature: Data) -> Bool {
        guard publicKey.count == 32, signature.count == 64 else { return false }
        do {
            let pub = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            return pub.isValidSignature(signature, for: message)
        } catch {
            return false
        }
    }

    // MARK: - Encoding helpers

    /// Tolerant base64 decoder: tries standard padded base64, then
    /// URL-safe with padding restored.
    private static func decodeBase64Safe(_ s: String) -> Data? {
        if let d = Data(base64Encoded: s) { return d }
        var padded = s.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        let pad = padded.count % 4
        if pad > 0 { padded += String(repeating: "=", count: 4 - pad) }
        return Data(base64Encoded: padded)
    }

    /// Hex decoder. Returns empty Data on any malformed input — the
    /// signature check will then fail length validation and return false,
    /// surfacing as a `tampered` row.
    private static func hexDecode(_ hex: String) -> Data {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        guard cleaned.count % 2 == 0 else { return Data() }
        var out = Data(capacity: cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let byte = UInt8(cleaned[idx..<next], radix: 16) else {
                return Data()
            }
            out.append(byte)
            idx = next
        }
        return out
    }
}

// MARK: - ChainStatus surface helpers

extension AuditChainVerifier.ChainStatus {

    /// Short pill label rendered at the top of the audit log surface.
    var pillTitle: String {
        switch self {
        case .empty:
            return "No chain"
        case .verified(let signed, let unsigned):
            if unsigned == 0 { return "Chain verified" }
            return "Chain verified (\(signed) signed, \(unsigned) unsigned)"
        case .unsigned(let rows):
            return "Unsigned (\(rows))"
        case .tampered:
            return "Chain tampered"
        }
    }

    var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    var isTampered: Bool {
        if case .tampered = self { return true }
        return false
    }
}
