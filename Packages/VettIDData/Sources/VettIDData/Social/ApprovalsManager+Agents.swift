import Foundation
import VettIDCrypto
import VettIDVault

// What an agent's approval needs beyond the other approvals (ANDROID-PLAN 0.1.138 AA8 "Fail closed"): one that does not read
// strictly is kept deny only, one a `pending.list` read showed otherwise is deny only, and one referred again replaces the
// approval it names (§6.8 step 4).
extension ApprovalsManager {
    /// The body of [m]. An `approval.pending` that does not read strictly (a duplicate member somewhere) is kept as a deny-only
    /// one, not dropped, so that the member can still deny it (ANDROID-PLAN 0.1.138 AA8 "Fail closed").
    func eventObject(_ m: VaultMessage) -> JsonObject {
        guard m.type == Self.approvalType, (try? StrictJson.parseObject(m.body)) == nil,
              let lenient = (try? JSONSerialization.jsonObject(with: Data(m.body))) as? [String: Any],
              let denyOnly = ApprovalParser.denyOnly(lenient) else { return m.object }
        return denyOnly
    }

    /// AA8: an approval a `pending.list` read showed otherwise than its event is deny only.
    func denyIfDiffering(_ a: PendingApproval) -> PendingApproval {
        guard case .device(var d) = a, mismatched.contains(a.key) else { return a }
        d.held = .unshown
        return .device(d)
    }

    /// The key of the approval [a] replaces, if it is a run or a proxy referred again.
    static func replacedKey(_ a: PendingApproval) -> String? {
        guard case .device(let d) = a, d.type == approvalType, let r = d.replaces, r != d.id else { return nil }
        return PendingApproval.device(DeviceRequest(type: d.type, id: r, receivedAt: d.receivedAt)).key
    }

    /// The approval [key] is replaced by a newer one: gone, also when a late copy or a list brings it again.
    func markReplaced(_ key: String) {
        replaced.insert(key)
        changes += 1
        changedAt[key] = changes
    }
}
