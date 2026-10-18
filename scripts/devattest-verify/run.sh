#!/usr/bin/env bash
# Verifies the TEST iOS attester's fixture with vettid-vault's own devattest
# verifier under the dev enclave's TEST policy (main.go says what is checked).
#
#   scripts/devattest-verify/run.sh [FIXTURE]
#   scripts/devattest-verify/run.sh --real EXPORT
#
# FIXTURE defaults to VettIDAltChan's committed fixture without extensions (pass
# test-app-attest-ed.json next to it for the one with them). --real checks a real
# iPhone's App Attest attestation and assertions (VA1): EXPORT is the file the
# device test AppAttestDeviceTests writes with VETTID_TEST_APPATTEST_EXPORT=1
# (copied from the phone with `xcrun devicectl device copy from`); it is
# verified against Apple's App Attestation root for the App ID
# <team id>.<bundle id>, the team ID read from Config/Signing.xcconfig at run
# time. Keep EXPORT outside the repository: it is a real attestation object.
# VAULT_SRC is the
# vettid-vault clone (default: vettid-vault next to this repository); it must
# be checked out, without local changes, at VAULT_COMMIT. main.go is compiled
# inside that module with `go run -overlay` (it imports internal/enclavetest),
# so the clone itself is never modified. Requires Go 1.26.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd -P)"
# The vettid-vault commit the fixtures were verified against (SOURCE.md next to the fixtures).
VAULT_COMMIT=ed8929818d776e278bcb8b5756add909572f8838
VAULT_SRC="${VAULT_SRC:-${REPO}/../vettid-vault}"
MODE=()
if [[ "${1:-}" == "--real" ]]; then
  [[ $# -eq 2 ]] || { echo "usage: $0 --real EXPORT" >&2; exit 2; }
  shift
  TEAM=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' "${REPO}/Config/Signing.xcconfig")
  [[ -n "${TEAM}" ]] || { echo "no DEVELOPMENT_TEAM in Config/Signing.xcconfig" >&2; exit 2; }
  case "$(cd "$(dirname "$1")" && pwd -P)/" in
    "${REPO}/"*) echo "the export must stay outside the repository" >&2; exit 2 ;;
  esac
  MODE=(--real)
fi
FIXTURE="${1:-${REPO}/Packages/VettIDAltChan/Tests/VettIDAltChanTests/Resources/appattest/test-app-attest.json}"

[[ -d "${VAULT_SRC}" ]] || { echo "no vettid-vault clone at ${VAULT_SRC} (set VAULT_SRC)" >&2; exit 2; }
VAULT_SRC="$(cd "${VAULT_SRC}" && pwd)"
FIXTURE="$(cd "$(dirname "${FIXTURE}")" && pwd)/$(basename "${FIXTURE}")"
head=$(git -C "${VAULT_SRC}" rev-parse HEAD)
if [[ "${head}" != "${VAULT_COMMIT}" ]]; then
  echo "vettid-vault at ${VAULT_SRC} is at ${head}, not ${VAULT_COMMIT}" >&2
  exit 2
fi
if [[ -n "$(git -C "${VAULT_SRC}" status --porcelain)" ]]; then
  echo "vettid-vault at ${VAULT_SRC} has local changes" >&2
  exit 2
fi

# A package directory that does not exist in the clone (not even ignored files), so nothing of it is replaced.
pkg=internal/vettidiosattestcheck
if [[ -e "${VAULT_SRC}/${pkg}" || -n "$(git -C "${VAULT_SRC}" status --porcelain --ignored -- "${pkg}")" ]]; then
  echo "vettid-vault at ${VAULT_SRC} has ${pkg}; the overlay must add it, not replace it" >&2
  exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
printf '{"Replace":{"%s/%s/main.go":"%s/main.go","%s/%s/real.go":"%s/real.go"}}\n' \
  "${VAULT_SRC}" "${pkg}" "${HERE}" "${VAULT_SRC}" "${pkg}" "${HERE}" >"${tmp}/overlay.json"

echo "vettid-vault ${VAULT_COMMIT}, $(go version)"
cd "${VAULT_SRC}"
# -mod=readonly: go.mod and go.sum of the clone are never rewritten.
if [[ ${#MODE[@]} -gt 0 ]]; then
  GOFLAGS=-mod=readonly go run -overlay "${tmp}/overlay.json" "./${pkg}" --real "${FIXTURE}" "${TEAM}"
else
  GOFLAGS=-mod=readonly go run -overlay "${tmp}/overlay.json" "./${pkg}" "${FIXTURE}"
fi
