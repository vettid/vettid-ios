#!/usr/bin/env bash
# A member-site sign-in approved on a real iPhone, end to end (MEMBER-API sign-in, VAULT-MESSAGING §10.4): starts the
# sign-in on the staging member service as the test member, runs testStagingSignIn on the iPhone with the match code
# the site returned, and polls the site until the sign-in reads "approved". The test member must already be connected
# to the member service (the Connect flow of the site, accepted on the phone).
#
#   scripts/staging-signin-test.sh --device <id> --inputs <file> [--email-from <file>] [--lock-cycle] [--build]
#                                  [--skip-build] [--keep-result] [--timeout <seconds>]
#
#   --device <id>        the iPhone (`xcrun devicectl list devices`)
#   --inputs <file>      a private file outside the repository (chmod 600) with VETTID_STAGING_PIN and
#                        VETTID_STAGING_PASSWORD, and VETTID_STAGING_EMAIL (the test member's address) unless
#                        --email-from names the file that has it
#   --email-from <file>  a private file with the VETTID_STAGING_EMAIL line (only that line is read)
#   --lock-cycle         the test locks and unlocks the vault before it looks for the request, which must still be
#                        listed (pending.list, VAULT-MESSAGING §10.4.2)
#   --build              build the Staging app and the tests first (through scripts/staging-ui-test.sh, whose test is
#                        skipped without inputs), before the sign-in starts, so that its minutes are not spent building
#   --skip-build         reuse the last build-for-testing (one of --build and --skip-build is required)
#   --keep-result        keep the result bundle (see scripts/staging-ui-test.sh)
#   --timeout <s>        how long to poll the site after the test (60)
#
# The sign-in costs one of the site's 30 starts per client address per hour; this script starts one and never retries.
# The address, the match code and the cookie never reach the command line, the output or the repository: the match code
# goes to the test through a temporary copy of the inputs (mode 600, in a private temporary directory that is removed
# however the run ends), and the cookie lives in the same directory. The output holds the site's status words and the
# test's own lines.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO=$(pwd -P)
HOST=${VETTID_MEMBER_HOST:-member.staging.vettid.org}

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }

DEVICE="" INPUTS="" EMAIL_FROM="" CYCLE=0 BUILD=0 SKIP=0 KEEP=0 TIMEOUT=60
need() { [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "$1 needs a value (see --help)" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) need "$1" "${2:-}"; DEVICE=${2:-}; shift 2 ;;
    --inputs) need "$1" "${2:-}"; INPUTS=${2:-}; shift 2 ;;
    --email-from) need "$1" "${2:-}"; EMAIL_FROM=${2:-}; shift 2 ;;
    --lock-cycle) CYCLE=1; shift ;;
    --build) BUILD=1; shift ;;
    --skip-build) SKIP=1; shift ;;
    --keep-result) KEEP=1; shift ;;
    --timeout) need "$1" "${2:-}"; TIMEOUT=${2:-}; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[[ "${HOST}" =~ ^[a-z0-9.-]+\.staging\.vettid\.org$ ]] || { echo "refusing: VETTID_MEMBER_HOST must be a host name ending in .staging.vettid.org" >&2; exit 1; }
if [[ ${BUILD} -eq 0 && ${SKIP} -eq 0 ]]; then echo "give --build (build first) or --skip-build (reuse the last build)" >&2; exit 2; fi
[[ -n "${DEVICE}" && -n "${INPUTS}" ]] || { echo "--device and --inputs are required" >&2; usage; }
[[ "${TIMEOUT}" =~ ^[0-9]+$ ]] || { echo "--timeout is a number of seconds" >&2; exit 2; }

private_file() {
  [[ -f "$1" ]] || { echo "no such input file: $1" >&2; exit 1; }
  local file
  file=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
  if [[ "${file}" == "${REPO}" || "${file}" == "${REPO}/"* ]]; then
    echo "refusing: an input file is inside the repository" >&2; exit 1
  fi
  if (( 8#$(stat -f %Lp "${file}") & 8#077 )); then
    echo "refusing: an input file is readable by others; chmod 600 it" >&2; exit 1
  fi
}
private_file "${INPUTS}"
if [[ -n "${EMAIL_FROM}" ]]; then private_file "${EMAIL_FROM}"; fi

# The address: one line of a private file, read as data.
email_line() { grep -E '^VETTID_STAGING_EMAIL=' "$1" | head -1 | cut -d= -f2- | tr -d "\"'\r" || true; }
EMAIL=$(email_line "${EMAIL_FROM:-${INPUTS}}")
[[ -n "${EMAIL}" ]] || { echo "no VETTID_STAGING_EMAIL in the inputs (or --email-from)" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/vettid-signin.XXXXXX")
chmod 700 "${WORK}"
trap 'rm -rf "${WORK}"' EXIT
trap 'exit 130' INT TERM HUP

if [[ ${BUILD} -eq 1 ]]; then
  echo "== build (Staging)"
  scripts/staging-ui-test.sh --device "${DEVICE}" --test testStagingSignIn
  SKIP=1
fi

# Calls the site with the cookie jar; a body goes in through a file, so that the address is not on a command line.
call() { # method path [body file]
  local args=(-sS --max-time 30 -b "${WORK}/jar" -c "${WORK}/jar" -X "$1" -H 'Content-Type: application/json'
    -o "${WORK}/out" -w '%{http_code}' "https://${HOST}$2")
  if [[ -n "${3:-}" ]]; then args+=(--data-binary "@$3"); fi
  curl "${args[@]}"
}
json() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "${WORK}/out" "$1"; }

printf '{"email":"%s"}' "${EMAIL}" >"${WORK}/body"
echo "== sign-in start on ${HOST}"
code=$(call POST /api/signin/start "${WORK}/body")
rm -f "${WORK}/body"
if [[ "${code}" != 202 ]]; then
  echo "sign-in start answered ${code} ($(json error))" >&2
  exit 1
fi
MATCH=$(json match_code)
[[ -n "${MATCH}" ]] || { echo "sign-in start gave no match code" >&2; exit 1; }
echo "sign-in started; the match code goes to the test (not printed)"

# The test's inputs: the private file, the match code and the options, in a temporary copy.
IN="${WORK}/inputs"
grep -v -E '^(VETTID_STAGING_MATCH_CODE|VETTID_STAGING_SIGNIN_LOCK)=' "${INPUTS}" >"${IN}" || true
printf '\nVETTID_STAGING_MATCH_CODE=%s\n' "${MATCH}" >>"${IN}"
if [[ ${CYCLE} -eq 1 ]]; then printf 'VETTID_STAGING_SIGNIN_LOCK=1\n' >>"${IN}"; fi
chmod 600 "${IN}"

args=(--device "${DEVICE}" --test testStagingSignIn --inputs "${IN}")
if [[ ${SKIP} -eq 1 ]]; then args+=(--skip-build); fi
if [[ ${KEEP} -eq 1 ]]; then args+=(--keep-result); fi
set +e
scripts/staging-ui-test.sh "${args[@]}"
test_status=$?
set -e

# The site's answer: pending, approved, confirm or ended.
status=none
deadline=$((SECONDS + TIMEOUT))
while :; do
  if [[ $(call GET /api/signin/status) == 200 ]]; then status=$(json status); fi
  echo "SIGNIN_SITE_STATUS: ${status}"
  if [[ "${status}" == approved || "${status}" == ended || "${status}" == confirm || ${SECONDS} -ge ${deadline} ]]; then break; fi
  sleep 3
done
echo "test exit status: ${test_status}"
[[ "${status}" == approved && ${test_status} -eq 0 ]]
