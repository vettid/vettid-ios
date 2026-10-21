import Foundation
import VettIDData

// TEST ONLY. ``FakeVaultRepository`` as the shared profile and the account's names (vettid-android `FakeVault`'s profile
// part).

extension FakeVaultRepository: ProfileRepository {
    public func refreshProfile() async throws { try call("refreshProfile") }

    /// Records the call; the display name kept (trimmed) with a new version, as the vault answers.
    public func setDisplayName(_ name: String) async throws {
        try call("setDisplayName")
        guard var p = profile else { return }
        p.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.version += 1
        profile = p
    }

    /// Records the call and the photo ("" removes it), kept with a new version.
    public func setPhoto(_ photo: String) async throws {
        try call("setPhoto")
        lastPhoto = photo
        guard var p = profile else { return }
        p.photo = photo.isEmpty ? nil : photo
        p.version += 1
        profile = p
    }

    /// Records the call; a scripted answer, or a pending request with the next seq, which the account then shows.
    public func changeName(pin: String, password: String, firstName: String, lastName: String) async -> NameChangeOutcome {
        calls.append("changeName")
        lastPin = pin
        lastPassword = password
        lastNames = (firstName, lastName)
        if let changeNameGate { try? await changeNameGate.value() }
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
