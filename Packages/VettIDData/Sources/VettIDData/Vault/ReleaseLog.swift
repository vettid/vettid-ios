import Foundation
import VettIDRelay

/// How urgent updating is, as the release log says (RELEASE-UPDATES §5). Information only. Mirrors vettid-android
/// `ReleaseSecurity`.
public enum ReleaseSecurity: String, Equatable, Sendable {
    case none, recommended, urgent
}

/// One release log entry as the app shows it: plain text, already cut to the RELEASE-UPDATES §5 limits. Mirrors
/// vettid-android `ReleaseLogEntry`.
public struct ReleaseLogEntry: Equatable, Sendable {
    public var release: UInt64
    public var summary: String
    public var changes: [String]
    public var security: ReleaseSecurity
    public var securityText: String?

    public init(release: UInt64, summary: String, changes: [String], security: ReleaseSecurity, securityText: String?) {
        self.release = release
        self.summary = summary
        self.changes = changes
        self.security = security
        self.securityText = securityText
    }
}

/// A release between the vault's and the offered one: "Also in earlier releases" (one line each).
public struct EarlierRelease: Equatable, Sendable {
    public var release: UInt64
    public var summary: String

    public init(release: UInt64, summary: String) {
        self.release = release
        self.summary = summary
    }
}

/// What's new in a release (ANDROID-PLAN "What's new"): the log entry, or why there is none. Mirrors vettid-android
/// `ReleaseNotes`.
public enum ReleaseNotes: Equatable, Sendable {
    /// The entry of the offered release from [host]'s release log, and the summaries of the releases in between.
    case available(host: String, entry: ReleaseLogEntry, earlier: [EarlierRelease])
    /// "Release notes unavailable": `notes` is not the channel's log URL, the fetch failed, or the log has no entry for
    /// the release with the manifest's PCR0. Updating stays possible.
    case unavailable
}

/// What's new for the update screen and the unlock offer. Mirrors vettid-android `ReleaseNotesRepository`.
public protocol ReleaseNotesRepository: Sendable {
    /// What's new in [target] (a release of the trusted manifest), with the summaries of [between] (the manifest's
    /// releases between the vault's and [target]). Never throws; never decides anything.
    func whatsNew(target: ReleaseView, between: [ReleaseView]) async -> ReleaseNotes
}

/// The rules of What's new (ANDROID-PLAN "What's new", RELEASE-UPDATES §5), pure: which URL may be fetched, and what of
/// `index.json` is used. Mirrors vettid-android `ReleaseLog`.
public enum ReleaseLog {
    /// At most 1 MiB of `index.json` is read.
    public static let maxBytes = 1 << 20
    public static let timeout: TimeInterval = 10
    public static let maxSummary = 160
    public static let maxChanges = 20
    public static let maxChange = 280
    public static let maxSecurityText = 1000
    static let ellipsis = "…"
    static let logPath = "/security/releases/"
    public static let index = "index.json"

    /// The origin of the build's pinned manifest URL (`https://vettid.org`; staging `https://staging.vettid.org`; the dev
    /// stack's), or nil for a URL without one.
    public static func origin(_ manifestURL: String) -> String? {
        guard let u = URLComponents(string: manifestURL), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = u.host?.lowercased(), !host.isEmpty
        else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = u.port.flatMap { $0 == defaultPort ? nil : $0 }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    /// The host shown in "From <host>".
    public static func host(_ manifestURL: String) -> String? {
        guard origin(manifestURL) != nil else { return nil }
        return URLComponents(string: manifestURL)?.host?.lowercased()
    }

    /// The only URL the app fetches for [target]: `<origin>/security/releases/index.json`, and only when the trusted
    /// manifest's `notes` for the release is exactly `<origin>/security/releases/<N>/`, where `<origin>` is the pinned
    /// manifest's; nil otherwise (any other `notes`: no fetch).
    public static func indexURL(_ manifestURL: String, target: ReleaseView) -> String? {
        guard let o = origin(manifestURL), target.number > 0, target.notes == "\(o)\(logPath)\(target.number)/" else { return nil }
        return "\(o)\(logPath)\(index)"
    }

    /// `notes` opened by "Full release notes": an `https` URL only (the manifest parser already requires it).
    public static func openable(_ notes: String) -> Bool {
        guard let u = URLComponents(string: notes), u.scheme?.lowercased() == "https", let h = u.host, !h.isEmpty else { return false }
        return true
    }

    /// What's new from `index.json` [body]: the entry whose `release` is [target]'s number AND whose `pcr0` is the
    /// manifest's PCR0 for it; nil when there is none (or the document is not a log). [between] entries are kept the same
    /// way, each matched on number and PCR0, newest first.
    public static func parse(_ body: [UInt8], target: ReleaseView, between: [ReleaseView]) -> (ReleaseLogEntry, [EarlierRelease])? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(body), options: [.fragmentsAllowed]) as? [String: Any],
              let releases = root["releases"] as? [Any]
        else { return nil }
        let objects = releases.compactMap { $0 as? [String: Any] }
        func find(_ r: ReleaseView) -> ReleaseLogEntry? {
            objects.lazy.compactMap { o in matches(o, r) ? entry(o, r.number) : nil }.first
        }
        guard let e = find(target) else { return nil }
        let earlier = between.filter { $0.number >= 1 && $0.number < target.number }.sorted { $0.number > $1.number }
            .compactMap { r in find(r).map { EarlierRelease(release: r.number, summary: $0.summary) } }
        return (e, earlier)
    }

    private static func matches(_ o: [String: Any], _ r: ReleaseView) -> Bool {
        integer(o["release"]) == r.number && string(o, "pcr0") == r.pcr0
    }

    /// A JSON integer (never a string, a boolean or a number written with a fraction or an exponent, such as `18.0`), as
    /// vettid-android's `longOrNull` reads it.
    private static func integer(_ v: Any?) -> UInt64? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) else { return nil }
        let i = n.int64Value
        guard i >= 0, NSNumber(value: i) == n else { return nil }
        return UInt64(i)
    }

    private static func entry(_ o: [String: Any], _ number: UInt64) -> ReleaseLogEntry? {
        guard let summary = string(o, "summary").map({ plain($0, maxSummary) }), !summary.isEmpty,
              let raw = o["changes"] as? [Any], let security = string(o, "security").flatMap(ReleaseSecurity.init(rawValue:))
        else { return nil }
        let strings = raw.compactMap { $0 as? String }
        guard strings.count == raw.count else { return nil }
        let changes = Array(strings.map { plain($0, maxChange) }.filter { !$0.isEmpty }.prefix(maxChanges))
        let text = string(o, "security_text").map { plain($0, maxSecurityText) }.flatMap { $0.isEmpty ? nil : $0 }
        return ReleaseLogEntry(
            release: number, summary: summary, changes: changes, security: security, securityText: security == .none ? nil : text
        )
    }

    private static func string(_ o: [String: Any], _ key: String) -> String? { o[key] as? String }

    /// Plain text: control and format characters (bidi overrides and the like) become spaces, runs of white space collapse
    /// to one, and text past [max] characters (Unicode scalars) is cut with "…".
    public static func plain(_ s: String, _ max: Int) -> String {
        var out: [Unicode.Scalar] = []
        var space = false
        for c in s.unicodeScalars {
            if out.count > max { break }
            let cat = c.properties.generalCategory
            if c.properties.isWhitespace || cat == .control || cat == .format {
                space = !out.isEmpty
            } else {
                if space { out.append(" ") }
                space = false
                out.append(c)
            }
        }
        if out.count <= max { return String(String.UnicodeScalarView(out)) }
        let end = max - ellipsis.unicodeScalars.count
        var head = String(String.UnicodeScalarView(out.prefix(end)))
        while head.last?.isWhitespace == true { head.removeLast() }
        return head + ellipsis
    }
}

/// Fetches What's new from the channel's release log (ANDROID-PLAN "What's new"): only `index.json` on the pinned
/// manifest's host, only when ``ReleaseLog/indexURL(_:target:)`` allows it; GET without cookies or credentials, redirects
/// refused, a ``ReleaseLog/timeout`` second timeout, at most ``ReleaseLog/maxBytes``, JSON only. A found entry is kept in
/// memory per host, release and PCR0 until the process ends; nothing is stored. Failures are not kept: the next look
/// retries. Mirrors vettid-android `ReleaseNotesClient`.
public final class ReleaseNotesClient: ReleaseNotesRepository, @unchecked Sendable {
    private let manifestURL: String
    private let fetch: @Sendable (URL) async -> [UInt8]?
    private let lock = NSLock()
    private var found: [String: ReleaseNotes] = [:]

    /// [fetch]: TEST ONLY, replaces the network (the body of a 200 JSON answer, or nil).
    public init(manifestURL: String, fetch: (@Sendable (URL) async -> [UInt8]?)? = nil) {
        self.manifestURL = manifestURL
        self.fetch = fetch ?? { await ReleaseLogFetcher.shared.get($0) }
    }

    public func whatsNew(target: ReleaseView, between: [ReleaseView]) async -> ReleaseNotes {
        guard let s = ReleaseLog.indexURL(manifestURL, target: target), let url = URL(string: s), let host = ReleaseLog.host(manifestURL)
        else { return .unavailable }
        let key = "\(host)|\(target.number)|\(target.pcr0)"
        if let n = lock.withLock({ found[key] }) { return n }
        guard let body = await fetch(url), let (entry, earlier) = ReleaseLog.parse(body, target: target, between: between) else {
            return .unavailable
        }
        let notes = ReleaseNotes.available(host: host, entry: entry, earlier: earlier)
        lock.withLock { found[key] = notes }
        return notes
    }
}

/// The release log's GET: an ephemeral session without cookies, cache or credentials, redirects refused.
final class ReleaseLogFetcher: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = ReleaseLogFetcher()

    private let session: URLSession

    override init() {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = ReleaseLog.timeout
        c.timeoutIntervalForResource = ReleaseLog.timeout
        session = URLSession(configuration: c)
        super.init()
    }

    /// The GET for [url]: JSON, with the app's fixed `User-Agent` (VAULT-MESSAGING 0.75.0 §13.6).
    static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return ClientIdentity.identified(req)
    }

    func get(_ url: URL) async -> [UInt8]? {
        let req = Self.request(url)
        do {
            let (bytes, response) = try await session.bytes(for: req, delegate: self)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, Self.isJSON(http.mimeType),
                  http.expectedContentLength <= Int64(ReleaseLog.maxBytes)
            else { return nil }
            var out: [UInt8] = []
            for try await b in bytes {
                out.append(b)
                if out.count > ReleaseLog.maxBytes { return nil }
            }
            return out
        } catch {
            return nil
        }
    }

    static func isJSON(_ mime: String?) -> Bool {
        guard let m = mime?.lowercased() else { return false }
        return m == "application/json" || (m.hasPrefix("application/") && m.hasSuffix("+json"))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
