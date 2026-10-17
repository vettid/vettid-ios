# CLAUDE.md

Guidance for Claude Code in this repository.

## What this is

The VettID iPhone app, **being rebuilt for the 2.0 architecture** (the
vault in AWS Nitro Enclaves, the relay, the alternate channel, the
Protean Credential of VAULT-MESSAGING §3.5), the counterpart of the
rebuilt Android app (`vettid/vettid-android`, branch `master`).

The **first implementation of the old architecture** (NATS, "cloud
status", the old enrollment and credential) is on the branch `legacy/v1`
(tag `legacy-v1-final`); I0.1 removed it from `master`. It does not work
with the current vault. Port nothing from it except what the plan names,
and then rewrite it against the spec with its tests.

## The plan and the specifications

- **The plan: `docs/IOS-PLAN.md` in `vettid/vettid.org`**, on `master`:
  <https://github.com/vettid/vettid.org/blob/master/docs/IOS-PLAN.md>.
  It gives the decisions (§2), the package layout and the Android files
  to mirror (§5), the iOS-specific rules (§6), the test vectors (§7),
  the phases and their PRs with acceptance tests (§8), what blocks what,
  and getting started on the Mac (§12).
- The app's contract with the vault: `docs/VAULT-MESSAGING.md` in
  vettid.org. Also `ANDROID-PLAN.md` (screens, texts, behaviour),
  `RELAY-PROTOCOL.md`, `MEMBER-API.md`, `ENROLLMENT-CODES.md`,
  `VAULT-LOCK.md`, `VAULT-ITEMS.md`, `RELEASE-UPDATES.md`,
  `PUSH-GATEWAY.md` §11.2.
- The reference implementation for every screen, text and state is the
  Android app on `master`. Where it and ANDROID-PLAN differ, follow the
  code and say so in the PR.
- The phases are tracked as issues in this repository (one per phase).
- Issue #39 (the App IDs) is done; I0 is issue #34.

## How to work

- **Small PRs**, one per row of IOS-PLAN §8 (I0.1, I0.2, …), titled with
  the phase (`I1.4: Secure Enclave keys and App Attest`). Each PR has
  its tests and they pass locally before it is pushed. Never merge: the
  owner merges.
- Only this repository is written to. Clone `vettid-android`,
  `vettid-vault` and `vettid.org` to read.
- **Test vectors**: the crypto code must reproduce vettid-vault's
  `testdata/vectors/` (and the other files of IOS-PLAN §7) byte for
  byte. Copy them with a `SOURCE.md` naming the source commit and each
  file's `sha256sum`. A vector that fails is a stop-and-report item;
  never edit a vector or skip its test.
- **Builds and tests** (one `xcodebuild` at a time, test parallelism
  capped):

  ```bash
  # pure Swift packages (no simulator)
  swift test --package-path Packages/VettIDCrypto

  # the app and every package's tests on a simulator
  xcodebuild test -project VettID.xcodeproj -scheme VettID \
    -destination "$(scripts/simulator-destination.sh)" \
    -parallel-testing-worker-count 2

  # Release and Staging archives checked for TEST, dev-stack and
  # other-environment strings
  scripts/release-check.sh --self-test

  swiftlint lint --strict

  # on the connected iPhone (device id from `xcrun devicectl list devices`)
  xcodebuild test -project VettID.xcodeproj -scheme VettID -configuration Debug \
    -destination 'platform=iOS,id=<device id>' -allowProvisioningUpdates
  ```

- **The Xcode project is generated** from `project.yml` with XcodeGen.
  Add files, packages and settings there, run `xcodegen generate`, and
  commit both; never edit `VettID.xcodeproj` by hand. CI fails when they
  differ.
- **Spec questions go to the owner**: open an issue in
  `vettid/vettid.org` titled `IOS-PLAN: …`, or comment on the relevant
  vettid.org PR. Never edit a specification. Where a spec is silent,
  choose, mark it "(chosen; not in the spec)" in the PR, and ask.

## Public text

Commits, PR texts, issues and code comments are public:

- never mention reviews, finding ids, private files, local paths outside
  this repository, or device serials;
- cite specifications by document and section (`VAULT-MESSAGING
  §11.7`).

## Commit and PR conventions

- Every commit message ends with the `Co-Authored-By:` line for the
  model and the `Claude-Session:` line with the session link, exactly as
  the harness provides them.
- Every PR body ends with the "🤖 Generated with [Claude Code]" line and
  the session link.
- No other attribution.

## Secrets and the team ID

- Nothing secret is committed: no signing certificates, `.p12`, `.p8`,
  provisioning profiles, API keys, member data or real attestation
  objects. Never create, read or ask for signing material: Xcode on the
  Mac is signed in to the owner's account and signs automatically.
- The Apple team ID appears **only** in `Config/Signing.xcconfig`
  (`DEVELOPMENT_TEAM = 3X25CJ86MV`, the owner's team, IOS-PLAN ID3), never in
  code, tests or other configuration.

## Security rules that apply from the first line

- Keys per IOS-PLAN §6.1: Secure Enclave keys and the App Attest key,
  `ThisDeviceOnly`, never synchronizable, never bound to biometry or the
  passcode (except the app-lock key); data excluded from backups.
- No autofill or "Save Password?" on any secret field, third-party
  keyboards refused, the PIN on an in-app keypad (IOS-PLAN §6.5).
- App-switcher cover and capture hiding always on (IOS-PLAN §6.4).
- Never log keys, secrets, attestation objects, assertions, codes or
  message content.
