# Test vectors (copied, do not edit)

The files in `vectors/` are copied verbatim from vettid-vault `testdata/vectors/`
(VAULT-MESSAGING §16, IOS-PLAN §7). They are the authoritative cross-implementation
vectors: the Swift code must reproduce every value byte for byte. All keys and seeds
in them are fixed, public and TEST-ONLY. A vector that no longer matches is a
stop-and-report item, never a skip.

- Source repository: github.com/vettid/vettid-vault
- Source commit (`main` when copied): 1ef2dd9ec68627a80e18d665032fcd58e3a61a1d
- Last commit touching `keys.json`: 7eb063767ad7dfd5dc4128ba1e90b3a71fc514b6
- Copied: 2026-10-17 (`keys.json`, for I0.3).
- `hpke.json`, `envelope_sealed.json`, `envelope_session.json`: copied 2026-10-17 from the same commit, for I0.4;
  last commit touching them df79ca9fbc4b5cb8f3d08c17285c819e71b5fc07. Byte for byte the files vettid-android
  checks (its `SOURCE.md` lists the same hashes).
- `handshake.json` (last commit touching it 19c03153e2ecda009f449cb26d13929f34085783) and `invite.json`
  (df79ca9fbc4b5cb8f3d08c17285c819e71b5fc07): copied 2026-10-17 from the same commit, for I0.5; the same hashes as
  vettid-android's.
- `altchan.json` and `release.json` (last commit touching them 7480651a1c55a4827bbc36ee4807383bd9f47e49, "Release R
  3/3", vettid-vault #101): copied 2026-10-17 from the same commit, for I0.6. Newer than vettid-android's copies,
  which predate that commit: the unlock vector now carries release R's `unlock_secret` (the request body and the
  signing string's last line), and `release.json`'s `unlock_with_update` changed the same way.
- `unlock.json` and `recovery.json` from `testdata/vectors/`, and `verdicts.json` from `testdata/passwords/` (last
  commit touching them 3c260362ced30aaf0d061cf686708bf59ed47f37): copied 2026-10-17 from commit
  7f2c5b7bd8c6c04b6f46df610a6aa1f4d29104fe, for I0.7; the files above are unchanged at that commit. The iPhone's
  unlock secret (VAULT-MESSAGING 0.35.0 §11.14.1 "On an iPhone") has no vector file yet: `ReleaseRTests.swift`
  checks the values §16 states for it.
- `blob.json` and `attachment.json` (last commit touching them d95fb2fe65c81638b8f0bff6d05e5002549cf92d): copied
  2026-10-17 from commit 7f2c5b7bd8c6c04b6f46df610a6aa1f4d29104fe, for I0.8; the same hashes as vettid-android's.
- Each later PR adds the files it checks.

To refresh: copy the files again from a newer vettid-vault commit, update the commits
above and the hashes below, and run `swift test --package-path Packages/VettIDCrypto`.

`sha256sum` of the copied files:

```
3a21d9d6de082476eab7744ad971f31cb47806378c5abc34e07c7839c7ff34c5  altchan.json
a8d86c76b9469f26526f8238d41bd07a6b74fcce3da6035879fc5910c5f36427  attachment.json
a890582a80e24cea9e10523f01f2f0040924aa47cd66cd8c442c0a1577e284b3  blob.json
3ab4f20eebb3ec621e97d3b03705c8b3851312e99e227d423e8f0e6066887360  envelope_sealed.json
8cbf6324c294e6c99011bd3bd5f875fcd329cbe7be1e354b7be06f3c03044827  envelope_session.json
9b69503b507fd117ab3d6a66368cb60bb24e09286867921a6f473fb476fb0577  handshake.json
08fa20d793577a27196f37e9fe5f5222bbcd90e5adabc015679be3d98b47b226  hpke.json
6d7be9ba65f8426070ee54f0ea6ed84fed1e49c54eb31e09a1e177d3d5286d2f  invite.json
568c65595189051a6297653511acb27c88fed17257b985af070342d5bfc1660e  keys.json
157f89fb392ffb74f5cc76671f19b011cf8edd048faecc2ebf3a3d4b948d5eb4  recovery.json
8944c466cd00ce5d606f310e954b8d13fdd4d65d598062b3ecc05de6d310ad6f  release.json
0073c578252ba87960b74f6a1825b6dbb06f8762c77b7f8003d380b48c373905  unlock.json
09540a0c78b03fb03cfdee762066a9f1171419d2958798b5b4cf054f7dda66a5  verdicts.json
```
