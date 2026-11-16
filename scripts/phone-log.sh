#!/usr/bin/env bash
# The log of a connected iPhone for the last minutes, read without root: idevicesyslog's archive, then `log show` on it
# (`log collect --device-udid` needs root). For debugging on the test iPhones, for example a staging call (STAGING-TESTING §5).
#
#   scripts/phone-log.sh --device <udid> [--minutes 10] [--predicate '<log predicate>'] [--keep]
#
#   --device <udid>    the iPhone's hardware UDID (`idevice_id -l`; not the CoreDevice identifier devicectl shows)
#   --minutes <n>      how far back (10 by default)
#   --predicate <p>    a `log show` predicate; by default the VettID app's own process
#   --keep             keep the log archive (under ${XDG_CACHE_HOME:-~/Library/Caches}/vettid-ios/phone-log, mode 700)
#
# The lines are printed and the archive is deleted, unless --keep. A
# phone's log holds more than the app's own lines (networks, other apps): keep the output private, and never paste it into an
# issue, a PR or a chat. Needs idevicesyslog (libimobiledevice).
set -euo pipefail

DEVICE=""
MINUTES=10
PREDICATE='process == "VettID"'
KEEP=0
usage() { echo "usage: $0 --device <udid> [--minutes <n>] [--predicate '<predicate>'] [--keep]" >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) [[ $# -ge 2 ]] || usage; DEVICE="$2"; shift 2 ;;
    --minutes) [[ $# -ge 2 ]] || usage; MINUTES="$2"; shift 2 ;;
    --predicate) [[ $# -ge 2 ]] || usage; PREDICATE="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "${DEVICE}" ]] || usage
[[ "${MINUTES}" =~ ^[1-9][0-9]*$ ]] || { echo "--minutes must be a positive whole number" >&2; exit 2; }
command -v idevicesyslog >/dev/null || { echo "idevicesyslog not found (brew install libimobiledevice)" >&2; exit 1; }

DIR="${XDG_CACHE_HOME:-${HOME}/Library/Caches}/vettid-ios/phone-log"
(umask 077; mkdir -p "${DIR}")
chmod 700 "${DIR}"
STAMP="$(date +%Y%m%d-%H%M%S)"
TAR="${DIR}/${STAMP}.tar"
ARCHIVE="${DIR}/${STAMP}.logarchive"
idevicesyslog -u "${DEVICE}" archive "${TAR}" --age-limit "$((MINUTES * 60))" >/dev/null
mkdir -p "${ARCHIVE}"
tar -xf "${TAR}" -C "${ARCHIVE}"
rm -f "${TAR}"
# The full path, so that no shell function or builtin of the same name is used.
status=0
/usr/bin/log show --archive "${ARCHIVE}" --predicate "${PREDICATE}" --style compact || status=$?
if [[ ${KEEP} -eq 1 ]]; then echo "archive kept: ${ARCHIVE}" >&2; else rm -rf "${ARCHIVE}"; fi
exit "${status}"
