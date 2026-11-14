#!/usr/bin/env bash
# The components built into the webrtc-sdk binary, derived from the DWARF of its dSYM (the xcframework ships one for every slice;
# the iOS device slice is read): the vendored directories, one per line, sorted. Every path string of the DWARF counts (the compile
# units' names and the source files and directories of the line tables, so a component whose headers alone were compiled in, such
# as llvm-libc, is listed too), reduced to its chain of third_party directories: `libaom/third_party/vector`, `ooura`, `perfetto`.
#
# The list is checked in as Packages/VettIDCallsWebRTC/Licences/components.list with the licence each maps to (SOURCE.md,
# scripts/licences.sh). A WebRTC upgrade that adds or drops a component changes this output, and `--check` (run by the
# calls-webrtc CI job, where the binary is available) fails until the list and the notices are updated.
#
#   scripts/webrtc-components.sh <WebRTC.xcframework>            print the components
#   scripts/webrtc-components.sh --check <WebRTC.xcframework>    fail when they differ from the checked-in list
set -euo pipefail

cd "$(dirname "$0")/.."

CHECKED_IN=${COMPONENTS_LIST:-Packages/VettIDCallsWebRTC/Licences/components.list}

check=0
if [[ "${1:-}" == "--check" ]]; then check=1; shift; fi
xcframework=${1:?usage: webrtc-components.sh [--check] <WebRTC.xcframework>}
dwarf="${xcframework}/ios-arm64/dSYMs/WebRTC.framework.dSYM/Contents/Resources/DWARF/WebRTC"
[[ -f "${dwarf}" ]] || { echo "webrtc-components: no dSYM at ${dwarf}" >&2; exit 1; }

derive() {
  strings -a "${dwarf}" | python3 -I -c '
import re, sys
found = set()
for line in sys.stdin:
    for path in re.findall(r"[A-Za-z0-9_+./-]*third_party/[A-Za-z0-9_+.-]+(?:/[A-Za-z0-9_+.-]+)*", line):
        parts = path.split("/")
        chain = [parts[i + 1] for i, part in enumerate(parts[:-1]) if part == "third_party"]
        chain = [c for k, c in enumerate(chain) if k == 0 or c != chain[k - 1]]
        if chain:
            found.add("/third_party/".join(chain))
if len(found) < 5:
    sys.exit("too few components in the DWARF")
print("\n".join(sorted(found)))
'
}
components=$(derive)

if [[ ${check} -eq 1 ]]; then
  expected=$(grep -v '^#' "${CHECKED_IN}" | awk 'NF { print $1 }' | LC_ALL=C sort -u)
  if [[ "${components}" != "${expected}" ]]; then
    echo "webrtc-components: the binary's components differ from ${CHECKED_IN}:" >&2
    diff <(echo "${expected}") <(echo "${components}") >&2 || true
    exit 1
  fi
  echo "webrtc-components: the $(wc -l <<<"${components}" | tr -d ' ') components of the binary match ${CHECKED_IN}"
else
  echo "${components}"
fi
