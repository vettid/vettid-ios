import Foundation
import VettIDData

/// The History category a feed kind's icon and colour come from (ANDROID-PLAN §4 Notifications, 3): the audit kind's
/// category, `credential.*` under Security, a guide under Other. Mirrors vettid-android `FeedIcons.category`.
public enum FeedCategories {
    public static func of(_ kind: String) -> AuditCategory {
        if kind == "guide" { return .other }
        if kind.hasPrefix("credential.") { return .security }
        return AuditCategory.of(kind)
    }
}
