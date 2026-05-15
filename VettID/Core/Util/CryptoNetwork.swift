import Foundation

// MARK: - Crypto Network

/// Pre-populated catalog of common cryptocurrency networks. Used by:
///   - Wallet creation (today: BTC only; tomorrow: any of these).
///   - Cryptocurrency / Crypto Key secrets, where the user records a key
///     or address for a chain we don't yet create wallets for.
///
/// Both surfaces draw from the same list so a peer-visible "BTC" tag
/// means the same string everywhere. Order is roughly market-cap as of
/// 2026 — most-likely picks first. The list is intentionally short; a
/// free-text "Other" slot covers anything not represented.
///
/// Parity with Android `core/util/CryptoNetwork.kt`.
struct CryptoNetwork: Identifiable, Equatable, Hashable {
    let ticker: String
    let displayName: String

    var id: String { ticker }
}

enum CryptoNetworks {
    static let btc   = CryptoNetwork(ticker: "BTC",   displayName: "Bitcoin")
    static let eth   = CryptoNetwork(ticker: "ETH",   displayName: "Ethereum")
    static let usdc  = CryptoNetwork(ticker: "USDC",  displayName: "USD Coin")
    static let usdt  = CryptoNetwork(ticker: "USDT",  displayName: "Tether")
    static let sol   = CryptoNetwork(ticker: "SOL",   displayName: "Solana")
    static let doge  = CryptoNetwork(ticker: "DOGE",  displayName: "Dogecoin")
    static let ltc   = CryptoNetwork(ticker: "LTC",   displayName: "Litecoin")
    static let xrp   = CryptoNetwork(ticker: "XRP",   displayName: "Ripple")
    static let ada   = CryptoNetwork(ticker: "ADA",   displayName: "Cardano")
    static let avax  = CryptoNetwork(ticker: "AVAX",  displayName: "Avalanche")
    static let dot   = CryptoNetwork(ticker: "DOT",   displayName: "Polkadot")
    static let matic = CryptoNetwork(ticker: "MATIC", displayName: "Polygon")
    static let link  = CryptoNetwork(ticker: "LINK",  displayName: "Chainlink")
    static let atom  = CryptoNetwork(ticker: "ATOM",  displayName: "Cosmos")
    static let bch   = CryptoNetwork(ticker: "BCH",   displayName: "Bitcoin Cash")
    static let other = CryptoNetwork(ticker: "OTHER", displayName: "Other")

    static let all: [CryptoNetwork] = [
        btc, eth, usdc, usdt, sol, doge, ltc, xrp, ada,
        avax, dot, matic, link, atom, bch, other
    ]

    /// Resolve a ticker (case-insensitive, whitespace-trimmed) to a
    /// known `CryptoNetwork`. Returns nil for unknown / empty inputs.
    static func fromTicker(_ ticker: String?) -> CryptoNetwork? {
        guard let raw = ticker?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        let normalized = raw.uppercased()
        return all.first { $0.ticker == normalized }
    }
}
