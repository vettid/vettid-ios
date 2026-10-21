import Foundation
import VettIDData

/// The Vault screens' messages in the member's words. Mirrors vettid-android `ItemsText` (and `tagLabel`).
public enum ItemsText {
    /// A tag as shown: "Shared profile" for `@profile`, the tag itself otherwise. Mirrors vettid-android `tagLabel`.
    public static func tagLabel(_ tag: String) -> String { tag == ItemChecks.profileTag ? ItemsStrings.tagProfile : tag }

    /// The palette's names, by slot (`TagColors.names`' order).
    public static var colourNames: [String] {
        [
            ItemsStrings.tagColourRed, ItemsStrings.tagColourOrange, ItemsStrings.tagColourGreen, ItemsStrings.tagColourTeal,
            ItemsStrings.tagColourBlue, ItemsStrings.tagColourIndigo, ItemsStrings.tagColourViolet, ItemsStrings.tagColourPink,
            ItemsStrings.tagColourBrown, ItemsStrings.tagColourSlate,
        ]
    }

    /// A failure on the Vault screens: a `limit` in the member's words from the limit it names ([limit], VAULT-MESSAGING
    /// 0.21.0 §10.1); from an older vault, which names none, the likeliest of §10.7 and §10.8 ([creating]: an add, where
    /// `limit` is the vault's item count; [critical]: the credential's; [profile]: the shared profile's). A change made on
    /// another device (`conflict`), else the app's general message; [shownCode] the code an unmapped refusal names (an
    /// item's `bad_request` keeps its text).
    public static func failure(
        _ kind: FailureKind, creating: Bool = false, critical: Bool = false, profile: Bool = false, limit: VaultLimit? = nil,
        shownCode: String? = nil
    ) -> String {
        switch kind {
        case .limit:
            if let limit { return limit.message }
            if profile { return ItemsStrings.errorLimitProfile }
            if creating { return critical ? ItemsStrings.errorLimitCritical : ItemsStrings.errorLimitItems }
            return ItemsStrings.errorLimit
        case .conflict: return ItemsStrings.errorConflict
        case .notFound: return ItemsStrings.errorNotFound
        case .other:
            if let shownCode, shownCode != "bad_request" { return FailureKind.vaultCode(shown(shownCode)).message }
            return ItemsStrings.errorRefused
        default: return kind.message
        }
    }

    /// The code as a failure names it (IOS-PLAN §4.4 (2)): [code] when it matches `[a-z0-9_]{1,40}`, else `unknown`.
    static func shown(_ code: String) -> String {
        let allowed = { (b: UInt8) in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b)
                || b == UInt8(ascii: "_")
        }
        let ok = (1...40).contains(code.utf8.count) && code.utf8.allSatisfy(allowed)
        return ok ? code : "unknown"
    }

    /// A tag change's dry run in words (§10.8): the items it changes and, for a rename, what newly gets shared and what the
    /// member will be asked about.
    public static func change(_ c: TagChange, renaming: Bool) -> String {
        let items = ItemsStrings.tagsChangeItems(c.items)
        guard renaming, c.sharesTotal > 0 else { return items }
        let auto = c.shares.count { $0.mode == .auto }
        let asked = c.sharesTotal - auto
        var out = [items]
        if auto > 0 { out.append(ItemsStrings.tagsChangeShared(auto)) }
        if asked > 0 { out.append(ItemsStrings.tagsChangeAsked(asked)) }
        return out.joined(separator: " ")
    }

    /// A tag row's counts: its items, and the sharing rules that use it.
    public static func tagCounts(_ t: TagView) -> String {
        ItemsStrings.tagItems(t.items) + (t.rules.isEmpty ? "" : " · " + ItemsStrings.tagRules(t.rules.count))
    }

    /// A tag row's second line: for `@profile` what it means, else the counts and the description.
    public static func tagSupporting(_ t: TagView) -> String {
        if t.reserved { return ItemsStrings.tagProfileNote }
        return [tagCounts(t), t.description].compactMap { $0 }.joined(separator: " · ")
    }
}
