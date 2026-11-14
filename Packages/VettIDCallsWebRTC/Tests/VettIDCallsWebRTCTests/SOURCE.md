# Where the test values come from

`FrameKeyTests.swift` holds four values inline (`kDirSuite1`, `frameKeySuite1`, `kDirSuite2`, `frameKeySuite2`). They are
the TEST ONLY direction and frame keys of VAULT-MESSAGING §10.10 and §16 (test vectors), "0.28.0" entry (the specification at
version 0.90.10, vettid.org commit `924731f865e85eaef03fabe25de54e5c116bca7a`, `docs/VAULT-MESSAGING.md`), which took them
from vettid-android `docs/calls/CALL-MEDIA.md` §8:

| value | what it is | spec line |
|---|---|---|
| `kDirSuite1` | `k_dir("caller")`, offered "1", chosen "1" | `df07dfb7…2c08` |
| `frameKeySuite1` | its frame key (suite 1, 16 bytes) | `df487aff…c2de` |
| `kDirSuite2` | `k_dir("caller")`, offered "2 1", chosen "2" | `129e7ea0…9617` |
| `frameKeySuite2` | its frame key (suite 2, 32 bytes) | `e2637ed9…83da` |

`Packages/VettIDCrypto` checks the same derivation against vettid-vault's `calls.json` (see its `SOURCE.md`); these four
values are checked here against the media stack's own cryptor, which is a different thing to reproduce.

Nothing else here is a vector: the keys of the loopback tests are random.

The two frame keys are allowlisted for gitleaks in `/.gitleaks.toml`, as in vettid-android's file (public, TEST ONLY, printed in the
specification).
