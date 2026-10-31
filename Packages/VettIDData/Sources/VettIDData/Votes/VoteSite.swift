import Foundation
import VettIDRelay

/// What one read of the public votes site came to (VAULT-MESSAGING 0.81.3 §10.19.8; ANDROID-PLAN 0.1.107).
public enum SiteAnswer: Sendable, Equatable {
    /// HTTP 200 with a whole body.
    case found([UInt8])
    /// HTTP 404: the vault stamps an `absent` entry with its own clock; the app sends no time.
    case absent
    /// Longer than the limit asked for: a document the vault could never take, which is not a site that is down.
    case tooLarge
    /// No answer, a 5xx or any other status (a redirect included), a timeout, a TLS failure, or a truncated body.
    case unreachable
}

/// Reads from the public votes site (VOTES-SITE §3: `/v1/…`) with no session: no cookies, no cache, no identifier and no
/// authorization header (IOS-PLAN §4.16 "The site"). The site sees the phone's address and the hour, and which documents
/// are read. Mirrors vettid-android `VoteSite`.
public protocol VoteSite: Sendable {
    /// False when this build has no site (the dev stack): nothing is fetched and nothing is sent.
    var configured: Bool { get }

    /// The document at [path] under `/v1/`, read up to [maxBytes].
    func get(_ path: String, maxBytes: Int) async -> SiteAnswer
}

public extension VoteSite {
    func get(_ path: String) async -> SiteAnswer { await get(path, maxBytes: VoteSiteLimits.defaultMax) }
}

/// The read limits of the site's documents.
public enum VoteSiteLimits {
    /// A proposal, an extension or a results document: far under this.
    public static let defaultMax = 1 << 20
    /// A service list: the encoded request body's own limit (VAULT-MESSAGING 0.81.2, `attachment_max_bytes`).
    public static let listMax = 8_257_532
    /// A detached Ed25519 signature is 64 bytes.
    public static let sigMax = 256
    public static let bundleMax = 64 * 1024
    /// The vault's `MaxResultsDoc`.
    public static let resultsMax = 196_608
    /// `rows.json`, bounded by the rows the app reads (about 256 bytes a row).
    public static let rowsMax = 100_000 * 256
    public static let indexMax = 8 << 20
}

/// The no-redirect rule of the site's session: an answer that points elsewhere is no answer.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}

/// ``VoteSite`` over a URLSession of its own, for [base] (`https://votes.vettid.org`; nil where the build has no site):
/// an ephemeral configuration with no cookie store, no URL cache and no credential store, no redirects followed, the
/// app's fixed `User-Agent` (``ClientIdentity``) and a 30-second limit for each read.
public struct URLSessionVoteSite: VoteSite {
    private let root: String?
    private let transport: HTTPTransport

    public var configured: Bool { root != nil }

    /// [configuration] is for the tests (a fake URL protocol); the app passes nothing.
    public init(base: String?, configuration: URLSessionConfiguration? = nil, timeout: TimeInterval = 30) {
        // Only HTTPS: a site over plain HTTP is no site (fail secure).
        root = base.flatMap { $0.hasPrefix("https://") ? ($0.hasSuffix("/") ? String($0.dropLast()) : $0) : nil }
        let c = configuration ?? .ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        transport = HTTPTransport(session: URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil))
    }

    public func get(_ path: String, maxBytes: Int) async -> SiteAnswer {
        // A read of work that was cancelled (a lock, the app leaving) is not made.
        guard !Task.isCancelled, let root, let url = URL(string: "\(root)/v1/\(path.drop { $0 == "/" })") else { return .unreachable }
        do {
            let answer = try await transport.send(policy: .idempotent, maxBody: maxBytes, readsBody: { $0 == 200 }) {
                var r = URLRequest(url: url)
                r.httpMethod = "GET"
                r.setValue("*/*", forHTTPHeaderField: "Accept")
                return r
            }
            switch answer.status {
            case 200: return .found(answer.body)
            case 404: return .absent
            default: return .unreachable
            }
        } catch is BodyTooLarge {
            return .tooLarge
        } catch {
            return .unreachable
        }
    }
}
