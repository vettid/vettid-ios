# Test fixtures (copied or generated, do not edit)

All public, TEST-ONLY data. A fixture that no longer verifies is a stop-and-report item, never a skip.

- `nitro/aws-attestation-2025-09-16.b64`: copied verbatim from vettid-vault `vms/nitro/testdata/` (commit
  7f2c5b7bd8c6c04b6f46df610a6aa1f4d29104fe), the same file vettid-android checks. A real AWS Nitro Enclaves attestation
  document (base64) from an enclave in us-east-1 on 2025-09-16, originally from the test fixtures of tkhq/rust-sdk
  (Apache-2.0). It shows the NSM's actual encoding: an untagged COSE_Sign1 whose payload is an indefinite-length CBOR
  map, with `nonce` null.
- `nitro/staging-enclave-2026-10-18.json`: one staging `GET /api/vault/enclave` answer (MEMBER-API "Vault (alternate
  channel)": `instance_id`, `release`, `descriptor`, `attestation`, unchanged), staging release 15, fetched
  2026-10-18T00:50:36Z from the staging instance registry the route reads, as posted in issue #49. Public data.
- `nitro/test-pki.json`: written by `scripts/nitro-test-pki`: a P-384 root, intermediate and leaf shaped like AWS
  Nitro's, from the public scalars 48 × 0x31, 0x32 and 0x33. The tests sign fake NSM documents with the leaf key.
- `manifest/staging-pcr-manifest-serial1.json` and `manifest/staging-pcr-manifest-serial17.json`: the documents
  `https://staging.vettid.org/.well-known/vettid/pcr-manifest.json` served, copied verbatim from vettid.org
  `vault/staging/pcr-manifest.json` at commits 3b2532372570ce82b947e927e59619e78340306b (serial 1, the copy
  vettid-android checks) and 8f5c03a301614d5608d68221b9334aaeb799a2ea (serial 17, 2026-10-16), signed by the staging
  channel's key A (`key_id` e9b3a403423120ac).
- `vectors/release.json`: the VAULT-MESSAGING §16 vector from vettid-vault `testdata/vectors/`, the same file as
  `Packages/VettIDCrypto/Tests/VettIDCryptoTests/Resources/vectors/release.json` (see its SOURCE.md).

`sha256sum`:

```
5f9d15f36e5fec19e6798b22d86d8b84f822a3a77b859bf9453f4e3f85c33b21  nitro/aws-attestation-2025-09-16.b64
76538e4fa0f6ff8b019931cd6ee43ebd6874f9f9f775440356e22dc3299a02f4  nitro/staging-enclave-2026-10-18.json
3ead842d1471a0c49ea4bd860585aaa2b53b6f1235ceb0adaadd89a9ebb83554  nitro/test-pki.json
ccdb2c9bd255363b9a0d0166f46ada4659e7f2373f8f4fc66ecc864e3a5a6b38  manifest/staging-pcr-manifest-serial1.json
e010990d9f64ab736cd3884cd0c1ecb28b08a9fa9cea71401d9603e823dd2479  manifest/staging-pcr-manifest-serial17.json
8944c466cd00ce5d606f310e954b8d13fdd4d65d598062b3ecc05de6d310ad6f  vectors/release.json
```
