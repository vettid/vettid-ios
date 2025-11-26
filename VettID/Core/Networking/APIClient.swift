import Foundation

/// HTTP client for communicating with the VettID Ledger Service
actor APIClient {

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: "https://api.vettid.com")!) {
        self.baseURL = baseURL

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Enrollment

    /// Complete device enrollment with the ledger
    func enroll(request: EnrollmentRequest) async throws -> EnrollmentResponse {
        return try await post(endpoint: "/v1/enroll", body: request)
    }

    // MARK: - Authentication

    /// Authenticate with the ledger using LAT
    func authenticate(request: AuthenticationRequest) async throws -> AuthenticationResponse {
        return try await post(endpoint: "/v1/auth", body: request)
    }

    // MARK: - Vault Operations

    /// Get current vault status
    func getVaultStatus(vaultId: String, authToken: String) async throws -> VaultStatusResponse {
        return try await get(endpoint: "/v1/vaults/\(vaultId)/status", authToken: authToken)
    }

    /// Request vault action (start, stop, etc.)
    func vaultAction(vaultId: String, action: VaultAction, authToken: String) async throws -> VaultActionResponse {
        let request = VaultActionRequest(action: action)
        return try await post(endpoint: "/v1/vaults/\(vaultId)/actions", body: request, authToken: authToken)
    }

    // MARK: - Key Rotation

    /// Submit new CEK public key after rotation
    func rotateCEK(request: CEKRotationRequest, authToken: String) async throws -> CEKRotationResponse {
        return try await post(endpoint: "/v1/keys/cek/rotate", body: request, authToken: authToken)
    }

    /// Replenish transaction keys
    func replenishTransactionKeys(request: TKReplenishRequest, authToken: String) async throws -> TKReplenishResponse {
        return try await post(endpoint: "/v1/keys/tk/replenish", body: request, authToken: authToken)
    }

    // MARK: - HTTP Methods

    private func get<T: Decodable>(endpoint: String, authToken: String? = nil) async throws -> T {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let authToken = authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        return try await execute(request)
    }

    private func post<T: Encodable, R: Decodable>(
        endpoint: String,
        body: T,
        authToken: String? = nil
    ) async throws -> R {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        if let authToken = authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        return try await execute(request)
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorResponse = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw APIError.serverError(httpResponse.statusCode, errorResponse.message)
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingFailed(error)
        }
    }
}

// MARK: - Request/Response Types

struct EnrollmentRequest: Encodable {
    let invitationCode: String
    let deviceId: String
    let cekPublicKey: Data        // X25519 public key
    let signingPublicKey: Data    // Ed25519 public key
    let transactionPublicKeys: [Data]  // X25519 public keys
    let attestationData: Data     // App Attest assertion
}

struct EnrollmentResponse: Decodable {
    let credentialId: String
    let vaultId: String
    let lat: Data                 // Initial LAT token
    let encryptedCredentialBlob: Data
}

struct AuthenticationRequest: Encodable {
    let credentialId: String
    let lat: Data
    let signature: Data           // Ed25519 signature
    let timestamp: Date
}

struct AuthenticationResponse: Decodable {
    let authToken: String         // Short-lived JWT
    let newLat: Data              // Rotated LAT
    let newCekPublicKey: Data?    // If CEK rotation required
}

struct VaultStatusResponse: Decodable {
    let vaultId: String
    let status: String
    let instanceId: String?
    let publicIP: String?
    let lastHeartbeat: Date?
}

enum VaultAction: String, Encodable {
    case start
    case stop
    case restart
    case terminate
}

struct VaultActionRequest: Encodable {
    let action: VaultAction
}

struct VaultActionResponse: Decodable {
    let success: Bool
    let message: String
}

struct CEKRotationRequest: Encodable {
    let credentialId: String
    let newCekPublicKey: Data
    let signature: Data
}

struct CEKRotationResponse: Decodable {
    let success: Bool
    let acknowledgedAt: Date
}

struct TKReplenishRequest: Encodable {
    let credentialId: String
    let newPublicKeys: [Data]
}

struct TKReplenishResponse: Decodable {
    let success: Bool
    let keysAccepted: Int
}

struct APIErrorResponse: Decodable {
    let message: String
    let code: String?
}

// MARK: - Errors

enum APIError: Error {
    case invalidResponse
    case httpError(Int)
    case serverError(Int, String)
    case decodingFailed(Error)
    case networkError(Error)
}
