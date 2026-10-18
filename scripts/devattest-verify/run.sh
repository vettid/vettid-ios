#!/usr/bin/env bash
# Verifies the TEST iOS attester's fixture with vettid-vault's own devattest
# verifier under the dev enclave's TEST policy (main.go says what is checked).
#
#   scripts/devattest-verify/run.sh [FIXTURE]
#
# FIXTURE defaults to VettIDAltChan's committed fixture. VAULT_SRC is the
# vettid-vault clone (default: vettid-vault next to this repository); it must
# be checked out, without local changes, at VAULT_COMMIT. main.go is compiled
# inside that module with `go run -overlay` (it imports internal/enclavetest),
# so the clone itself is never modified. Requires Go 1.26.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
# The vettid-vault commit the fixture was verified against (SOURCE.md next to the fixture).
VAULT_COMMIT=057236379992e48e7f356b4994fc2d11c174d365
VAULT_SRC="${VAULT_SRC:-${REPO}/../vettid-vault}"
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
printf '{"Replace":{"%s/%s/main.go":"%s/main.go"}}\n' "${VAULT_SRC}" "${pkg}" "${HERE}" >"${tmp}/overlay.json"

echo "vettid-vault ${VAULT_COMMIT}, $(go version)"
cd "${VAULT_SRC}"
# -mod=readonly: go.mod and go.sum of the clone are never rewritten.
GOFLAGS=-mod=readonly go run -overlay "${tmp}/overlay.json" "./${pkg}" "${FIXTURE}"
