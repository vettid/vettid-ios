# Test vectors (copied, do not edit)

The files in `vectors/` are copied verbatim from vettid-vault `testdata/vectors/`
(VAULT-MESSAGING §16, IOS-PLAN §7). They are the authoritative cross-implementation
vectors: the Swift code must reproduce every value byte for byte. All keys and seeds
in them are fixed, public and TEST-ONLY. A vector that no longer matches is a
stop-and-report item, never a skip.

- Source repository: github.com/vettid/vettid-vault
- Source commit (`main` when copied): 1ef2dd9ec68627a80e18d665032fcd58e3a61a1d
- Last commit touching `keys.json`: 7eb063767ad7dfd5dc4128ba1e90b3a71fc514b6
- Copied: 2026-10-17 (`keys.json`, for I0.3). Each later PR adds the files it checks.

To refresh: copy the files again from a newer vettid-vault commit, update the commits
above and the hashes below, and run `swift test --package-path Packages/VettIDCrypto`.

`sha256sum` of the copied files:

```
568c65595189051a6297653511acb27c88fed17257b985af070342d5bfc1660e  keys.json
```
