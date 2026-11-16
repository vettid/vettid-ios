#!/usr/bin/env bash
# The log of a connected iPhone for the last minutes, read without root: idevicesyslog's archive, then `log show` on it
# (`log collect --device-udid` needs root). For debugging on the test iPhones, for example a staging call (STAGING-TESTING §5).
#
#   scripts/phone-log.sh --device <id> [--minutes 10] [--predicate '<log predicate>']
#
#   --device <id>      the iPhone (`xcrun devicectl list devices`)
#   --minutes <n>      how far back (10 by default)
#   --predicate <p>    a `log show` predicate; by default the VettID app's own process
#
# The archive is kept under ${XDG_CACHE_HOME:-~/Library/Caches}/vettid-ios/phone-log (mode 700) and the lines are printed. A
# phone's log holds more than the app's own lines (networks, other apps): keep the output private, and never paste it into an
# issue, a PR or a chat. Needs idevicesyslog (libimobiledevice).
set -euo pipefail

DEVICE=""
MINUTES=10
PREDICATE='process == "VettID"'
usage() { echo "usage: $0 --device <id> [--minutes <n>] [--predicate '<predicate>']" >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="${2:-}"; shift 2 ;;
    --minutes) MINUTES="${2:-}"; shift 2 ;;
    --predicate) PREDICATE="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "${DEVICE}" ]] || usage
[[ "${MINUTES}" =~ ^[1-9][0-9]*$ ]] || { echo "--minutes must be a positive whole number" >&2; exit 2; }
command -v idevicesyslog >/dev/null || { echo "idevicesyslog not found (brew install libimobiledevice)" >&2; exit 1; }

DIR="${XDG_CACHE_HOME:-${HOME}/Library/Caches}/vettid-ios/phone-log"
mkdir -p "${DIR}"
chmod 700 "${DIR}"
STAMP="$(date +%Y%m%d-%H%M%S)"
TAR="${DIR}/${STAMP}.tar"
ARCHIVE="${DIR}/${STAMP}.logarchive"
idevicesyslog -u "${DEVICE}" archive "${TAR}" --age-limit "$((MINUTES * 60))" >/dev/null
mkdir -p "${ARCHIVE}"
tar -xf "${TAR}" -C "${ARCHIVE}"
rm -f "${TAR}"
echo "archive: ${ARCHIVE}" >&2
# The full path: zsh has a `log` builtin of its own.
/usr/bin/log show --archive "${ARCHIVE}" --predicate "${PREDICATE}" --style compact
