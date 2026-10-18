import Foundation
import Security
import Testing
@testable import VettIDKeys

/// The pure parts of the Secure Enclave keys (the keys themselves run on the iPhone: AppTests).
@Suite struct SecureEnclaveKeysTests {
    @Test func aPhoneKeyLabelIsParsedBack() {
        for vault in ["", "vault-0001"] {
            let label = PhoneKeyLabel.make(keyVault: vault, keyID: "0123abcd")
            #expect(PhoneKeyLabel.parse(label) == PhoneKeyName(keyVault: vault, keyID: "0123abcd"))
        }
        for other in ["", "vettid.phone.v1", "vettid.phone.v2\u{1F}v\u{1F}id", "vettid.phone.v1\u{1F}v\u{1F}", "a\u{1F}b\u{1F}c\u{1F}d"] {
            #expect(PhoneKeyLabel.parse(other) == nil, "\(other)")
        }
    }

    /// IOS-PLAN §6.3: invalid only when iOS says so while protected data was available before and after; anything
    /// else is refused for now.
    @Test func aFailureIsInvalidOnlyWhenIOSSaysSoWhileUnlocked() {
        func classify(_ domain: String?, _ code: Int, before: Bool = true, after: Bool = true) -> KeysError {
            SecureEnclaveFailure.classify(domain: domain, code: code, protectedBefore: before, protectedAfter: after, what: "k")
        }
        let os = NSOSStatusErrorDomain
        #expect(classify(os, Int(errSecInvalidKeyRef)) == .invalid("k"))
        #expect(classify(os, Int(errSecItemNotFound)) == .invalid("k"))
        #expect(classify("CryptoTokenKit", -6) == .invalid("k"))
        #expect(classify("CryptoTokenKit", -3) == .invalid("k"))
        #expect(classify(os, Int(errSecInteractionNotAllowed)) == .unavailable("k"))
        #expect(classify("CryptoTokenKit", -9) == .unavailable("k"))
        #expect(classify(os, Int(errSecInvalidKeyRef), before: false) == .unavailable("k"))
        #expect(classify(os, Int(errSecInvalidKeyRef), after: false) == .unavailable("k"))
        #expect(classify(nil, 0) == .unavailable("k"))
        #expect(classify("other", -6) == .unavailable("k"))
    }

    /// A refused creation is "no secure hardware" only when iOS says the Secure Enclave cannot do it.
    @Test func aRefusedCreation() {
        let os = NSOSStatusErrorDomain
        #expect(SecureEnclaveFailure.creation(domain: os, code: Int(errSecUnimplemented), what: "k") == .noSecureHardware)
        #expect(SecureEnclaveFailure.creation(domain: "CryptoTokenKit", code: -1, what: "k") == .noSecureHardware)
        #expect(SecureEnclaveFailure.creation(domain: os, code: Int(errSecInteractionNotAllowed), what: "k") == .unavailable("k"))
        #expect(SecureEnclaveFailure.creation(domain: "CryptoTokenKit", code: -4, what: "k") == .unavailable("k"))
        #expect(SecureEnclaveFailure.creation(domain: "other", code: Int(errSecUnimplemented), what: "k") == .unavailable("k"))
        #expect(SecureEnclaveFailure.creation(domain: nil, code: 0, what: "k") == .unavailable("k"))
    }

    @Test func theAppsKeysHaveTheirOwnTags() {
        let tags = [SecureEnclaveAppKeyStore.tag, SecureEnclaveSeedWrapKeySource.tag, SecureEnclavePhoneSecretSource.tag]
        #expect(Set(tags).count == 3 && tags.allSatisfy { $0.hasPrefix("com.vettid.") })
        let phone = SecureEnclavePhoneSecretSource(protectedData: ProtectedDataFlag())
        #expect(phone.sourceID == SecureEnclavePhoneSecretSource.tag)
    }
}
