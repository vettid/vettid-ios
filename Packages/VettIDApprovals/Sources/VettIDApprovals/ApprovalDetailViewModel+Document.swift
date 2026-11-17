import Foundation
import VettIDData

/// The approval screen's document (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents"): fetched and checked when the screen
/// first holds the request, shown, approvable once it has all been on screen, and approved only over itself.
extension ApprovalDetailViewModel {
    /// A member authentication that carries a document (0.89.0 §10.4): it is fetched and checked when the screen first
    /// holds the request, and again if the request it holds comes to name another document than the one shown.
    func loadDocument() {
        guard case .authentication(let x)? = local.approval, x.hasDocument else { return }
        // Fetched once for the hash the request names, and again whenever it names another (from any state but a fetch on
        // its way, which looks again once it is answered).
        if local.document == .loading || (local.document != nil && local.documentFor == x.documentSha256) { return }
        local.documentFor = x.documentSha256
        local.document = .loading
        // The password field goes while there is nothing to approve; it does not come back filled.
        local.password = ""
        let repo = repo
        work.launch { [weak self] in
            do {
                let checked = try await repo.authenticationDocument(x)
                self?.show(checked, context: x.context)
            } catch {
                self?.local.document = .failed(failureKind(error))
            }
            // The request may have come to name another document meanwhile.
            self?.loadDocument()
        }
    }

    /// [checked] in place of whatever document the screen showed: it is shown from the start, not yet seen whole.
    func show(_ checked: Result<ApprovalDocument, ApprovalDocument.Failure>, context: String?) {
        local.documentSeen = nil
        local.documentGeneration += 1
        switch checked {
        case .success(let d):
            local.document = DocumentPresentation(d, context: context).map { .shown(d, $0) } ?? .unshowable(.shape)
        case .failure(let f): local.document = .unshowable(f)
        }
    }

    /// The document's fetch failed: Try again.
    public func retryDocument() {
        guard case .failed? = local.document else { return }
        local.document = nil
        local.documentFor = nil
        loadDocument()
    }

    /// The screen has shown the whole of the document whose hash is [sha256], from its top to its end without a gap
    /// (``SeenCoverage``): Approve may be enabled, for that document only (a report about a document no longer shown
    /// counts for nothing).
    /// [generation]: the ``ApprovalDetailState/documentGeneration`` the screen showed it in; a report from an earlier
    /// showing counts for nothing either.
    public func documentShownWhole(_ sha256: String, generation: Int) {
        guard case .shown(let d, _)? = local.document, d.sha256 == sha256, generation == local.documentGeneration else { return }
        local.documentSeen = d.sha256
    }

    /// Decided from the request in hand, never from what the repository still holds: a challenge with a document is
    /// approved only over the document shown here, whole (§10.4: nowhere else, and never without it).
    func approveOverDocument(_ x: AuthenticationRequest, _ s: ApprovalDetailState, password: String) async throws {
        guard let d = s.documentToApprove else { throw VaultFailure(.other, code: Self.documentNotShown) }
        if case .changed(let again) = try await repo.approveAuthentication(x, password: password, document: d) {
            show(again, context: x.context)
            throw DocumentRestarted()
        }
    }

    /// The app's own refusal to approve a challenge with a document that is not shown whole (never sent to the vault).
    static let documentNotShown = "document_not_shown"
}

/// The approval found another document than the one shown (`document_not_fetched`, then other bytes): nothing was
/// approved and the screen shows what it has now from the start; no failure is said for it.
struct DocumentRestarted: Error {}
