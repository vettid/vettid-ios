import Foundation

// The Vault's texts, continued (``ItemsStrings``).
public extension ItemsStrings {
    static func impactAuto(_ a: String) -> String {
        String(localized: "items_impact_auto", defaultValue: "Saving shares this item with \(a) automatically.", bundle: .module)
    }

    static func impactAsk(_ a: String) -> String {
        String(
            localized: "items_impact_ask",
            defaultValue: """
                You will be asked whether to share this item with \(a).
                """,
            bundle: .module
        )
    }

    static func impactAskBecause(_ a: String, _ b: String) -> String {
        String(
            localized: "items_impact_ask_because",
            defaultValue: """
                Asks you first because \(a) for \(b) covers it.
                """,
            bundle: .module
        )
    }

    static func impactUsable(_ a: String) -> String {
        String(
            localized: "items_impact_usable",
            defaultValue: """
                \(a) will be able to ask you to use this item, never read it.
                """,
            bundle: .module
        )
    }

    static func impactWithdrawn(_ a: String) -> String {
        String(localized: "items_impact_withdrawn", defaultValue: "Saving stops sharing this item with \(a).", bundle: .module)
    }
}
