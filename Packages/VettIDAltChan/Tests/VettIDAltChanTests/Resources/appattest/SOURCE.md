# The TEST iOS attester's fixtures (generated, do not edit)

`test-app-attest.json` and `test-app-attest-ed.json` are the output of VettIDAltChanTesting's `TestIOSAttester`
(IOS-PLAN §8 I1.3, the Swift port of vettid-vault `internal/enclavetest/devattest.go`'s iOS attester) for fixed inputs:
the key `TestKey(P-256, 0x91)`, the TEST App ID `TESTTEAM00.com.vettid.app`, credential serial 1001, and SHA-256 of
fixed strings as challenges. Each holds the TEST Apple CA's root and intermediate certificates, the `device_attest`
object (VAULT-MESSAGING §11.7, iOS form) and three `device_assertion` objects (an unlock challenge, a release approval
string of §11.10.3, another challenge) with counters 1, 2 and 3. Every key behind them is fixed, public and TEST-ONLY;
nothing but the dev enclave's TEST device policy trusts them.

- `test-app-attest.json`: the form without extensions (`TestIOSAttester(appleExtensions: false)`, vettid-vault
  `IOSOptions{}`): flags `0x41` in the attestation, `0x01` in each assertion, nothing after the COSE key or the counter.
- `test-app-attest-ed.json` (`"apple_extensions": true`): the form a real iPhone sends on iOS 27, the attester's default
  (vettid-vault `IOSAppleExtensions`): flags `0xc0` (AT and ED) in the attestation and in each assertion, and the
  62-byte extensions map `enclavetest.AppleExtensions()` after the COSE key and after each counter. vettid-vault
  `vms/devattest` accepts it since vettid-vault #118.

Two checks hold them in place; a value that no longer matches is a stop-and-report item, never a skip:

- `TestIOSAttesterTests.swift` reproduces everything in each that is not an ECDSA signature byte for byte (the key id,
  the authenticator data, the receipt, each certificate's `tbsCertificate`, each assertion's authenticator data) and
  verifies every signature (ECDSA is randomized).
- `scripts/devattest-verify/run.sh` verifies each with vettid-vault's own code: `vms/devattest.VerifyAttest` and
  `VerifyAssertion` under `internal/enclavetest.Policy()` (the dev enclave's TEST policy) accept the attestation and
  the three assertions in order; another challenge, another App ID and a replayed counter are refused; and the root's,
  the intermediate's and the credential certificate's `tbsCertificate`, the authenticator data, the receipt and each
  assertion's authenticator data equal, byte for byte, what `internal/enclavetest` builds for the same key and
  challenge (`TestAppleCA`, `NewIOSAttester(0x91, …)`, `IOSAssertWith`, with `IOSAppleExtensions` for the `-ed` file).

`test-app-attest.json`:

- vettid-vault commit: 057236379992e48e7f356b4994fc2d11c174d365
- Generated and verified: 2026-10-18, Go 1.26.3
- Re-verified, unchanged (same sha256), at vettid-vault ed8929818d776e278bcb8b5756add909572f8838: 2026-10-18, Go 1.26.3

`test-app-attest-ed.json`:

- vettid-vault commit: ed8929818d776e278bcb8b5756add909572f8838
- Generated and verified: 2026-10-18, Go 1.26.3

To regenerate one (only when the attester's output must change; then run the Go check again and update the hash):

```
VETTID_WRITE_APPATTEST_FIXTURE=test-app-attest-ed.json swift test --package-path Packages/VettIDAltChan --filter TestIOSAttester
VAULT_SRC=<vettid-vault clone at run.sh's VAULT_COMMIT> scripts/devattest-verify/run.sh \
  Packages/VettIDAltChan/Tests/VettIDAltChanTests/Resources/appattest/test-app-attest-ed.json
```

(`VETTID_WRITE_APPATTEST_FIXTURE=test-app-attest.json` and `run.sh` without an argument for the other.)

`sha256sum`:

```
16d50e9072db2b1a3cea2d580cd8f1c92fda82a7d7c9da8038ea1cc1fc344a82  test-app-attest.json
ff5fb2eb67d21a5aad82d98ecdafb97f6c0f5266f6ab4a7f23c54afb3ae58e2d  test-app-attest-ed.json
```
