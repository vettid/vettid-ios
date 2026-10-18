import Foundation
import VettIDCrypto

// The account's names (VAULT-MESSAGING §10.8): the app changes them only here, with the PIN and the credential password.
extension VaultApi {
    /// `account.name.set`'s message type (§10.2, §10.8).
    public static let typeAccountNameSet = "account.name.set"

    /// Changes the account's first and last name (§10.8): the PIN, the credential password and the two names sealed
    /// together to one UTK, with the blob, checked as an owner check is (the CEK rotates; the deadline does not move).
    /// Returns the stored request (`pending`); the member API's outcome arrives in the account snapshot (`account.get`'s
    /// `name_request`). `too_soon` carries `{allowed_after}` in the error body; the other refusals are the owner check's.
    /// Mirrors vettid-android `VaultApi.accountNameSet`.
    public func accountNameSet(pin: String, password: String, firstName: String, lastName: String) async throws -> NameRequest {
        let fields: [SealedField] = [
            .string("pin", pin), .string("password", password), .string("first_name", firstName), .string("last_name", lastName),
        ]
        let body = try await credential.credOp(Self.typeAccountNameSet, fields)
        struct Answer: Decodable { let request: NameRequest? }
        guard let request = try VaultJSON.decode(Answer.self, body).request else {
            throw VaultStateError(message: "account.name.set without request")
        }
        return request
    }
}
