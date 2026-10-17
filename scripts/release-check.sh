#!/usr/bin/env bash
# Release check (IOS-PLAN §5, I0.1): the counterpart of vettid-android's
# checkReleaseApk and checkStagingApk.
#
# Archives the Release and Staging configurations unsigned and fails when
# either app carries:
#   - a TEST-only marker (the VettIDTesting package, the TEST attester's
#     App ID),
#   - a dev-stack address or a debug-only tool,
#   - the other environment's hosts,
# or lacks its own account host, or has another bundle id.
#
#   scripts/release-check.sh              build both, check both
#   scripts/release-check.sh --self-test  also plant a TEST string and a
#                                         staging host in a copy of each
#                                         app and require the check to fail
set -euo pipefail

cd "$(dirname "$0")/.."

OUT=build/release-check
SELF_TEST=0
[[ "${1:-}" == "--self-test" ]] && SELF_TEST=1

# Strings no Release or Staging app may contain.
# The deterministic randomness hook of VettIDCrypto (debug builds only) carries this string.
TEST_MARKERS=("VettIDTesting" "TESTTEAM00" "VETTID TEST ONLY")
DEV_ONLY=("127.0.0.1" "relay.vettid.test" "vettid.start" "vettid.theme" "Component gallery" "Screen catalog")

PRODUCTION_HOSTS=("account.vettid.org")
STAGING_HOSTS=("staging.vettid.org")

archive() {
  local config=$1
  echo "== archiving ${config} (unsigned)"
  xcodebuild archive \
    -project VettID.xcodeproj -scheme VettID -configuration "${config}" \
    -destination 'generic/platform=iOS' \
    -archivePath "${OUT}/${config}.xcarchive" \
    -derivedDataPath "${OUT}/DerivedData" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
    -quiet
}

# Everything readable in an app bundle: printable strings of each Mach-O
# file, property lists as XML, and every other file as is.
bundle_text() {
  local app=$1
  find "${app}" -type f -print0 | while IFS= read -r -d '' f; do
    if file -b "${f}" | grep -q 'Mach-O'; then
      strings -a "${f}"
    elif [[ "${f}" == *.plist ]]; then
      plutil -convert xml1 -o - "${f}" 2>/dev/null || cat "${f}"
    else
      cat "${f}"
    fi
  done
}

# check_app <app> <expected bundle id> <required...> -- <forbidden...>
check_app() {
  local app=$1 bundle_id=$2
  shift 2
  local required=() forbidden=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do required+=("$1"); shift; done
  shift
  forbidden=("$@")

  local text
  text=$(mktemp)
  bundle_text "${app}" >"${text}"

  local problems=()
  local actual
  actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app}/Info.plist")
  [[ "${actual}" == "${bundle_id}" ]] || problems+=("bundle id ${actual}, expected ${bundle_id}")
  for s in "${required[@]}"; do
    grep -qF -- "${s}" "${text}" || problems+=("missing '${s}'")
  done
  for s in "${forbidden[@]}"; do
    grep -qF -- "${s}" "${text}" && problems+=("forbidden '${s}'")
  done
  rm -f "${text}"

  if [[ ${#problems[@]} -gt 0 ]]; then
    printf '%s: %s\n' "${app}" "${problems[@]}" >&2
    return 1
  fi
  echo "${app}: ${#forbidden[@]} forbidden strings absent, ${#required[@]} required present"
}

check_release() {
  check_app "$1" com.vettid.app "${PRODUCTION_HOSTS[@]}" \
    -- "${TEST_MARKERS[@]}" "${DEV_ONLY[@]}" "${STAGING_HOSTS[@]}"
}

check_staging() {
  check_app "$1" com.vettid.app.staging "account.staging.vettid.org" \
    -- "${TEST_MARKERS[@]}" "${DEV_ONLY[@]}" "${PRODUCTION_HOSTS[@]}"
}

app_of() { echo "${OUT}/$1.xcarchive/Products/Applications/VettID.app"; }

# The test-only hooks of the pure packages are compiled into debug builds only (#if DEBUG). The app may not link a
# package's code yet (it is then dead-stripped and the scan above proves nothing), so the packages are also built on
# their own: the release build must not contain the marker, and the debug build must (or the scan finds nothing).
# The package's compiled objects under a SwiftPM bin path, in either build system's layout; fails when there are none.
package_objects() {
  local bin=$1 pkg=$2 files
  files=$(find "${bin}" -maxdepth 1 \( -name "${pkg}.o" -o -name "lib${pkg}.a" \) 2>/dev/null)
  [[ -z "${files}" && -d "${bin}/${pkg}.build" ]] && files=$(find "${bin}/${pkg}.build" -name '*.o')
  if [[ -z "${files}" ]]; then
    echo "no compiled objects of ${pkg} under ${bin}" >&2
    return 1
  fi
  echo "${files}"
}

check_package_hooks() {
  local pkg=$1 marker=$2
  echo "== ${pkg}: test hooks in debug builds only"
  swift build --package-path "Packages/${pkg}" -c debug --quiet
  swift build --package-path "Packages/${pkg}" -c release --quiet
  local found_debug found_release debug_bin release_bin
  debug_bin=$(swift build --package-path "Packages/${pkg}" -c debug --show-bin-path)
  release_bin=$(swift build --package-path "Packages/${pkg}" -c release --show-bin-path)
  found_debug=$(package_objects "${debug_bin}" "${pkg}" | xargs strings -a | grep -cF -- "${marker}" || true)
  found_release=$(package_objects "${release_bin}" "${pkg}" | xargs strings -a | grep -cF -- "${marker}" || true)
  if [[ "${found_debug}" -eq 0 ]]; then
    echo "${pkg}: the debug build lacks the marker '${marker}'; the check would prove nothing" >&2
    return 1
  fi
  if [[ "${found_release}" -ne 0 ]]; then
    echo "${pkg}: the release build contains the test hook ('${marker}')" >&2
    return 1
  fi
  echo "${pkg}: test hook present in debug, absent in release"
}

check_package_hooks VettIDCrypto "VETTID TEST ONLY"

rm -rf "${OUT}/Release.xcarchive" "${OUT}/Staging.xcarchive"
archive Release
archive Staging
check_release "$(app_of Release)"
check_staging "$(app_of Staging)"

# Every object file the two archives compiled (the app's and every package's, before the linker strips unused code)
# is free of the TEST markers too.
echo "== objects compiled for the Release and Staging archives"
objects=$(find "${OUT}/DerivedData/Build/Intermediates.noindex" -name '*.o' | wc -l | tr -d ' ')
[[ "${objects}" -gt 0 ]] || { echo "no compiled objects under ${OUT}/DerivedData" >&2; exit 1; }
for marker in "${TEST_MARKERS[@]}"; do
  if find "${OUT}/DerivedData/Build/Intermediates.noindex" -name '*.o' -exec strings -a {} + | grep -qF -- "${marker}"; then
    echo "an object compiled for Release or Staging contains '${marker}'" >&2
    exit 1
  fi
done
echo "${objects} objects: ${#TEST_MARKERS[@]} TEST markers absent"

if [[ ${SELF_TEST} -eq 1 ]]; then
  # plant <config> <checker> <string>: the check must refuse a copy of the
  # app that carries <string>.
  plant() {
    local config=$1 checker=$2 planted=$3
    local copy="${OUT}/planted/${config}/VettID.app"
    rm -rf "${OUT}/planted/${config}"
    mkdir -p "$(dirname "${copy}")"
    cp -R "$(app_of "${config}")" "${copy}"
    printf '%s\n' "${planted}" >"${copy}/planted.txt"
    if "${checker}" "${copy}" 2>/dev/null; then
      echo "self-test FAILED: ${config} accepted a planted '${planted}'" >&2
      exit 1
    fi
    echo "self-test: ${config} refuses a planted '${planted}'"
  }
  plant Release check_release "VettIDTesting"
  plant Release check_release "VETTID TEST ONLY: deterministic randomness drew the wrong size"
  plant Release check_release "account.staging.vettid.org"
  plant Staging check_staging "TESTTEAM00.com.vettid.app"
  plant Staging check_staging "127.0.0.1"
fi

echo "release check passed"
