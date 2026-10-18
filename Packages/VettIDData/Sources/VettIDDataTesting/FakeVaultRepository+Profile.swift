import Foundation
import VettIDData

// TEST ONLY. ``FakeVaultRepository`` as the account's names (vettid-android `FakeVault`'s profile part, the name change).

extension FakeVaultRepository: ProfileRepository {
    /// Records the call; a scripted answer, or a pending request with the next seq, which the account then shows.
    public func changeName(pin: String, password: String, firstName: String, lastName: String) async -> NameChangeOutcome {
        calls.append("changeName")
        lastPin = pin
        lastPassword = password
        lastNames = (firstName, lastName)
        let r: NameChangeOutcome
        if nameResults.isEmpty {
            nameSeq += 1
            r = .requested(NameRequestView(seq: nameSeq, firstName: firstName, lastName: lastName, requestedAt: Date(), state: .pending))
        } else {
            r = nameResults.removeFirst()
        }
        if case .requested(let request) = r { account?.nameRequest = request }
        return r
    }

    public func refreshAccount() async { calls.append("refreshAccount") }
}
