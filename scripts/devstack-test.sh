#!/usr/bin/env bash
# The local dev stack for the iPhone app (IOS-PLAN §8 I1.3, §12 step 6):
# vettid-vault's `cmd/devstack` (the real relay, LocalStack, vault-parent,
# the dev enclave with its TEST device policy, the member API stand-in and
# the vaultctl peer), and the dev stack test that runs against it
# (VettIDVault's DevStackAcceptanceTests: enroll with the TEST iOS attester,
# unlock, exchange a message with the vaultctl peer).
#
#   scripts/devstack-test.sh          # up, run the test on the simulator, down
#   scripts/devstack-test.sh --host   # the same test with `swift test` on the Mac
#   scripts/devstack-test.sh --ui     # IOS-PLAN §8 exit I1 (a): the VettIDDevStack
#                                     # app's UI test on the simulator
#   scripts/devstack-test.sh up|status|down
#
# --ui builds the VettIDDevStack scheme for testing (DevStack configuration),
# removes VettID Dev Stack from the simulator (a fresh install), issues a
# setup code for a new member (POST /api/vault/enroll-code, the member being
# <guid>@example.org on the stack's member API stand-in), reads the stack's
# TEST-ONLY trust (GET /dev/trust) and runs AppDevStackUITests' DevStackTests
# with them and run/ready.json's addresses as TEST_RUNNER_VETTID_DEVSTACK_*.
#
# The simulator shares the Mac's 127.0.0.1, so it reaches the stack's ports
# (18080 relay, 18081 member API, 18082 control) directly. A stack already
# answering on the control port (vettid-android's devstack/devstack.sh, for
# example) is used as it is and left running.
#
# The dev enclave's vault processes need Linux, so on macOS the stack runs in
# a Linux container (golang:<GO_VERSION>, --network host, named
# vettid-ios-devstack) on Docker or colima; the data directory and this
# script's state directory are mounted at the same paths, so run/ready.json
# and the logs land on the Mac, and the Go module and build caches live in
# the named volumes vettid-gomod and vettid-gocache. colima forwards the
# ports the container listens on to the Mac's 127.0.0.1, and shares only the
# home directory with its VM: the data directory, the state directory and
# VAULT_SRC must be under it. The container cannot start LocalStack itself:
# an endpoint in DEVSTACK_LOCALSTACK is used, else one already answering on
# 127.0.0.1:4566, else this script starts vettid-vault's
# integration/docker-compose.yml from the Mac (project vettid-ios-devstack)
# and stops it with the stack. Elsewhere (Linux), or with DEVSTACK_NATIVE=1,
# the stack runs natively with `go run`.
#
# Environment:
#   VAULT_REF            vettid-vault commit to run (default below)
#   VAULT_SRC            run ./cmd/devstack from this vettid-vault checkout instead
#   DEVSTACK_LOCALSTACK  an external LocalStack endpoint (passed as -localstack);
#                        without it the stack starts LocalStack with podman or
#                        docker compose
#   KEEP_STACK=1         leave the stack running after the test
#   DEVSTACK_NATIVE=1    on macOS, run the stack natively anyway (it cannot enroll)
#   GO_VERSION           the golang image tag of the container (default 1.26)
#
# Requirements: on macOS, Docker with compose (colima, for example) and
# Xcode for the simulator run; on Linux, Go 1.26 and podman or docker with
# compose (or DEVSTACK_LOCALSTACK); network access the first time (module and
# relay builds). Every key in the stack is TEST-ONLY, and no vault survives a
# restart of the stack. What stays on the Mac: ~/.cache/vettid-devstack (the
# stack's built binaries, run/ready.json and run/logs/), ~/.cache/vettid-ios-devstack
# (this script's pid file and devstack.log), the Go module and build caches
# (on macOS the volumes vettid-gomod and vettid-gocache), and the golang and
# LocalStack container images.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"

# The vettid-vault commit the dev stack runs: #118 or later, which accepts the App Attest extensions map the TEST attester sends by default.
VAULT_REF="${VAULT_REF:-ed8929818d776e278bcb8b5756add909572f8838}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
DATA="${DEVSTACK_DATA:-${CACHE}/vettid-devstack}"
STATE="${CACHE}/vettid-ios-devstack"
CTL=http://127.0.0.1:18082

CONTAINER=vettid-ios-devstack
LOCALSTACK=http://127.0.0.1:4566
GO_IMAGE="golang:${GO_VERSION:-1.26}"
if [[ "$(uname -s)" == Darwin && "${DEVSTACK_NATIVE:-}" != 1 ]]; then MODE=container; else MODE=native; fi

healthy() { curl -sf --max-time 3 "${CTL}/dev/health" >/dev/null 2>&1; }
running() {
  if [[ "${MODE}" == container ]]; then
    [[ -n "$(docker ps -q --filter "name=^${CONTAINER}\$" 2>/dev/null)" ]]
  else
    [[ -f "${STATE}/pid" ]] && kill -0 "$(cat "${STATE}/pid")" 2>/dev/null
  fi
}

# The LocalStack endpoint for the container (see the top of this file).
container_localstack() {
  if [[ -n "${DEVSTACK_LOCALSTACK:-}" ]]; then echo "${DEVSTACK_LOCALSTACK}"; return; fi
  if curl -sf --max-time 3 "${LOCALSTACK}/_localstack/health" >/dev/null 2>&1; then
    echo "using the LocalStack already answering on ${LOCALSTACK}" >&2
    echo "${LOCALSTACK}"; return
  fi
  local file
  if [[ -n "${VAULT_SRC:-}" ]]; then
    file="$(cat "${VAULT_SRC}/integration/docker-compose.yml")"
  else
    # The compose file of VAULT_REF, from the module cache volume.
    file="$(docker run --rm -v vettid-gomod:/go/pkg/mod "${GO_IMAGE}" sh -c \
      'd="$(go mod download -json "$0" | sed -n "s/^[[:space:]]*\"Dir\": \"\(.*\)\",\$/\1/p")" && cat "${d}/integration/docker-compose.yml"' \
      "github.com/vettid/vettid-vault@${VAULT_REF}")"
  fi
  echo "starting LocalStack (compose project ${CONTAINER})" >&2
  printf '%s\n' "${file}" | docker compose -p "${CONTAINER}" -f - up -d --wait >&2
  touch "${STATE}/localstack"
  echo "${LOCALSTACK}"
}

container_up() {
  local path
  for path in "${DATA}" "${STATE}" ${VAULT_SRC:+"${VAULT_SRC}"}; do
    case "${path}" in
      "${HOME}"/*) ;;
      *) echo "${path} is outside ${HOME}: colima does not share it with its VM" >&2; exit 1 ;;
    esac
  done
  docker info >/dev/null 2>&1 || { echo "docker does not answer (start colima)" >&2; exit 1; }
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  mkdir -p "${DATA}"
  # colima's VM has a few GB of memory, under devstack's default -wait-free-mem of 8.
  local args=(-data "${DATA}" -mem-wait 10m -wait-free-mem 2 -localstack "$(container_localstack)")
  local run=(go run -tags devenclave "github.com/vettid/vettid-vault/cmd/devstack@${VAULT_REF}")
  local src=()
  if [[ -n "${VAULT_SRC:-}" ]]; then
    src=(-v "${VAULT_SRC}:${VAULT_SRC}:ro" -w "${VAULT_SRC}")
    run=(go run -tags devenclave ./cmd/devstack)
  fi
  docker run -d --rm --init --name "${CONTAINER}" --network host \
    -v "${DATA}:${DATA}" -v "${STATE}:${STATE}" \
    -v vettid-gomod:/go/pkg/mod -v vettid-gocache:/root/.cache/go-build \
    -e GOMAXPROCS=2 -e GOFLAGS=-p=2 ${src[@]+"${src[@]}"} "${GO_IMAGE}" \
    sh -c 'exec "$@" >"$0" 2>&1' "${STATE}/devstack.log" "${run[@]}" "${args[@]}" >/dev/null
}

native_up() {
  local args=(-data "${DATA}" -mem-wait 10m)
  [[ -n "${DEVSTACK_LOCALSTACK:-}" ]] && args+=(-localstack "${DEVSTACK_LOCALSTACK}")
  (
    export GOMAXPROCS=2 GOFLAGS=-p=2
    if [[ -n "${VAULT_SRC:-}" ]]; then
      cd "${VAULT_SRC}"
      nohup go run -tags devenclave ./cmd/devstack "${args[@]}" >"${STATE}/devstack.log" 2>&1 &
    else
      nohup go run -tags devenclave "github.com/vettid/vettid-vault/cmd/devstack@${VAULT_REF}" "${args[@]}" \
        >"${STATE}/devstack.log" 2>&1 &
    fi
    echo $! >"${STATE}/pid"
  )
}

up() {
  if healthy; then
    echo "a dev stack already answers on ${CTL}" >&2
    return 0
  fi
  mkdir -p "${STATE}"
  rm -f "${DATA}/run/ready.json"
  if [[ "${MODE}" == container ]]; then container_up; else native_up; fi
  echo "starting vettid-vault ${VAULT_SRC:-@${VAULT_REF}} (log: ${STATE}/devstack.log)" >&2
  for _ in $(seq 1 900); do
    [[ -f "${DATA}/run/ready.json" ]] && healthy && break
    if ! running; then
      echo "the stack exited; see ${STATE}/devstack.log" >&2
      tail -40 "${STATE}/devstack.log" >&2
      exit 1
    fi
    sleep 1
  done
  healthy || { echo "timed out; see ${STATE}/devstack.log" >&2; down; exit 1; }
  cat "${DATA}/run/ready.json"
}

down() {
  if [[ "${MODE}" == container ]]; then
    if running; then
      # --init: SIGTERM reaches `go run`, and devstack stops once its go parent is gone.
      docker stop -t 60 "${CONTAINER}" >/dev/null 2>&1 || true
      echo "stopped" >&2
    fi
    if [[ -f "${STATE}/localstack" ]]; then
      docker compose -p "${CONTAINER}" down >/dev/null 2>&1 || true
      rm -f "${STATE}/localstack"
      echo "stopped LocalStack" >&2
    fi
    return 0
  fi
  if [[ -f "${STATE}/pid" ]]; then
    local pid
    pid="$(cat "${STATE}/pid")"
    # Only the process this script started: a stale pid file may name another process by now.
    if ps -p "${pid}" -o command= 2>/dev/null | grep -q devstack; then
      # `go run` does not forward SIGTERM; devstack stops by itself once its go parent is gone.
      kill "${pid}" 2>/dev/null || true
      for _ in $(seq 1 120); do healthy || break; sleep 1; done
      echo "stopped" >&2
    fi
    rm -f "${STATE}/pid"
  fi
}

status() {
  if healthy; then
    echo "running"; curl -sf "${CTL}/dev/info" || true
  else
    echo "not running"
  fi
  if [[ "${MODE}" == container ]] && running; then
    echo "container ${CONTAINER}: $(docker ps --filter "name=^${CONTAINER}\$" --format '{{.Status}}')"
  fi
}

run_test() {
  local where=$1
  if ! healthy; then
    # A stack this run starts is stopped however the run ends (an interrupt too), unless KEEP_STACK=1; a stack
    # found running is left alone.
    if [[ "${KEEP_STACK:-}" != 1 ]]; then
      trap down EXIT
      trap 'exit 130' INT TERM
    fi
    up
  fi
  local rc=0
  if [[ "${where}" == ui ]]; then
    run_ui || rc=$?
  elif [[ "${where}" == host ]]; then
    VETTID_DEVSTACK=1 swift test --package-path "${REPO}/Packages/VettIDVault" --filter DevStackAcceptanceTests || rc=$?
  else
    # xcodebuild hands TEST_RUNNER_-prefixed variables to the test process without the prefix.
    TEST_RUNNER_VETTID_DEVSTACK=1 xcodebuild test -project VettID.xcodeproj -scheme VettID \
      -destination "$(scripts/simulator-destination.sh)" -parallel-testing-worker-count 1 \
      -only-testing:VettIDVaultTests/DevStackAcceptanceTests || rc=$?
  fi
  return ${rc}
}

# The VettIDDevStack app's bundle id (project.yml), removed before each --ui run.
DEVSTACK_UI_APP=com.vettid.app.devstack.ui

# Fails the --ui run, saying what was missing. (run_ui is called as `run_ui || rc=$?`, which turns `set -e` off inside
# it: every step checks its own result.)
ui_fail() { echo "devstack --ui: $*" >&2; return 1; }

# One field of a JSON document on stdin (a list joined with commas); empty when it is missing.
json_field() { python3 -c 'import json,sys
v = json.load(sys.stdin).get(sys.argv[1], "")
print(",".join(v) if isinstance(v, list) else v)' "$1" 2>/dev/null || true; }

# The VettIDDevStack app's UI test (DevStackTests) on the simulator against the running stack. It passes only when the
# test ran and passed: the runner is told it runs from this script (VETTID_DEVSTACK_UI=1), so a missing input fails the
# test instead of skipping it, and the output must show the test passed.
run_ui() {
  local dest udid ready api relay ctl guid code trust root keys out rc=0
  dest="$(scripts/simulator-destination.sh)" || ui_fail "no simulator" || return 1
  xcodebuild build-for-testing -project VettID.xcodeproj -scheme VettIDDevStack -configuration DevStack \
    -destination "${dest}" -quiet || ui_fail "the build failed" || return 1
  # A fresh install: the app and its data container are removed (the first launch erases what the keychain kept).
  udid="${dest##*id=}"
  if [[ "${udid}" != "${dest}" ]]; then
    xcrun simctl boot "${udid}" 2>/dev/null || true
    xcrun simctl uninstall "${udid}" "${DEVSTACK_UI_APP}" 2>/dev/null || true
  fi
  ready="${DATA}/run/ready.json"
  [[ -f "${ready}" ]] || ui_fail "no ${ready}" || return 1
  api=$(json_field api <"${ready}")
  relay=$(json_field relay_transport <"${ready}")
  ctl=$(json_field ctl <"${ready}")
  [[ -n "${api}" && -n "${relay}" && -n "${ctl}" ]] || ui_fail "${ready} lacks api, relay_transport or ctl" || return 1
  trust=$(curl -sf --max-time 10 "${ctl}/dev/trust") || ui_fail "GET ${ctl}/dev/trust failed" || return 1
  root=$(printf '%s' "${trust}" | json_field nitro_root)
  keys=$(printf '%s' "${trust}" | json_field manifest_keys)
  [[ -n "${root}" && -n "${keys}" ]] || ui_fail "/dev/trust lacks nitro_root or manifest_keys" || return 1
  # A new member for each run; the code is issued last, as it lives 5 minutes.
  guid="ios-ui-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
  code=$(curl -sf --max-time 10 -X POST -H "Authorization: Bearer ${guid}" -H 'Content-Type: application/json' \
    "${api}/api/vault/enroll-code" | json_field code)
  [[ -n "${code}" ]] || ui_fail "POST ${api}/api/vault/enroll-code gave no code" || return 1
  out=$(mktemp)
  TEST_RUNNER_VETTID_DEVSTACK_UI=1 \
    TEST_RUNNER_VETTID_DEVSTACK_API="${api}" TEST_RUNNER_VETTID_DEVSTACK_RELAY="${relay}" \
    TEST_RUNNER_VETTID_DEVSTACK_CTL="${ctl}" TEST_RUNNER_VETTID_DEVSTACK_NITRO_ROOT="${root}" \
    TEST_RUNNER_VETTID_DEVSTACK_MANIFEST_KEYS="${keys}" TEST_RUNNER_VETTID_DEVSTACK_EMAIL="${guid}@example.org" \
    TEST_RUNNER_VETTID_DEVSTACK_CODE="${code}" \
    xcodebuild test-without-building -project VettID.xcodeproj -scheme VettIDDevStack -configuration DevStack \
    -destination "${dest}" -parallel-testing-enabled NO \
    -only-testing:VettIDDevStackUITests/DevStackTests/testDevStackEnrollLockUnlock 2>&1 | tee "${out}"
  rc=${PIPESTATUS[0]}
  if [[ ${rc} -eq 0 ]] && ! grep -q "testDevStackEnrollLockUnlock\]' passed" "${out}"; then
    ui_fail "testDevStackEnrollLockUnlock did not run and pass (skipped?)"
    rc=1
  fi
  rm -f "${out}"
  return ${rc}
}

case "${1:-}" in
  "") run_test simulator ;;
  --host) run_test host ;;
  --ui) run_test ui ;;
  up) up ;;
  down) down ;;
  status) status ;;
  *) echo "usage: $0 [--host|--ui|up|status|down]" >&2; exit 2 ;;
esac
