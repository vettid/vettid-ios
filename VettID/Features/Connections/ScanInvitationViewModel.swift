import Foundation

/// State for scan invitation flow
enum ScanInvitationState: Equatable {
    case scanning
    case processing
    case preview(PeerInvitationInfo)
    case success(Connection)
    case error(String)

    static func == (lhs: ScanInvitationState, rhs: ScanInvitationState) -> Bool {
        switch (lhs, rhs) {
        case (.scanning, .scanning), (.processing, .processing):
            return true
        case (.preview(let a), .preview(let b)):
            return a.code == b.code
        case (.success(let a), .success(let b)):
            return a.id == b.id
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Information about the invitation being scanned
struct PeerInvitationInfo: Equatable {
    let code: String
    let creatorDisplayName: String
    let expiresAt: Date?
}

/// ViewModel for scanning and accepting connection invitations
@MainActor
final class ScanInvitationViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: ScanInvitationState = .scanning

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let cryptoManager: ConnectionCryptoManager
    private let authTokenProvider: @Sendable () -> String?
    var connectionsClient: ConnectionsClient?

    // MARK: - Private State

    private var scannedCode: String?
    private var generatedKeyPair: (publicKey: Data, privateKey: Data)?
    private var resolvedInvitation: NatsResolvedInvitation?

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        cryptoManager: ConnectionCryptoManager = ConnectionCryptoManager(),
        authTokenProvider: @escaping @Sendable () -> String?,
        connectionsClient: ConnectionsClient? = nil
    ) {
        self.apiClient = apiClient
        self.cryptoManager = cryptoManager
        self.authTokenProvider = authTokenProvider
        self.connectionsClient = connectionsClient
    }

    // MARK: - Scanning

    /// Handle QR code scan result
    func onQrCodeScanned(_ data: String) {
        // Parse the QR code data
        // Expected formats:
        // - vettid://invite/{code}
        // - https://vettid.com/invite/{code}
        // - Just the code itself

        let code = parseInvitationCode(from: data)

        guard !code.isEmpty else {
            state = .error("Invalid QR code format")
            return
        }

        processCode(code)
    }

    /// Handle manual code entry. Tries the canonical 12-character
    /// `ShortCode` form first (strips hyphens / spaces, uppercases),
    /// then falls back to the looser legacy parse for older invite
    /// formats.
    func onManualCodeEntered(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .error("Please enter an invitation code")
            return
        }

        // Canonical short-code path first — handles `ABCD-EFGH-JKLM`,
        // `abcd efgh jklm`, `abcdefghjklm`, etc.
        let canonical = ShortCode.normalize(trimmed)
        if ShortCode.isValid(canonical) {
            processCode(canonical)
            return
        }

        // Legacy fallback — let the resolver decide if it's a known
        // older format. `processCode` will surface a friendly error
        // if the broker doesn't recognize it.
        processCode(trimmed)
    }

    /// Parse invitation code from various formats. Accepts:
    ///   - Short-code only (`ABCD-EFGH-JKLM` or `ABCDEFGHJKLM`)
    ///   - `https://vettid.dev/connect?c=<code>` (Phase 1.8 share URL)
    ///   - `https://vettid.dev/connect?code=<code>` (legacy)
    ///   - `https://vettid.dev/connect/<code>` (path-segment)
    ///   - `vettid://connect?code=<code>` (custom-scheme deep link)
    ///   - `vettid://invite/<code>` (legacy custom-scheme)
    ///   - Compact broker JSON `{"c":"<code>","e":"<endpoint>"}`
    /// Returns the bare normalized code or empty string when nothing
    /// matched.
    private func parseInvitationCode(from data: String) -> String {
        // Compact broker format.
        if data.hasPrefix("{"),
           let jsonData = data.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: String],
           let code = json["c"] {
            return ShortCode.normalize(code)
        }

        // Custom-scheme deep links.
        if data.hasPrefix("vettid://invite/") {
            return ShortCode.normalize(String(data.dropFirst("vettid://invite/".count)))
        }
        if let url = URL(string: data),
           url.scheme == "vettid",
           url.host == "connect" {
            let q = parseQuery(url)
            if let code = q["c"] ?? q["code"] {
                return ShortCode.normalize(code)
            }
        }

        // HTTPS share / universal links.
        if let url = URL(string: data),
           let scheme = url.scheme, scheme.hasPrefix("http") {
            let q = parseQuery(url)
            if let code = q["c"] ?? q["code"] {
                return ShortCode.normalize(code)
            }
            // Path-segment form: /connect/<code>  or  /invite/<code>.
            let segments = url.pathComponents.filter { $0 != "/" }
            if segments.count >= 2,
               ["connect", "invite"].contains(segments[segments.count - 2].lowercased()) {
                return ShortCode.normalize(segments[segments.count - 1])
            }
        }

        // Otherwise treat it as a bare code (also covers raw QR
        // payloads containing just the 12 chars).
        return ShortCode.normalize(data.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Pull `URL.queryItems` into a flat dict; URLComponents tolerates
    /// our custom `vettid://` scheme and HTTPS uniformly.
    private func parseQuery(_ url: URL) -> [String: String] {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return [:] }
        var out: [String: String] = [:]
        for item in items { if let v = item.value { out[item.name] = v } }
        return out
    }

    /// Check if QR data is compact broker format
    private func isCompactBrokerFormat(_ data: String) -> Bool {
        guard data.hasPrefix("{"),
              let jsonData = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: String] else {
            return false
        }
        return json["c"] != nil
    }

    /// Process the scanned/entered code
    private func processCode(_ code: String) {
        scannedCode = code
        state = .processing

        // If we have a NATS client, try to resolve via broker for richer preview
        if connectionsClient != nil {
            Task {
                await resolveAndPreview(code)
            }
            return
        }

        // Fallback: show preview with just the code
        let peerInfo = PeerInvitationInfo(
            code: code,
            creatorDisplayName: "Unknown",  // Would be fetched from API
            expiresAt: nil
        )

        state = .preview(peerInfo)
    }

    /// Resolve an invite code via the vault broker and show preview
    private func resolveAndPreview(_ code: String) async {
        do {
            let resolved = try await resolveInviteCode(code)
            resolvedInvitation = resolved

            let isoFormatter = ISO8601DateFormatter()
            let expiresDate = isoFormatter.date(from: resolved.expiresAt)

            let peerInfo = PeerInvitationInfo(
                code: code,
                creatorDisplayName: resolved.label.isEmpty ? "Unknown" : resolved.label,
                expiresAt: expiresDate
            )

            state = .preview(peerInfo)
        } catch {
            // If broker resolution fails, still show basic preview
            #if DEBUG
            print("[ScanInvitationViewModel] Broker resolve failed: \(error), showing basic preview")
            #endif
            let peerInfo = PeerInvitationInfo(
                code: code,
                creatorDisplayName: "Unknown",
                expiresAt: nil
            )
            state = .preview(peerInfo)
        }
    }

    /// Resolve an invite code via the vault's broker (NATS INVITATIONS stream)
    /// - Parameter code: The short invite code from QR or deep link
    /// - Returns: Resolved invitation with credentials and space IDs
    func resolveInviteCode(_ code: String) async throws -> NatsResolvedInvitation {
        guard let client = connectionsClient else {
            throw ConnectionError.invalidInvitationCode
        }
        return try await client.resolveInvite(inviteCode: code)
    }

    /// Fetch peer profile data for a resolved invitation (placeholder)
    /// In a full implementation, this would query the peer's public profile
    func fetchPeerProfile(peerGuid: String) async -> PeerProfileData? {
        // TODO: Implement peer profile fetching via vault or API
        return nil
    }

    // MARK: - Accept Invitation

    /// Accept the scanned invitation
    func acceptInvitation() async {
        guard let code = scannedCode else {
            state = .error("No invitation code")
            return
        }

        guard let authToken = authTokenProvider() else {
            state = .error("Not authenticated")
            return
        }

        state = .processing

        do {
            // Generate key pair for this connection
            let keyPair = try cryptoManager.generateConnectionKeyPair()
            generatedKeyPair = keyPair

            // Accept invitation via API
            let response = try await apiClient.acceptInvitation(
                code: code,
                publicKey: keyPair.publicKey,
                authToken: authToken
            )

            // Derive and store connection key
            if let peerPublicKeyData = Data(base64Encoded: response.peerPublicKey) {
                try await storeConnectionKey(
                    connectionId: response.connection.id,
                    peerPublicKey: peerPublicKeyData
                )
            }

            state = .success(response.connection)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Store the connection key after accepting
    private func storeConnectionKey(connectionId: String, peerPublicKey: Data) async throws {
        guard let keyPair = generatedKeyPair else {
            throw ConnectionError.noKeyPair
        }

        // Derive shared secret
        let sharedSecret = try cryptoManager.deriveSharedSecret(
            privateKey: keyPair.privateKey,
            peerPublicKey: peerPublicKey
        )

        // Derive connection key
        let connectionKey = try cryptoManager.deriveConnectionKey(
            sharedSecret: sharedSecret,
            connectionId: connectionId
        )

        // Store in Keychain
        try cryptoManager.storeConnectionKey(connectionId: connectionId, key: connectionKey)
    }

    // MARK: - Actions

    /// Reset to scanning state
    func reset() {
        state = .scanning
        scannedCode = nil
        generatedKeyPair = nil
    }

    /// Go back to scanning from preview
    func cancelPreview() {
        state = .scanning
        scannedCode = nil
    }
}
