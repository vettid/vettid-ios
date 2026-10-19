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
#   --test <test>     testStagingEnroll, testStagingUnlockLock, testStagingApproveUpdate or
#                     testStagingApproveUpdateAtUnlock
#   --inputs <file>   a private file outside the repository (chmod 600) with lines NAME=value for
#                     VETTID_STAGING_EMAIL, VETTID_STAGING_CODE, VETTID_STAGING_PIN, VETTID_STAGING_PASSWORD (quotes
#                     around a value and CRLF line ends are stripped); only the file is read then. Without it they are
#                     read from the environment of the same names. Prefer the file: nothing lands in the shell history.
#   --fresh           remove VettID Staging from the iPhone first, and its vault keys with it: only for
#                     testStagingEnroll with all four inputs set; asks y/N on a terminal
#   --skip-build      reuse the last build-for-testing
#   --keep-result     keep the result bundle (it holds what was typed) in the private cache directory
#
# A test without its inputs is skipped. The inputs reach only the test step, as TEST_RUNNER_<NAME> (xcodebuild passes
# them to the runner as <NAME>), never a command line or the build; xcodebuild's output is shown with them (and the
# keypad's digits) redacted; the result bundle is deleted, an interrupted run's too, unless --keep-result. The build and
# results live under ${XDG_CACHE_HOME:-~/Library/Caches}/vettid-ios/staging-ui-test (mode 700).
#
# Example (enrollment; the code was issued a minute ago and is in the private file):
#   scripts/staging-ui-test.sh --device <id> --test testStagingEnroll --inputs <private file> --fresh
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
  testStagingEnroll|testStagingUnlockLock|testStagingApproveUpdate|testStagingApproveUpdateAtUnlock) ;;
  *) echo "--test must be testStagingEnroll, testStagingUnlockLock, testStagingApproveUpdate or testStagingApproveUpdateAtUnlock" >&2
     usage ;;
esac

# The inputs are kept in IN_<NAME>, unexported, and the variables of the same names leave the environment: nothing the
# build runs sees them.
for n in "${NAMES[@]}"; do
  if [[ -z "${INPUTS}" ]]; then printf -v "IN_${n}" '%s' "${!n:-}"; else printf -v "IN_${n}" '%s' ""; fi
  unset "${n}"
done

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
    line=${line%$'\r'}
    [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    name=${line%%=*}
    value=${line#*=}
    if [[ ${#value} -ge 2 && ( ( "${value:0:1}" == '"' && "${value: -1}" == '"' ) ||
      ( "${value:0:1}" == "'" && "${value: -1}" == "'" ) ) ]]; then
      value=${value:1:${#value}-2}
    fi
    known=0
    for n in "${NAMES[@]}"; do [[ "${name}" == "${n}" ]] && known=1; done
    [[ ${known} -eq 1 ]] || { echo "unknown name in the input file: ${name}" >&2; exit 1; }
    printf -v "IN_${name}" '%s' "${value}"
  done <"${file}"
fi

missing=()
for n in "${NAMES[@]}"; do v="IN_${n}"; [[ -n "${!v}" ]] || missing+=("${n}"); done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "note: not set: ${missing[*]} (a test without its inputs is skipped)"
fi

# --fresh deletes the app's vault keys: only for an enrollment that will run.
if [[ ${FRESH} -eq 1 ]]; then
  if [[ "${TEST}" != testStagingEnroll || ${#missing[@]} -gt 0 ]]; then
    echo "refusing --fresh: it is only for testStagingEnroll with all four inputs set" >&2
    exit 1
  fi
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
  name=$(xcrun devicectl list devices 2>/dev/null | grep -F -- "${DEVICE}" | head -1 | sed -E 's/ {2,}.*//' || true)
  apps=$(xcrun devicectl device info apps --device "${DEVICE}" --bundle-id "${BUNDLE_ID}" 2>&1) || {
    echo "could not list the apps on the iPhone:" >&2
    echo "${apps}" >&2
    exit 1
  }
  if grep -qF -- "${BUNDLE_ID}" <<<"${apps}"; then
    echo "== removing ${BUNDLE_ID} (and its vault keys) from the iPhone \"${name:-unknown}\""
    if [[ -t 0 ]]; then
      read -r -p "Remove it? [y/N] " answer
      [[ "${answer}" == [yY] || "${answer}" == [yY][eE][sS] ]] || { echo "not removed; stopping"; exit 1; }
    fi
    out=$(xcrun devicectl device uninstall app --device "${DEVICE}" "${BUNDLE_ID}" 2>&1) || {
      echo "removing the app failed:" >&2
      echo "${out}" >&2
      exit 1
    }
  else
    echo "== ${BUNDLE_ID} is not installed on the iPhone \"${name:-unknown}\""
  fi
fi

# The runner's inputs, from here on and through the environment only.
for n in "${NAMES[@]}"; do
  v="IN_${n}"
  if [[ -n "${!v}" ]]; then export "TEST_RUNNER_${n}=${!v}"; fi
done

RESULT="${CACHE}/results/${TEST}-$(date +%Y%m%d-%H%M%S).xcresult"
if [[ ${KEEP} -eq 0 ]]; then
  # The bundle holds what was typed: it goes however the run ends.
  trap 'rm -rf "${RESULT}"' EXIT
  trap 'exit 130' INT TERM
fi
echo "== ${TEST} on the iPhone"
set +e
xcodebuild test-without-building \
  -project VettID.xcodeproj -scheme VettIDStagingUITests -configuration Staging \
  -destination "${DEST}" -derivedDataPath "${DERIVED}" \
  -only-testing:"VettIDAppUITests/StagingTests/${TEST}" \
  -resultBundlePath "${RESULT}" 2>&1 |
  perl -pe '
    BEGIN {
      @s = grep { length } map { $ENV{"TEST_RUNNER_$_"} // "" }
        qw(VETTID_STAGING_EMAIL VETTID_STAGING_CODE VETTID_STAGING_PIN VETTID_STAGING_PASSWORD)
    }
    for my $v (@s) { s/\Q$v\E/<redacted>/g }
    s/Type .*? into/Type <redacted> into/g;
    s/pin_[0-9]/pin_#/g;
  '
status=${PIPESTATUS[0]}
set -e

if [[ ${KEEP} -eq 1 ]]; then
  echo "result bundle (private; it holds what was typed): ${RESULT}"
fi
exit "${status}"
