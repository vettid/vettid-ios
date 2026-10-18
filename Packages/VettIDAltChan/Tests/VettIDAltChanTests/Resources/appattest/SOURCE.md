# The TEST iOS attester's fixture (generated, do not edit)

`test-app-attest.json` is the output of VettIDAltChanTesting's `TestIOSAttester` (IOS-PLAN §8 I1.3, the Swift port
of vettid-vault `internal/enclavetest/devattest.go`'s iOS attester) for fixed inputs: the key `TestKey(P-256, 0x91)`,
the TEST App ID `TESTTEAM00.com.vettid.app`, credential serial 1001, and SHA-256 of fixed strings as challenges. It
holds the TEST Apple CA's root and intermediate certificates, the `device_attest` object (VAULT-MESSAGING §11.7, iOS
form) and three `device_assertion` objects (an unlock challenge, a release approval string of §11.10.3, another
challenge) with counters 1, 2 and 3. Every key behind it is fixed, public and TEST-ONLY; nothing but the dev
enclave's TEST device policy trusts it.

Two checks hold it in place; a value that no longer matches is a stop-and-report item, never a skip:

- `TestIOSAttesterTests.swift` reproduces everything in it that is not an ECDSA signature byte for byte (the key id,
  the authenticator data, the receipt, each certificate's `tbsCertificate`, each assertion's authenticator data) and
  verifies every signature (ECDSA is randomized).
- `scripts/devattest-verify/run.sh` verifies it with vettid-vault's own code: `vms/devattest.VerifyAttest` and
  `VerifyAssertion` under `internal/enclavetest.Policy()` (the dev enclave's TEST policy) accept the attestation and
  the three assertions in order; another challenge, another App ID and a replayed counter are refused; and the root's,
  the intermediate's and the credential certificate's `tbsCertificate`, the authenticator data, the receipt and each
  assertion's authenticator data equal, byte for byte, what `internal/enclavetest` builds for the same key and
  challenge (`TestAppleCA`, `NewIOSAttester(0x91)`, `IOSAssert`).

- vettid-vault commit: 057236379992e48e7f356b4994fc2d11c174d365
- Generated and verified: 2026-10-18, Go 1.26.3

To regenerate (only when the attester's output must change; then run the Go check again and update the hash):

```
VETTID_WRITE_APPATTEST_FIXTURE=1 swift test --package-path Packages/VettIDAltChan --filter TestIOSAttester
VAULT_SRC=<vettid-vault clone at the commit above> scripts/devattest-verify/run.sh
```

`sha256sum`:

```
16d50e9072db2b1a3cea2d580cd8f1c92fda82a7d7c9da8038ea1cc1fc344a82  test-app-attest.json
```
