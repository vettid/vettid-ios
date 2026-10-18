# Reference outputs (generated, do not edit)

VAULT-MESSAGING 0.35.0 §16 states the values of the iPhone's unlock secret (§11.14.1 "On an iPhone"), but
vettid-vault's `testdata/vectors/unlock.json` has no `phone_ios` object yet (IOS-PLAN §7). Until it does,
`phone_ios.json` is what `scripts/phone-ios-reference` writes: the derivation with Go's standard library only
(`crypto/ecdh`, `crypto/hkdf`, `crypto/hmac`), exactly as the specification states it, and the same secrets carried
through vettid-vault's own `vms/recovery` functions (`UnlockKey`, `SecretCheck`, and a `dek_wrap` that
`recovery.OpenDEK` opens). Every key in it is fixed, public and TEST-ONLY. Its secrets, tags, unlock keys and
secret checks are the values §16 lists. `PhoneSecretsReferenceTests.swift` checks them; a value that no longer matches
is a stop-and-report item, never a skip. When vettid-vault's `unlock.json` gains `phone_ios`, it is copied into
VettIDCrypto's vectors and checked there as well.

- vettid-vault commit: 057236379992e48e7f356b4994fc2d11c174d365
- Generated: 2026-10-18, Go 1.26.3

The generator refuses to run unless the vettid-vault clone its `go.mod` names is checked out, without local changes,
at the commit above (its `vaultCommit`), and writes that commit into the file (`vettid_vault_commit`).

To regenerate, with vettid-vault cloned next to this repository and checked out at that commit:

```
cd scripts/phone-ios-reference
go run . > ../../Packages/VettIDData/Tests/VettIDDataTests/Resources/reference/phone_ios.json
```

`sha256sum` of the generated file:

```
c475a66483b666d1c7ea9c3f9cdf8458a658bb3a4abc67b0212d4393bdf2b359  phone_ios.json
```
