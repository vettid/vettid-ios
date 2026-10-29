#!/usr/bin/env bash
# Archives a build for TestFlight (IOS-PLAN §8 I4): the Staging configuration by default, signed by Xcode's automatic
# signing with the account it is signed in to, with a build number that grows with each archive: the UTC time,
# yyyymmddHHMM. App Store Connect refuses a second upload with the same version and build number; MARKETING_VERSION
# stays in project.yml. Uploading is left to Xcode's Organizer (Validate App first, then Distribute App), which the
# owner does.
#
#   scripts/testflight-archive.sh [Staging|Release]
set -euo pipefail
cd "$(dirname "$0")/.."

config=${1:-Staging}
case "${config}" in Staging | Release) ;; *) echo "usage: $0 [Staging|Release]" >&2; exit 2 ;; esac

build=$(date -u +%Y%m%d%H%M)
out="${HOME}/Library/Developer/Xcode/Archives/${build:0:4}-${build:4:2}-${build:6:2}/VettID-${config}-${build}.xcarchive"

xcodebuild archive \
  -project VettID.xcodeproj -scheme VettID -configuration "${config}" \
  -destination 'generic/platform=iOS' \
  -archivePath "${out}" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="${build}" \
  -quiet

app="${out}/Products/Applications/VettID.app"
icon=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "${app}/Info.plist")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${app}/Info.plist")
[[ -f "${app}/PrivacyInfo.xcprivacy" ]] || { echo "no PrivacyInfo.xcprivacy in ${app}" >&2; exit 1; }
[[ "${version}" == "${build}" ]] || { echo "build number ${version}, expected ${build}" >&2; exit 1; }
echo "archived ${config} build ${build} (icon ${icon}): ${out}"
echo "next: Xcode > Window > Organizer > Archives: Validate App, then Distribute App"
