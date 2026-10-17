# VettID iOS

The VettID iPhone app.

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)

> **Being rebuilt.** The app is being rebuilt for VettID's 2.0
> architecture, as the Android app ([vettid-android](https://github.com/vettid/vettid-android))
> was. The plan is [IOS-PLAN](https://github.com/vettid/vettid.org/blob/master/docs/IOS-PLAN.md)
> in the vettid.org repository; the phases are tracked as issues here.
> The first implementation (the old NATS architecture) is kept on the
> branch `legacy/v1`, tag `legacy-v1-final`.

## Requirements

- Xcode 26 or later (developed with Xcode 27.0; CI uses the default Xcode
  of GitHub's `macos-26` runner)
- iOS 17 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0, SwiftLint
  0.65.1 and gitleaks 8.30.1 (`brew install xcodegen swiftlint gitleaks`)

## Layout

```
App/                    the app target (SwiftUI); App/Debug: the debug catalog and gallery
AppTests/               the app's unit tests
AppUITests/             screenshots of the component gallery (VettIDScreenshots scheme)
Config/                 one xcconfig per build configuration; Signing.xcconfig
Packages/               one local Swift package per Android core module
  VettIDCrypto          pure: swift test on macOS
  VettIDAttestation     pure
  VettIDRelay           pure
  VettIDAltChan         pure
  VettIDVault           pure
  VettIDKeys            iOS only
  VettIDData            iOS only
  VettIDMedia           iOS only
  VettIDNotify          iOS only
  VettIDUI              iOS only
  VettIDTesting         TEST ONLY: test targets, never the app
scripts/                release check, simulator selection
project.yml             XcodeGen spec of VettID.xcodeproj
```

`VettID.xcodeproj` is generated from `project.yml`. After changing
`project.yml`, run `xcodegen generate` and commit both; CI fails if they
differ.

## Build configurations

| Configuration | Bundle id | Name | Talks to |
|---|---|---|---|
| Release | `com.vettid.app` | VettID | production |
| Staging | `com.vettid.app.staging` | VettID Staging | staging |
| Debug | `com.vettid.app.dev` | VettID Dev | staging (the dev stack, chosen at launch, from I1) |
| DevStack | `com.vettid.app.devstack` | VettID Dev Stack | the local dev stack |

All four install side by side.

## Build and test

```bash
# pure packages (no simulator)
swift test --package-path Packages/VettIDCrypto

# the app and every package's tests on a simulator
xcodebuild test -project VettID.xcodeproj -scheme VettID \
  -destination "$(scripts/simulator-destination.sh)" \
  -parallel-testing-worker-count 2

# Release and Staging archives (unsigned) checked for TEST, dev-stack and
# other-environment strings; --self-test also proves the check fails
scripts/release-check.sh --self-test

swiftlint lint --strict
```

Signing is automatic in Xcode; the team is set in
`Config/Signing.xcconfig` and nowhere else.

## Debug catalog and component gallery

Debug and DevStack builds have a **Screen catalog** button on the root screen,
leading to the **Component gallery**: every `VettIDUI` component with sample
data, in the chosen theme (the counterpart of the Android debug gallery). Open
it directly at launch with `-vettid.start gallery`, and force a theme with
`-vettid.theme dark` or `-vettid.theme light`. None of it is compiled into
Staging or Release builds, and the release check refuses its strings.

The `VettIDScreenshots` scheme (not run by CI) scrolls through the gallery and
keeps screenshots in the result bundle, in the dark and light themes and at the
largest accessibility text size:

```bash
xcodebuild test -project VettID.xcodeproj -scheme VettIDScreenshots \
  -destination "$(scripts/simulator-destination.sh)" -resultBundlePath build/screens.xcresult
xcrun xcresulttool export attachments --path build/screens.xcresult --output-path build/screens
```

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).
