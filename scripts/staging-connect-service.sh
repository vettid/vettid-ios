#!/usr/bin/env bash
# Connects a staging test member's iPhone to the staging member service (MEMBER-API "Join", member-service README
# "Member API"), so that scripts/staging-signin-test.sh has a connection to sign in with.
#
#   scripts/staging-connect-service.sh --device <id> --inputs <file> [--email-from <file>] [--vettid-org <checkout>]
#                                      [--skip-build]
#
# Steps: POST /api/connect/start (the site emails a 6-digit code to the test address); the code is read from the
# test mail (`npm run -s staging:mail -- wait` in the vettid.org checkout, AWS profile vault-staging-test-mail, signed in
# with `aws sso login`); POST /api/connect/verify gives the invitation link; testStagingConnectAccept pastes it on the
# iPhone and prints the phone's safety code; GET /api/connect/status then shows the site's `sas`, and the two must be
# equal (the script compares them and prints only "SAFETY_CODES: match|differ"). The service vault approves its side
# itself; the member's side is approved with testStagingApproveRequest on the phone when the request shows in
# Approvals (the script runs it with the safety code). The final status must read `connected`.
#
# Limits (README): 3 codes per address per hour, 10 per day; one start per run and no retry. The address, the code,
# the link and the safety code are never printed (only the comparison), and live in a private temporary directory
# that is removed however the run ends.
#   --vettid-org <dir>  the vettid.org checkout with packages installed (default: ../vettid.org beside this repository's
#                       parent, or $VETTID_ORG)
set -euo pipefail

cd "$(dirname "$0")/.."
REPO=$(pwd -P)
HOST=${VETTID_MEMBER_HOST:-member.staging.vettid.org}
ORG=${VETTID_ORG:-/Users/al/Projects/vettid.org}

DEVICE="" INPUTS="" EMAIL_FROM="" SKIP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE=${2:-}; shift 2 ;;
    --inputs) INPUTS=${2:-}; shift 2 ;;
    --email-from) EMAIL_FROM=${2:-}; shift 2 ;;
    --vettid-org) ORG=${2:-}; shift 2 ;;
    --skip-build) SKIP=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "${DEVICE}" && -n "${INPUTS}" ]] || { echo "--device and --inputs are required" >&2; exit 2; }

private_file() {
  [[ -f "$1" ]] || { echo "no such input file: $1" >&2; exit 1; }
  local file
  file=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
  if [[ "${file}" == "${REPO}" || "${file}" == "${REPO}/"* ]]; then echo "refusing: an input file is inside the repository" >&2; exit 1; fi
  if (( 8#$(stat -f %Lp "${file}") & 8#077 )); then echo "refusing: an input file is readable by others; chmod 600 it" >&2; exit 1; fi
}
private_file "${INPUTS}"
if [[ -n "${EMAIL_FROM}" ]]; then private_file "${EMAIL_FROM}"; fi
EMAIL=$(grep -E '^VETTID_STAGING_EMAIL=' "${EMAIL_FROM:-${INPUTS}}" | head -1 | cut -d= -f2- | tr -d "\"'\r" || true)
[[ -n "${EMAIL}" ]] || { echo "no VETTID_STAGING_EMAIL in the inputs (or --email-from)" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/vettid-connect.XXXXXX")
chmod 700 "${WORK}"
trap 'rm -rf "${WORK}"' EXIT
trap 'exit 130' INT TERM

call() { # method path [body file]
  local args=(-sS --max-time 30 -b "${WORK}/jar" -c "${WORK}/jar" -X "$1" -H 'Content-Type: application/json'
    -o "${WORK}/out" -w '%{http_code}' "https://${HOST}$2")
  if [[ -n "${3:-}" ]]; then args+=(--data-binary "@$3"); fi
  curl "${args[@]}"
}
json() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "${WORK}/out" "$1"; }

SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"email":"%s"}' "${EMAIL}" >"${WORK}/body"
echo "== connect start"
code=$(call POST /api/connect/start "${WORK}/body")
[[ "${code}" == 202 ]] || { echo "connect start answered ${code} ($(json error))" >&2; exit 1; }

echo "== the code from the test mail"
(cd "${ORG}" && npm run -s staging:mail -- wait --to "${EMAIL}" --since "${SINCE}" --timeout 120) >"${WORK}/mail" ||
  { echo "no mail arrived (or the mail reader failed: aws sso login --profile vault-staging-test-mail)" >&2; exit 1; }
CODE=$(python3 -I -c 'import json,re,sys; m=re.search(r"(?<!\d)\d{6}(?!\d)", json.load(open(sys.argv[1])).get("text","")); print(m.group(0) if m else "")' "${WORK}/mail")
[[ -n "${CODE}" ]] || { echo "the mail holds no 6-digit code" >&2; exit 1; }

printf '{"email":"%s","code":"%s"}' "${EMAIL}" "${CODE}" >"${WORK}/body"
echo "== connect verify"
code=$(call POST /api/connect/verify "${WORK}/body")
rm -f "${WORK}/body" "${WORK}/mail"
[[ "${code}" == 200 ]] || { echo "connect verify answered ${code} ($(json error))" >&2; exit 1; }
LINK=$(json url)
[[ "${LINK}" == https://* ]] || { echo "no https invitation link" >&2; exit 1; }

IN="${WORK}/inputs"
grep -v -E '^(VETTID_STAGING_LINK|VETTID_STAGING_SAFETY_CODE)=' "${INPUTS}" >"${IN}" || true
printf '\nVETTID_STAGING_LINK=%s\n' "${LINK}" >>"${IN}"
chmod 600 "${IN}"

args=(--device "${DEVICE}" --inputs "${IN}")
if [[ ${SKIP} -eq 1 ]]; then args+=(--skip-build); fi
echo "== accept the invitation on the iPhone"
scripts/staging-ui-test.sh "${args[@]}" --test testStagingConnectAccept | tee "${WORK}/accept" | grep -E 'SAFETY_CODE|CONNECT_STATE|Test Case.*(passed|failed)' || true
PHONE=$(sed -n 's/^SAFETY_CODE: \([0-9]\{6\}\)$/\1/p' "${WORK}/accept" | head -1)
[[ -n "${PHONE}" ]] || { echo "the phone showed no safety code" >&2; exit 1; }

# The site shows `sas` once the service vault has answered.
site=""
for _ in $(seq 1 30); do
  if [[ $(call GET /api/connect/status) == 200 ]]; then
    st=$(json status); site=$(json sas)
    [[ "${st}" == sas || "${st}" == connected || "${st}" == declined || "${st}" == expired ]] && break
  fi
  sleep 4
done
echo "site status: ${st:-none}"
if [[ "${site}" == "${PHONE}" ]]; then echo "SAFETY_CODES: match"; else echo "SAFETY_CODES: differ"; exit 1; fi

# The member's side: the request on the phone, found by its safety code.
printf 'VETTID_STAGING_SAFETY_CODE=%s\n' "${PHONE}" >>"${IN}"
echo "== approve on the iPhone"
scripts/staging-ui-test.sh "${args[@]}" --skip-build --test testStagingApproveRequest | grep -E 'CONNECT_STATE|Test Case.*(passed|failed)' || true
for _ in $(seq 1 15); do
  if [[ $(call GET /api/connect/status) == 200 ]]; then st=$(json status); fi
  [[ "${st}" == connected || "${st}" == declined || "${st}" == expired ]] && break
  sleep 4
done
echo "final site status: ${st:-none}"
[[ "${st}" == connected ]]
