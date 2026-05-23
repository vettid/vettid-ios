import Foundation

/// Represents different types of deep links the app can handle
enum DeepLink: Equatable {
    /// Enrollment with a session token: vettid://enroll?token={session_token}
    case enroll(token: String)

    /// Connect via invitation code: vettid://connect?code={invite_code}
    case connect(code: String)

    /// Open a conversation: vettid://message?connection={connection_id}
    case message(connectionId: String)

    /// Open vault status: vettid://vault
    case vault

    /// Unknown or invalid deep link
    case unknown
}

/// Security validation result for deep links
enum DeepLinkValidationResult {
    case valid
    case invalidFormat(String)
    case suspiciousContent(String)
    case tooLong(String)
}

/// Handles parsing and routing of deep links
/// Security hardened with input validation and sanitization
@MainActor
class DeepLinkHandler: ObservableObject {
    static let shared = DeepLinkHandler()

    /// The currently pending deep link to be handled
    @Published var pendingDeepLink: DeepLink?

    /// Whether a deep link is currently being processed
    @Published var isProcessing = false

    // MARK: - Security Configuration

    /// Maximum allowed length for deep link parameters
    private let maxTokenLength = 512
    private let maxCodeLength = 128
    private let maxConnectionIdLength = 64

    /// SECURITY (Area E #99): hard cap on the deep-link URL as a whole.
    /// A hostile share-sheet handoff or universal-link redirect could
    /// hand us a multi-megabyte URL string that we'd then run regex
    /// and substring passes over. Real invitation / enrollment URLs
    /// sit under 1 KB; 4 KB leaves headroom for future growth and
    /// rejects pathological input. Matches Android 450489e.
    private let maxUrlStringLength = 4096

    /// SECURITY (Area E #98): hosts we accept on the vettid:// custom
    /// scheme, gated up-front in `parse(url:)` so a URL with an unknown
    /// host bails before parseCustomScheme's switch even runs. The
    /// switch keeps the same set as a defence-in-depth `default`
    /// branch. Matches Android ALLOWED_VETTID_HOSTS.
    private let allowedVettidHosts: Set<String> = ["enroll", "connect", "message", "vault"]

    /// Allowed characters for tokens (base64 + common URL-safe chars)
    private let allowedTokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_=+/."))

    /// Allowed characters for invite codes (alphanumeric + hyphens)
    private let allowedCodeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

    /// Allowed characters for connection IDs (UUIDs)
    private let allowedConnectionIdCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))

    /// Suspicious patterns that might indicate injection attempts
    private let suspiciousPatterns = [
        "<script",
        "javascript:",
        "data:",
        "file://",
        "../",
        "..\\",
        "%00",      // Null byte
        "%0a",      // Newline
        "%0d",      // Carriage return
        "\u{0000}", // Unicode null
    ]

    private init() {}

    /// Parse a URL into a DeepLink
    /// Supports both custom scheme (vettid://) and universal links (https://vettid.dev/)
    func parse(url: URL) -> DeepLink {
        // SECURITY (Area E #99): cap the URL string size before any
        // other work. Cheap rejection of pathological input — keeps
        // the rest of the validator from scanning megabytes of garbage.
        if url.absoluteString.count > maxUrlStringLength {
            logSecurityEvent("Deep link exceeds \(maxUrlStringLength)-char cap (got \(url.absoluteString.count))", url: url)
            return .unknown
        }

        // SECURITY: Validate URL scheme first
        guard let scheme = url.scheme?.lowercased() else {
            logSecurityEvent("Deep link with missing scheme", url: url)
            return .unknown
        }

        // Handle custom scheme: vettid://
        if scheme == "vettid" {
            // SECURITY (Area E #98): allow-list the (scheme, host) pair
            // up front so an unknown vettid:// host can't slip into
            // parseCustomScheme's switch and hit the default branch's
            // suspicious-host log path. Matches Android ALLOWED_VETTID_HOSTS.
            guard let host = url.host?.lowercased(), allowedVettidHosts.contains(host) else {
                logSecurityEvent("vettid:// host not in allow-list: \(url.host ?? "<nil>")", url: url)
                return .unknown
            }
            return parseCustomScheme(url: url)
        }

        // Handle universal links: https://vettid.dev/
        if scheme == "https" {
            guard let host = url.host?.lowercased() else {
                logSecurityEvent("HTTPS deep link with missing host", url: url)
                return .unknown
            }

            // SECURITY: Strict host validation
            let allowedHosts = ["vettid.dev", "www.vettid.dev", "app.vettid.dev"]
            guard allowedHosts.contains(host) else {
                logSecurityEvent("Deep link from untrusted host: \(host)", url: url)
                return .unknown
            }

            // SECURITY (Area E #98): the path's first segment must
            // match the same allow-list as the vettid:// hosts —
            // mirrors Android's https://vettid.dev/<allowed-host> guard.
            let firstSegment = url.pathComponents.filter { $0 != "/" }.first?.lowercased()
            guard let segment = firstSegment, allowedVettidHosts.contains(segment) else {
                logSecurityEvent("HTTPS deep link path not in allow-list: \(firstSegment ?? "<empty>")", url: url)
                return .unknown
            }

            return parseUniversalLink(url: url)
        }

        logSecurityEvent("Deep link with invalid scheme: \(scheme)", url: url)
        return .unknown
    }

    /// Handle an incoming deep link URL
    func handle(url: URL) {
        let deepLink = parse(url: url)

        guard deepLink != .unknown else {
            #if DEBUG
            print("[DeepLink] Rejected unknown deep link: \(url.absoluteString.prefix(100))")
            #endif
            return
        }

        #if DEBUG
        print("[DeepLink] Handling: \(deepLink)")
        #endif

        pendingDeepLink = deepLink
    }

    /// Clear the pending deep link after it has been handled
    func clearPendingDeepLink() {
        pendingDeepLink = nil
    }

    // MARK: - Security Logging

    /// Log security-relevant events (suspicious deep links)
    private func logSecurityEvent(_ message: String, url: URL) {
        #if DEBUG
        print("[DeepLink Security] \(message)")
        print("[DeepLink Security] URL: \(url.absoluteString.prefix(200))")
        #endif

        // In production, could send to security monitoring service
        // Truncate URL to prevent log injection
        let sanitizedUrl = String(url.absoluteString.prefix(500))
        _ = sanitizedUrl // Placeholder for production logging
    }

    // MARK: - Private Parsing Methods

    private func parseCustomScheme(url: URL) -> DeepLink {
        guard let host = url.host?.lowercased() else { return .unknown }

        let queryParams = parseQueryParameters(url: url)

        switch host {
        case "enroll":
            if let token = queryParams["token"] {
                if let validatedToken = validateToken(token, url: url) {
                    return .enroll(token: validatedToken)
                }
            }
        case "connect":
            // Phase 1.8: accept `?c=` (the short HTTPS share URL the
            // CreateInvitationViewModel emits today) AND legacy `?code=`.
            if let code = queryParams["c"] ?? queryParams["code"] {
                if let validatedCode = validateCode(code, url: url) {
                    return .connect(code: validatedCode)
                }
            }
        case "message":
            if let connectionId = queryParams["connection"] {
                if let validatedId = validateConnectionId(connectionId, url: url) {
                    return .message(connectionId: validatedId)
                }
            }
        case "vault":
            return .vault
        default:
            logSecurityEvent("Unknown deep link host: \(host)", url: url)
        }

        return .unknown
    }

    private func parseUniversalLink(url: URL) -> DeepLink {
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let queryParams = parseQueryParameters(url: url)

        guard !pathComponents.isEmpty else { return .unknown }

        let action = pathComponents[0].lowercased()

        switch action {
        case "enroll":
            if let token = queryParams["token"] {
                if let validatedToken = validateToken(token, url: url) {
                    return .enroll(token: validatedToken)
                }
            }
        case "connect":
            // Phase 1.8: accept `?c=` (the short HTTPS share URL the
            // CreateInvitationViewModel emits today) AND legacy `?code=`.
            if let code = queryParams["c"] ?? queryParams["code"] {
                if let validatedCode = validateCode(code, url: url) {
                    return .connect(code: validatedCode)
                }
            }
            // Also support /connect/{code} format
            if pathComponents.count > 1 {
                if let validatedCode = validateCode(pathComponents[1], url: url) {
                    return .connect(code: validatedCode)
                }
            }
        case "message":
            if let connectionId = queryParams["connection"] {
                if let validatedId = validateConnectionId(connectionId, url: url) {
                    return .message(connectionId: validatedId)
                }
            }
        case "vault":
            return .vault
        default:
            logSecurityEvent("Unknown universal link action: \(action)", url: url)
        }

        return .unknown
    }

    private func parseQueryParameters(url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return [:]
        }

        var params: [String: String] = [:]
        for item in queryItems {
            // SECURITY: Limit parameter name length
            guard item.name.count <= 32 else { continue }
            params[item.name] = item.value ?? ""
        }
        return params
    }

    // MARK: - Input Validation

    /// Validate and sanitize enrollment token
    private func validateToken(_ token: String, url: URL) -> String? {
        // Check for empty
        guard !token.isEmpty else {
            return nil
        }

        // Check length
        guard token.count <= maxTokenLength else {
            logSecurityEvent("Token exceeds max length (\(token.count) > \(maxTokenLength))", url: url)
            return nil
        }

        // Check for suspicious patterns
        if containsSuspiciousPattern(token) {
            logSecurityEvent("Token contains suspicious pattern", url: url)
            return nil
        }

        // Validate character set
        guard token.unicodeScalars.allSatisfy({ allowedTokenCharacters.contains($0) }) else {
            logSecurityEvent("Token contains invalid characters", url: url)
            return nil
        }

        return token
    }

    /// Validate and sanitize invitation code
    private func validateCode(_ code: String, url: URL) -> String? {
        // Check for empty
        guard !code.isEmpty else {
            return nil
        }

        // Check length
        guard code.count <= maxCodeLength else {
            logSecurityEvent("Code exceeds max length (\(code.count) > \(maxCodeLength))", url: url)
            return nil
        }

        // Check for suspicious patterns
        if containsSuspiciousPattern(code) {
            logSecurityEvent("Code contains suspicious pattern", url: url)
            return nil
        }

        // Validate character set
        guard code.unicodeScalars.allSatisfy({ allowedCodeCharacters.contains($0) }) else {
            logSecurityEvent("Code contains invalid characters", url: url)
            return nil
        }

        return code
    }

    /// Validate and sanitize connection ID (expected to be UUID format)
    private func validateConnectionId(_ connectionId: String, url: URL) -> String? {
        // Check for empty
        guard !connectionId.isEmpty else {
            return nil
        }

        // Check length
        guard connectionId.count <= maxConnectionIdLength else {
            logSecurityEvent("Connection ID exceeds max length (\(connectionId.count) > \(maxConnectionIdLength))", url: url)
            return nil
        }

        // Check for suspicious patterns
        if containsSuspiciousPattern(connectionId) {
            logSecurityEvent("Connection ID contains suspicious pattern", url: url)
            return nil
        }

        // Validate character set
        guard connectionId.unicodeScalars.allSatisfy({ allowedConnectionIdCharacters.contains($0) }) else {
            logSecurityEvent("Connection ID contains invalid characters", url: url)
            return nil
        }

        // Validate UUID format (optional but recommended)
        // UUIDs are 36 characters: 8-4-4-4-12
        if connectionId.count == 36 {
            let uuidRegex = try? NSRegularExpression(
                pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
                options: []
            )
            let range = NSRange(connectionId.startIndex..., in: connectionId)
            if uuidRegex?.firstMatch(in: connectionId, options: [], range: range) == nil {
                logSecurityEvent("Connection ID is not valid UUID format", url: url)
                return nil
            }
        }

        return connectionId
    }

    /// Check if input contains suspicious patterns that might indicate injection
    private func containsSuspiciousPattern(_ input: String) -> Bool {
        let lowercased = input.lowercased()
        for pattern in suspiciousPatterns {
            if lowercased.contains(pattern.lowercased()) {
                return true
            }
        }
        return false
    }
}
