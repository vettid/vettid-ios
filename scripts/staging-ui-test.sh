#!/usr/bin/env bash
# Staging end-to-end UI tests on a real iPhone (STAGING-TESTING §3 "Enrolling a phone", §5): builds the Staging app and
# the UI tests once (VettIDStagingUITests scheme), then runs one test of AppUITests/StagingTests.swift on the iPhone with
# the inputs handed to the test runner at run time. Nothing secret is in the repository; this script issues no codes:
# the enrollment code comes from the account site's "Enroll a phone", signed in as the test member, just before the run
# (it lives 5 minutes and works once).
#
#   scripts/staging-ui-test.sh --device <id> --test <test> [--inputs <file>] [--fresh] [--skip-build] [--keep-result]
#
#   --device <id>     the iPhone (`xcrun devicectl list devices`)
#   --test <test>     testStagingEnroll or testStagingUnlockLock
#   --inputs <file>   a private file outside the repository (chmod 600) with lines NAME=value for
#                     VETTID_STAGING_EMAIL, VETTID_STAGING_CODE, VETTID_STAGING_PIN, VETTID_STAGING_PASSWORD; without it
#                     they are read from the environment of the same names. Prefer the file: nothing lands in the shell
#                     history. Values in the file override the environment.
#   --fresh           remove VettID Staging from the iPhone first (its vault keys go with it): for testStagingEnroll
#   --skip-build      reuse the last build-for-testing
#   --keep-result     keep the result bundle (it holds what was typed) in the private cache directory
#
# A test without its inputs is skipped. The inputs are handed over as TEST_RUNNER_<NAME> (xcodebuild passes them to the
# runner as <NAME>), never on a command line; xcodebuild's output is shown with them (and the keypad's digits) redacted;
# the result bundle is deleted unless --keep-result. The build and results live under
# ${XDG_CACHE_HOME:-~/Library/Caches}/vettid-ios/staging-ui-test (mode 700).
#
# Example (enrollment; the code was issued a minute ago and is in the private file):
#   scripts/staging-ui-test.sh --device <id> --test testStagingEnroll --inputs ~/private/vettid-ios15.env --fresh
set -euo pipefail

cd "$(dirname "$0")/.."
REPO=$(pwd -P)

NAMES=(VETTID_STAGING_EMAIL VETTID_STAGING_CODE VETTID_STAGING_PIN VETTID_STAGING_PASSWORD)
BUNDLE_ID=com.vettid.app.staging

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }

DEVICE="" TEST="" INPUTS="" FRESH=0 SKIP_BUILD=0 KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE=${2:-}; shift 2 ;;
    --test) TEST=${2:-}; shift 2 ;;
    --inputs) INPUTS=${2:-}; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --keep-result) KEEP=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[[ -n "${DEVICE}" ]] || { echo "--device is required" >&2; usage; }
case "${TEST}" in
  testStagingEnroll|testStagingUnlockLock) ;;
  *) echo "--test must be testStagingEnroll or testStagingUnlockLock" >&2; usage ;;
esac

# The private input file: outside the repository (so that it can never be committed), readable by its owner only.
if [[ -n "${INPUTS}" ]]; then
  [[ -f "${INPUTS}" ]] || { echo "no such input file: ${INPUTS}" >&2; exit 1; }
  file=$(cd "$(dirname "${INPUTS}")" && pwd -P)/$(basename "${INPUTS}")
  if [[ "${file}" == "${REPO}" || "${file}" == "${REPO}/"* ]]; then
    echo "refusing: the input file is inside the repository; keep it in a private place outside it" >&2
    exit 1
  fi
  if (( 8#$(stat -f %Lp "${file}") & 8#077 )); then
    echo "refusing: the input file is readable by others; chmod 600 it" >&2
    exit 1
  fi
  # NAME=value lines, read as data (never sourced); blank lines and # comments are ignored.
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    name=${line%%=*}
    value=${line#*=}
    known=0
    for n in "${NAMES[@]}"; do [[ "${name}" == "${n}" ]] && known=1; done
    [[ ${known} -eq 1 ]] || { echo "unknown name in the input file: ${name}" >&2; exit 1; }
    printf -v "${name}" '%s' "${value}"
    export "${name?}"
  done <"${file}"
fi

missing=()
for n in "${NAMES[@]}"; do [[ -n "${!n:-}" ]] || missing+=("${n}"); done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "note: not set: ${missing[*]} (a test without its inputs is skipped)"
fi

CACHE="${XDG_CACHE_HOME:-${HOME}/Library/Caches}/vettid-ios/staging-ui-test"
mkdir -p "${CACHE}/results"
chmod 700 "${CACHE}" "${CACHE}/results"
DERIVED="${CACHE}/DerivedData"
DEST="platform=iOS,id=${DEVICE}"

if [[ ${SKIP_BUILD} -eq 0 ]]; then
  echo "== build-for-testing (Staging)"
  xcodebuild build-for-testing \
    -project VettID.xcodeproj -scheme VettIDStagingUITests -configuration Staging \
    -destination "${DEST}" -derivedDataPath "${DERIVED}" -allowProvisioningUpdates -quiet
fi

if [[ ${FRESH} -eq 1 ]]; then
  echo "== removing ${BUNDLE_ID} from the iPhone"
  xcrun devicectl device uninstall app --device "${DEVICE}" "${BUNDLE_ID}" >/dev/null 2>&1 ||
    echo "(it was not installed)"
fi

# The runner's inputs, through the environment only.
for n in "${NAMES[@]}"; do
  if [[ -n "${!n:-}" ]]; then export "TEST_RUNNER_${n}=${!n}"; fi
done

RESULT="${CACHE}/results/${TEST}-$(date +%Y%m%d-%H%M%S).xcresult"
echo "== ${TEST} on the iPhone"
set +e
xcodebuild test-without-building \
  -project VettID.xcodeproj -scheme VettIDStagingUITests -configuration Staging \
  -destination "${DEST}" -derivedDataPath "${DERIVED}" \
  -only-testing:"VettIDAppUITests/StagingTests/${TEST}" \
  -resultBundlePath "${RESULT}" 2>&1 |
  perl -pe '
    BEGIN { @s = grep { length } map { $ENV{$_} // "" } qw(VETTID_STAGING_EMAIL VETTID_STAGING_CODE VETTID_STAGING_PIN VETTID_STAGING_PASSWORD) }
    for my $v (@s) { s/\Q$v\E/<redacted>/g }
    s/Type .*? into/Type <redacted> into/g;
    s/pin_[0-9]/pin_#/g;
  '
status=${PIPESTATUS[0]}
set -e

if [[ ${KEEP} -eq 1 ]]; then
  echo "result bundle (private; it holds what was typed): ${RESULT}"
else
  rm -rf "${RESULT}"
fi
exit "${status}"
