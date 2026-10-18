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
#   scripts/devstack-test.sh up|status|down
#
# The simulator shares the Mac's 127.0.0.1, so it reaches the stack's ports
# (18080 relay, 18081 member API, 18082 control) directly. A stack already
# answering on the control port (vettid-android's devstack/devstack.sh, for
# example) is used as it is and left running.
#
# Environment:
#   VAULT_REF            vettid-vault commit to run (default below)
#   VAULT_SRC            run ./cmd/devstack from this vettid-vault checkout instead
#   DEVSTACK_LOCALSTACK  an external LocalStack endpoint (passed as -localstack);
#                        without it the stack starts LocalStack with podman or
#                        docker compose
#   KEEP_STACK=1         leave the stack running after the test
#
# Requirements: Go 1.26, podman or docker with compose (or DEVSTACK_LOCALSTACK),
# network access the first time (module and relay builds), Xcode for the
# simulator run. Every key in the stack is TEST-ONLY, and no vault survives a
# restart of the stack. What stays on the Mac: ~/.cache/vettid-devstack (the
# stack's built binaries, run/ready.json and run/logs/), ~/.cache/vettid-ios-devstack
# (this script's pid file and devstack.log), the Go module and build caches,
# and the LocalStack container image.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"

# The vettid-vault commit of the other references (scripts/phone-ios-reference, scripts/devattest-verify).
VAULT_REF="${VAULT_REF:-057236379992e48e7f356b4994fc2d11c174d365}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
DATA="${DEVSTACK_DATA:-${CACHE}/vettid-devstack}"
STATE="${CACHE}/vettid-ios-devstack"
CTL=http://127.0.0.1:18082

healthy() { curl -sf --max-time 3 "${CTL}/dev/health" >/dev/null 2>&1; }
running() { [[ -f "${STATE}/pid" ]] && kill -0 "$(cat "${STATE}/pid")" 2>/dev/null; }

up() {
  if healthy; then
    echo "a dev stack already answers on ${CTL}" >&2
    return 0
  fi
  mkdir -p "${STATE}"
  rm -f "${DATA}/run/ready.json"
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
  if [[ "${where}" == host ]]; then
    VETTID_DEVSTACK=1 swift test --package-path "${REPO}/Packages/VettIDVault" --filter DevStackAcceptanceTests || rc=$?
  else
    # xcodebuild hands TEST_RUNNER_-prefixed variables to the test process without the prefix.
    TEST_RUNNER_VETTID_DEVSTACK=1 xcodebuild test -project VettID.xcodeproj -scheme VettID \
      -destination "$(scripts/simulator-destination.sh)" -parallel-testing-worker-count 1 \
      -only-testing:VettIDVaultTests/DevStackAcceptanceTests || rc=$?
  fi
  return ${rc}
}

case "${1:-}" in
  "") run_test simulator ;;
  --host) run_test host ;;
  up) up ;;
  down) down ;;
  status) status ;;
  *) echo "usage: $0 [--host|up|status|down]" >&2; exit 2 ;;
esac
