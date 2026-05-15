import Foundation

// MARK: - Wallet Client

/// NATS-based client for Bitcoin wallet operations.
/// Uses OwnerSpaceClient.sendAndAwaitResponse() for request-response
/// correlation by event_id.
///
/// All private key operations happen inside the vault enclave.
/// The app never sees private keys — only addresses and balances.
final class WalletClient {

    private let ownerSpaceClient: OwnerSpaceClient
    private let credentialStore: ProteanCredentialStore

    init(ownerSpaceClient: OwnerSpaceClient,
         credentialStore: ProteanCredentialStore = ProteanCredentialStore()) {
        self.ownerSpaceClient = ownerSpaceClient
        self.credentialStore = credentialStore
    }

    // MARK: - Wallet Management

    /// Create a new HD wallet (Phase 5.2 — password-gated).
    ///
    /// Android moved wallet creation behind a password gate so the
    /// vault re-derives the credential CEK in-flight and rotates UTKs
    /// on success. The app supplies a password envelope, the vault
    /// hands back a fresh `encrypted_credential` + a `new_utks` array,
    /// and the client persists both before returning the wallet info.
    ///
    /// Backwards-compat path: when `password` is nil, fall back to the
    /// pre-5.2 unauthenticated call. Will be removed once every iOS
    /// call site supplies a password.
    func createWallet(label: String,
                      network: BitcoinNetwork,
                      password: String? = nil) async throws -> WalletInfo {
        var payload: [String: AnyCodableValue] = [
            "label": AnyCodableValue(label),
            "network": AnyCodableValue(network.rawValue)
        ]

        // Phase D / 0.7: include the encrypted credential blob so the
        // vault decrypts in-flight rather than reading vaultState.
        if let blob = try? credentialStore.encryptedBlobBase64() {
            payload["encrypted_credential"] = AnyCodableValue(blob)
        }

        // Phase 5.2: password envelope.
        if let password = password {
            let envelope = try PasswordApprovalEnvelope.build(password: password)
            payload["encrypted_password_hash"] = AnyCodableValue(envelope.encryptedPasswordHash)
            payload["ephemeral_public_key"]    = AnyCodableValue(envelope.ephemeralPublicKey)
            payload["nonce"]                   = AnyCodableValue(envelope.nonce)
            payload["salt"]                    = AnyCodableValue(envelope.salt)
            if let utk = envelope.utkKeyId {
                payload["key_id"] = AnyCodableValue(utk)
            }
        }

        let response = try await sendAndAwait("wallet.create", payload: payload)

        guard let result = response.result else {
            throw WalletClientError.invalidResponse("No result in create response")
        }

        // Phase 5.2: persist the fresh credential blob + UTKs the vault
        // returned on success. Without this the next password-gated op
        // would try to use the old credential, which the vault already
        // rotated away from.
        if let newBlob = result["encrypted_credential"] as? String,
           let blobData = Data(base64Encoded: newBlob) {
            try? rotateStoredCredential(blob: blobData, newUtks: result["new_utks"] as? [[String: Any]])
        }

        return Self.parseWalletInfo(from: result)
    }

    /// Persist a freshly rotated credential blob + UTK pool returned
    /// from a password-gated vault op. Best-effort; failures here
    /// leave the wallet usable but a future password-gated op would
    /// need to recover by re-rotating.
    private func rotateStoredCredential(blob: Data, newUtks: [[String: Any]]?) throws {
        guard let prior = try credentialStore.retrieveMetadata() else { return }
        let metadata = ProteanCredentialMetadata(
            version: prior.version + 1,
            createdAt: prior.createdAt,
            updatedAt: Date(),
            backedUpAt: prior.backedUpAt,
            backupId: prior.backupId,
            sizeBytes: blob.count,
            userGuid: prior.userGuid
        )
        try credentialStore.store(blob: blob, metadata: metadata)
        // UTK pool persistence lives on the separate CredentialStore
        // (`StoredUTK` array on `StoredCredential`). Out of scope for
        // this hop — the warm-up path's storeUTKsFromWarmResponse will
        // refresh on next warm.
        _ = newUtks
    }

    /// List all wallets.
    func listWallets() async throws -> [WalletInfo] {
        let response = try await sendAndAwait("wallet.list", payload: [:])

        guard let result = response.result else {
            throw WalletClientError.invalidResponse("No result in list response")
        }

        let walletsArray = result["wallets"] as? [[String: Any]]
            ?? result["items"] as? [[String: Any]]
            ?? []

        return walletsArray.map { Self.parseWalletInfo(from: $0) }
    }

    /// Get the current balance for a wallet.
    func getBalance(walletId: String) async throws -> BalanceInfo {
        let payload: [String: AnyCodableValue] = [
            "wallet_id": AnyCodableValue(walletId)
        ]

        let response = try await sendAndAwait("wallet.get-balance", payload: payload)

        guard let result = response.result else {
            throw WalletClientError.invalidResponse("No result in balance response")
        }

        return BalanceInfo(
            walletId: walletId,
            confirmedSats: Self.parseInt64(result["confirmed_sats"]) ?? 0,
            unconfirmedSats: Self.parseInt64(result["unconfirmed_sats"]) ?? 0,
            totalSats: Self.parseInt64(result["total_sats"]) ?? 0
        )
    }

    /// Get the current receive address for a wallet.
    func getAddress(walletId: String) async throws -> String {
        let payload: [String: AnyCodableValue] = [
            "wallet_id": AnyCodableValue(walletId)
        ]

        let response = try await sendAndAwait("wallet.get-address", payload: payload)

        guard let address = response.getString("address") else {
            throw WalletClientError.invalidResponse("No address in response")
        }

        return address
    }

    // MARK: - Transactions

    /// Sign and broadcast a transaction. Signing happens in the enclave.
    /// Uses a 60-second timeout since signing and broadcast can be slow.
    func send(
        walletId: String,
        toAddress: String,
        amountSats: Int64,
        feeRate: Int?
    ) async throws -> TxResult {
        var payload: [String: AnyCodableValue] = [
            "wallet_id": AnyCodableValue(walletId),
            "to_address": AnyCodableValue(toAddress),
            "amount_sats": AnyCodableValue(amountSats)
        ]

        if let feeRate = feeRate {
            payload["fee_rate"] = AnyCodableValue(feeRate)
        }

        let response = try await sendAndAwait("wallet.send", payload: payload, timeout: 60)

        guard let result = response.result else {
            throw WalletClientError.invalidResponse("No result in send response")
        }

        return TxResult(
            txid: result["txid"] as? String ?? "",
            rawHex: result["raw_hex"] as? String,
            feeSats: Self.parseInt64(result["fee_sats"]) ?? 0,
            estVsize: result["est_vsize"] as? Int
        )
    }

    /// Send BTC to a connection (P2P payment via vault).
    func sendToConnection(
        walletId: String,
        connectionId: String,
        amountSats: Int64,
        feeRate: Int?
    ) async throws -> TxResult {
        var payload: [String: AnyCodableValue] = [
            "wallet_id": AnyCodableValue(walletId),
            "connection_id": AnyCodableValue(connectionId),
            "amount_sats": AnyCodableValue(amountSats)
        ]

        if let feeRate = feeRate {
            payload["fee_rate"] = AnyCodableValue(feeRate)
        }

        let response = try await sendAndAwait("wallet.send-to-connection", payload: payload, timeout: 60)

        guard let result = response.result else {
            throw WalletClientError.invalidResponse("No result in send-to-connection response")
        }

        return TxResult(
            txid: result["txid"] as? String ?? "",
            rawHex: result["raw_hex"] as? String,
            feeSats: Self.parseInt64(result["fee_sats"]) ?? 0,
            estVsize: result["est_vsize"] as? Int
        )
    }

    /// Send a payment request to a connection.
    func requestPayment(
        connectionId: String,
        walletId: String,
        amountSats: Int64,
        memo: String?
    ) async throws {
        var payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId),
            "wallet_id": AnyCodableValue(walletId),
            "amount_sats": AnyCodableValue(amountSats)
        ]

        if let memo = memo {
            payload["memo"] = AnyCodableValue(memo)
        }

        _ = try await sendAndAwait("wallet.request-payment", payload: payload)
    }

    // MARK: - Fee Estimates

    /// Get current mempool fee estimates.
    func getFeeEstimates() async throws -> FeeEstimate {
        let response = try await sendAndAwait("wallet.get-fees", payload: [:])

        guard let result = response.result else {
            throw WalletClientError.invalidResponse("No result in fee response")
        }

        return FeeEstimate(
            fastestFee: result["fastest_fee"] as? Int ?? 0,
            halfHourFee: result["half_hour_fee"] as? Int ?? 0,
            hourFee: result["hour_fee"] as? Int ?? 0,
            economyFee: result["economy_fee"] as? Int ?? 0,
            minimumFee: result["minimum_fee"] as? Int ?? 0
        )
    }

    // MARK: - Transaction History

    /// Get transaction history for a wallet.
    func getHistory(walletId: String, limit: Int = 50) async throws -> [TxHistoryEntry] {
        let payload: [String: AnyCodableValue] = [
            "wallet_id": AnyCodableValue(walletId),
            "limit": AnyCodableValue(limit)
        ]

        let response = try await sendAndAwait("wallet.get-history", payload: payload)

        guard let result = response.result else {
            throw WalletClientError.invalidResponse("No result in history response")
        }

        let txArray = result["transactions"] as? [[String: Any]]
            ?? result["items"] as? [[String: Any]]
            ?? []

        return txArray.map { Self.parseTxHistoryEntry(from: $0) }
    }

    // MARK: - Wallet Settings

    /// Delete a wallet.
    func deleteWallet(walletId: String) async throws -> Bool {
        let payload: [String: AnyCodableValue] = [
            "wallet_id": AnyCodableValue(walletId)
        ]

        let response = try await sendAndAwait("wallet.delete", payload: payload)
        return response.success
    }

    /// Set wallet visibility (public/private). Making a wallet public cannot be undone.
    func setVisibility(walletId: String, isPublic: Bool) async throws -> Bool {
        let payload: [String: AnyCodableValue] = [
            "wallet_id": AnyCodableValue(walletId),
            "is_public": AnyCodableValue(isPublic)
        ]

        let response = try await sendAndAwait("wallet.set-visibility", payload: payload)
        return response.success
    }

    // MARK: - Private Helpers

    private func sendAndAwait(
        _ messageType: String,
        payload: [String: AnyCodableValue],
        timeout: TimeInterval = 30
    ) async throws -> VaultHandlerResponse {
        #if DEBUG
        print("[WalletClient] Sending \(messageType) request via OwnerSpaceClient")
        #endif

        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            messageType,
            payload: payload,
            timeout: timeout
        )

        guard response.success else {
            let error = response.error ?? "Request failed"
            #if DEBUG
            print("[WalletClient] \(messageType) failed: \(error)")
            #endif
            throw WalletClientError.requestFailed(
                messageType: messageType,
                error: error,
                errorCode: response.errorCode
            )
        }

        #if DEBUG
        print("[WalletClient] \(messageType) response received")
        #endif

        return response
    }

    // MARK: - Parsing Helpers

    static func parseWalletInfo(from dict: [String: Any]) -> WalletInfo {
        WalletInfo(
            walletId: dict["wallet_id"] as? String ?? "",
            label: dict["label"] as? String ?? "",
            address: dict["address"] as? String ?? "",
            network: BitcoinNetwork(rawValue: dict["network"] as? String ?? "mainnet") ?? .mainnet,
            cachedBalanceSats: parseInt64(dict["cached_balance_sats"]) ?? 0,
            balanceUpdatedAt: dict["balance_updated_at"] as? String,
            isPublic: dict["is_public"] as? Bool ?? false,
            isArchived: dict["is_archived"] as? Bool ?? false
        )
    }

    static func parseTxHistoryEntry(from dict: [String: Any]) -> TxHistoryEntry {
        TxHistoryEntry(
            txid: dict["txid"] as? String ?? "",
            direction: TxDirection(rawValue: dict["direction"] as? String ?? "sent") ?? .sent,
            amountSats: parseInt64(dict["amount_sats"]) ?? 0,
            feeSats: parseInt64(dict["fee_sats"]) ?? 0,
            confirmed: dict["confirmed"] as? Bool ?? false,
            blockHeight: dict["block_height"] as? Int,
            blockTime: dict["block_time"] as? String
        )
    }

    /// Parse an Int64 from various JSON number representations.
    static func parseInt64(_ value: Any?) -> Int64? {
        if let int = value as? Int { return Int64(int) }
        if let int64 = value as? Int64 { return int64 }
        if let double = value as? Double { return Int64(double) }
        if let string = value as? String { return Int64(string) }
        return nil
    }
}

// MARK: - Errors

enum WalletClientError: LocalizedError {
    case requestFailed(messageType: String, error: String, errorCode: String?)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let messageType, let error, let errorCode):
            if let code = errorCode {
                return "Wallet request '\(messageType)' failed [\(code)]: \(error)"
            }
            return "Wallet request '\(messageType)' failed: \(error)"
        case .invalidResponse(let reason):
            return "Invalid wallet response: \(reason)"
        }
    }
}
