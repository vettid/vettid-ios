import Foundation

// MARK: - Bitcoin Network

enum BitcoinNetwork: String, Codable, CaseIterable {
    case mainnet
    case testnet

    var displayName: String {
        switch self {
        case .mainnet: return "Mainnet"
        case .testnet: return "Testnet"
        }
    }
}

// MARK: - Wallet Info

struct WalletInfo: Codable, Identifiable {
    let walletId: String
    let label: String
    let address: String
    let network: BitcoinNetwork
    let cachedBalanceSats: Int64
    let balanceUpdatedAt: String?
    let isPublic: Bool
    let isArchived: Bool

    var id: String { walletId }

    /// Balance in BTC (1 BTC = 100,000,000 sats)
    var balanceBtc: Double {
        Double(cachedBalanceSats) / 100_000_000.0
    }

    /// Formatted BTC balance string
    var formattedBalance: String {
        String(format: "%.8f BTC", balanceBtc)
    }

    /// Truncated address for display (e.g. "bc1q...x4f8")
    var truncatedAddress: String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }

    enum CodingKeys: String, CodingKey {
        case walletId = "wallet_id"
        case label
        case address
        case network
        case cachedBalanceSats = "cached_balance_sats"
        case balanceUpdatedAt = "balance_updated_at"
        case isPublic = "is_public"
        case isArchived = "is_archived"
    }
}

// MARK: - Balance Info

struct BalanceInfo: Codable {
    let walletId: String
    let confirmedSats: Int64
    let unconfirmedSats: Int64
    let totalSats: Int64

    var totalBtc: Double {
        Double(totalSats) / 100_000_000.0
    }

    var formattedTotal: String {
        String(format: "%.8f BTC", totalBtc)
    }

    enum CodingKeys: String, CodingKey {
        case walletId = "wallet_id"
        case confirmedSats = "confirmed_sats"
        case unconfirmedSats = "unconfirmed_sats"
        case totalSats = "total_sats"
    }
}

// MARK: - Transaction Result

struct TxResult: Codable {
    let txid: String
    let rawHex: String?
    let feeSats: Int64
    let estVsize: Int?

    enum CodingKeys: String, CodingKey {
        case txid
        case rawHex = "raw_hex"
        case feeSats = "fee_sats"
        case estVsize = "est_vsize"
    }
}

// MARK: - Fee Estimate

struct FeeEstimate: Codable {
    let fastestFee: Int
    let halfHourFee: Int
    let hourFee: Int
    let economyFee: Int
    let minimumFee: Int

    enum CodingKeys: String, CodingKey {
        case fastestFee = "fastest_fee"
        case halfHourFee = "half_hour_fee"
        case hourFee = "hour_fee"
        case economyFee = "economy_fee"
        case minimumFee = "minimum_fee"
    }
}

/// Fee tier for user selection
enum FeeTier: String, CaseIterable, Identifiable {
    case economy
    case standard
    case fast
    case fastest

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .economy: return "Economy"
        case .standard: return "Standard"
        case .fast: return "Fast"
        case .fastest: return "Fastest"
        }
    }

    var description: String {
        switch self {
        case .economy: return "~1 hour"
        case .standard: return "~30 minutes"
        case .fast: return "~10 minutes"
        case .fastest: return "Next block"
        }
    }

    func rate(from estimate: FeeEstimate) -> Int {
        switch self {
        case .economy: return estimate.economyFee
        case .standard: return estimate.hourFee
        case .fast: return estimate.halfHourFee
        case .fastest: return estimate.fastestFee
        }
    }
}

// MARK: - Transaction History Entry

struct TxHistoryEntry: Codable, Identifiable {
    let txid: String
    let direction: TxDirection
    let amountSats: Int64
    let feeSats: Int64
    let confirmed: Bool
    let blockHeight: Int?
    let blockTime: String?

    var id: String { txid }

    var amountBtc: Double {
        Double(amountSats) / 100_000_000.0
    }

    var formattedAmount: String {
        let prefix = direction == .received ? "+" : "-"
        return "\(prefix)\(String(format: "%.8f", amountBtc)) BTC"
    }

    var feeBtc: Double {
        Double(feeSats) / 100_000_000.0
    }

    var blockDate: Date? {
        guard let blockTime = blockTime else { return nil }
        return ISO8601DateFormatter().date(from: blockTime)
    }

    enum CodingKeys: String, CodingKey {
        case txid
        case direction
        case amountSats = "amount_sats"
        case feeSats = "fee_sats"
        case confirmed
        case blockHeight = "block_height"
        case blockTime = "block_time"
    }
}

enum TxDirection: String, Codable {
    case sent
    case received
}

// MARK: - Payment Request

struct PaymentRequest: Codable {
    let amountSats: Int64
    let address: String?
    let memo: String?
    let walletId: String?
    let expiresAt: String?

    var amountBtc: Double {
        Double(amountSats) / 100_000_000.0
    }

    enum CodingKeys: String, CodingKey {
        case amountSats = "amount_sats"
        case address
        case memo
        case walletId = "wallet_id"
        case expiresAt = "expires_at"
    }
}

// MARK: - BTC Payment Receipt

struct BtcPaymentReceipt: Codable {
    let txid: String
    let amountSats: Int64
    let feeSats: Int64
    let paymentRequestId: String?

    var amountBtc: Double {
        Double(amountSats) / 100_000_000.0
    }

    enum CodingKeys: String, CodingKey {
        case txid
        case amountSats = "amount_sats"
        case feeSats = "fee_sats"
        case paymentRequestId = "payment_request_id"
    }
}

// MARK: - BTC Payment Decline (Phase 5.6)

/// Decline payload sent back when the recipient rejects a payment
/// request. Carries the original `request_id` and a free-text reason
/// so the sender knows which request was rejected and why.
/// Mirrors Android `BtcPaymentDecline`.
struct BtcPaymentDecline: Codable {
    let requestId: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case reason
    }
}

// MARK: - BTC Address

struct BtcAddress: Codable {
    let address: String
    let label: String?
    let network: BitcoinNetwork?
}
