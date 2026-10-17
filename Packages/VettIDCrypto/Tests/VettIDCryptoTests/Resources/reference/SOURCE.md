# Reference outputs (generated, do not edit)

VAULT-MESSAGING §16 has no vector for the credential's wire crypto (§3.5.4), the credential-key rotation statement
(§3.5.5), the credential blob header (§3.5.2) or the grant seal (§10.12). IOS-PLAN §8 (I0.8) checks them against
the Go reference instead: `credential.json` is what vettid-vault's `vms/credwire`, `vms/sharewire` and
`features/credential` produce from fixed, public, TEST-ONLY seeds, written by `scripts/credential-reference`.

- vettid-vault commit: 7f2c5b7bd8c6c04b6f46df610a6aa1f4d29104fe
- Generated: 2026-10-17

HPKE encapsulation is random in the reference, so the sealed values differ on every run and the tests open them
rather than compare them; the rotation statements are deterministic and compared byte for byte. The other direction
(values sealed by the Swift code with fixed randomness, opened by the reference with `go run . open …`) is pinned by
hash in `CredentialTests.swift`.

To regenerate, with vettid-vault cloned next to this repository:

```
cd scripts/credential-reference
go run . > ../../Packages/VettIDCrypto/Tests/VettIDCryptoTests/Resources/reference/credential.json
```
