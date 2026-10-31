import Foundation

/// Reads the documents of the public votes site for ``VoteSiteRunner``: a proposal with its signature, bundle and
/// extensions, the versions of the service list, a vote's results. Each read stops cancelled work. Everything is as the
/// site served it; what the vault would refuse a whole call for (VAULT-MESSAGING 0.81.6 §10.19.8; vettid-vault
/// `features/vote/sync.go`) is not passed on.
struct VoteSiteReader: Sendable {
    let site: any VoteSite

    /// A read of the site; cancelled work stops here.
    func get(_ path: String, _ max: Int) async throws -> SiteAnswer {
        try Task.checkCancellation()
        let answer = await site.get(path, maxBytes: max)
        try Task.checkCancellation()
        return answer
    }

    /// Version [v] of the service list as the site serves it (`services/<v>.json` and its signature); nil when it does not.
    func servedVersion(_ v: Int64) async throws -> VoteSync.ServedList? {
        guard case .found(let d) = try await get("services/\(v).json", VoteSiteLimits.listMax),
              case .found(let s) = try await get("services/\(v).json.sig", VoteSiteLimits.sigMax)
        else { return nil }
        return VoteSync.ServedList(doc: d, sig: s, version: v)
    }

    /// What one more document of a proposal came to.
    enum Part {
        case found([UInt8])
        /// A 404, or a document over the limit the vault takes.
        case missing
        /// The site could not answer.
        case down
    }

    func part(_ path: String, _ max: Int) async throws -> Part {
        switch try await get(path, max) {
        case .found(let b): .found(b)
        case .absent, .tooLarge: .missing
        case .unreachable: .down
        }
    }

    /// One proposal's documents from the site: `proposal.json` with its signature and bundle, and each extension in order.
    /// A 404 for the proposal is `absent` (sent again at the next run and when the screen opens), a 5xx or a timeout, and
    /// a proposal over the vault's 65,536 bytes, `unreachable`, an odd body `found`: the vault judges it. A bundle that is
    /// no strict JSON object (or too deep for its place in the request) is left out. The extensions are at most 24 and end
    /// at the first one over 4,096 bytes, without a signature of 64 bytes or without a bundle that is a strict object; the
    /// entry goes with those before it (VAULT-MESSAGING 0.81.6 §10.19.8 "Shape checks before sending"). An extension the
    /// site could not answer for makes the whole entry `unreachable` (the erratum is silent on it).
    func readDocument(_ id: String, index: String?) async throws -> VoteSync.Document {
        let p: [UInt8]
        switch try await get("p/\(id)/proposal.json", VoteSiteLimits.proposalMax) {
        case .absent: return .absent
        case .unreachable, .tooLarge: return .unreachable
        case .found(let b): p = b
        }
        guard let signed = try await signedParts(id) else { return .unreachable }
        let (sig, bundle) = (signed.sig, signed.bundle)
        var extensions: [VoteSync.Extension] = []
        let count = VoteSync.extendedOf(index).map { min(max($0, 0), VoteSync.maxExtensions) } ?? VoteSync.maxExtensions
        if count > 0 {
            for n in 1...count {
                switch try await readExtension(id, n) {
                case .down: return .unreachable
                case .stop: return .found(proposal: p, proposalSig: sig, bundle: bundle, extensions: extensions)
                case .read(let e): extensions.append(e)
                }
            }
        }
        return .found(proposal: p, proposalSig: sig, bundle: bundle, extensions: extensions)
    }

    /// The signature and the bundle of a proposal, each nil when missing; nil when the site could not answer.
    private func signedParts(_ id: String) async throws -> (sig: [UInt8]?, bundle: String?)? {
        var sig: [UInt8]?
        switch try await part("p/\(id)/proposal.json.sig", VoteSiteLimits.sigMax) {
        case .down: return nil
        case .found(let b): sig = b
        case .missing: break
        }
        var bundle: String?
        switch try await part("p/\(id)/proposal.json.sigstore.json", VoteSiteLimits.bundleMax) {
        case .down: return nil
        case .found(let b): bundle = VoteSync.compactObject(b, level: VoteSync.Level.proposalBundle)
        case .missing: break
        }
        return (sig, bundle)
    }

    enum ExtensionRead {
        case read(VoteSync.Extension)
        /// Not there, or not what the vault takes: the extensions end before it.
        case stop
        case down
    }

    /// Extension [n] of a proposal with its signature (exactly 64 bytes) and its bundle (an object), each as the vault
    /// takes it.
    func readExtension(_ id: String, _ n: Int) async throws -> ExtensionRead {
        let base = "p/\(id)/extension-\(n).json"
        let doc: [UInt8]
        switch try await part(base, VoteSiteLimits.extensionMax) {
        case .down: return .down
        case .missing: return .stop
        case .found(let b): doc = b
        }
        let sig: [UInt8]
        switch try await part(base + ".sig", VoteSiteLimits.sigMax) {
        case .down: return .down
        case .found(let b) where b.count == VoteSiteLimits.sigLength: sig = b
        case .found, .missing: return .stop
        }
        switch try await part(base + ".sigstore.json", VoteSiteLimits.bundleMax) {
        case .down: return .down
        case .found(let b):
            guard let bundle = VoteSync.compactObject(b, level: VoteSync.Level.extensionBundle) else { return .stop }
            return .read(VoteSync.Extension(doc, sig: sig, bundle: bundle))
        case .missing: return .stop
        }
    }

    /// A vote's results as the site serves them.
    struct ResultsFiles: Sendable {
        let doc: [UInt8]
        let sig: [UInt8]
        let bundle: [UInt8]
        let rows: [UInt8]
    }

    enum ResultsFetch: Sendable {
        case files(ResultsFiles)
        /// A document is over the limit the vault takes: a problem with the results, not a site that is down.
        case tooLarge
        /// The site could not be reached for one of them.
        case siteDown
        /// The site answered, and the results are not (all) there.
        case notPublished
    }

    /// The four documents of a vote's results from the site, or why there are not.
    func fetchResults(_ proposalID: String) async throws -> ResultsFetch {
        var siteDown = false
        var tooLarge = false
        func fetch(_ name: String, _ max: Int) async throws -> [UInt8]? {
            switch try await get("p/\(proposalID)/\(name)", max) {
            case .found(let b): return b
            case .absent: return nil
            case .tooLarge:
                tooLarge = true
                return nil
            case .unreachable:
                siteDown = true
                return nil
            }
        }
        let doc = try await fetch("results.json", VoteSiteLimits.resultsMax)
        if tooLarge { return .tooLarge }
        guard let doc else { return siteDown ? .siteDown : .notPublished }
        let sig = try await fetch("results.json.sig", VoteSiteLimits.sigMax)
        let bundle = try await fetch("results.json.sigstore.json", VoteSiteLimits.bundleMax)
        let rows = try await fetch("rows.json", VoteSiteLimits.rowsMax)
        if tooLarge { return .tooLarge }
        guard let sig, let bundle, let rows else { return siteDown ? .siteDown : .notPublished }
        return .files(ResultsFiles(doc: doc, sig: sig, bundle: bundle, rows: rows))
    }
}
