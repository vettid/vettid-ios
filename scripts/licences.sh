#!/usr/bin/env bash
# The licences of the third-party components bundled in the app, for Help > Licences: a checked-in resource,
# Packages/VettIDSettings/Sources/VettIDSettingsUI/Resources/Licences.json, with the app's own licence first (AGPL-3.0,
# LICENSE), then each component with its licence text, copied from the file in its checkout or in this repository.
#
#   scripts/licences.sh              write the resource (needs the resolved packages checked out: build the VettID scheme once,
#                                    or set SOURCE_PACKAGES to a SourcePackages/checkouts directory)
#   scripts/licences.sh --verify     no checkouts needed: fail when a dependency of any Package.resolved is missing from the
#                                    resource, or the resource names a version other than the app's resolved one
#
# The components: every package of the app's resolved packages (the VettID.xcodeproj's Package.resolved), the code
# vendored in this repository (mlkem-native) and the fonts (Packages/VettIDUI). The text of a package is its LICENSE
# file, with its NOTICE file after it when it has one. A checkout whose revision differs from Package.resolved is refused.
set -euo pipefail

cd "$(dirname "$0")/.."

RESOURCE=${LICENCES_RESOURCE:-Packages/VettIDSettings/Sources/VettIDSettingsUI/Resources/Licences.json}
RESOLVED=VettID.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

# What each SwiftPM identity is called, what it is licensed under and the file that holds the text (relative to its checkout).
# An identity in a Package.resolved that is not listed here fails both modes: add it, with its licence read from its checkout.
meta() {
  case "$1" in
    swift-sodium) echo "swift-sodium and libsodium|ISC|LICENSE" ;;
    phonenumberkit) echo "PhoneNumberKit|MIT|LICENSE" ;;
    swift-crypto) echo "swift-crypto|Apache-2.0|LICENSE.txt" ;;
    swift-certificates) echo "swift-certificates|Apache-2.0|LICENSE.txt" ;;
    swift-asn1) echo "swift-asn1|Apache-2.0|LICENSE.txt" ;;
    *) return 1 ;;
  esac
}

identities() { # every identity of every Package.resolved of the repository, one per line
  find . -name Package.resolved -not -path './.build/*' -not -path '*/.build/*' -print0 | xargs -0 jq -r '.pins[].identity' | sort -u
}

if [[ "${1:-}" == "--verify" ]]; then
  [[ -f "${RESOURCE}" ]] || { echo "licences: no ${RESOURCE}" >&2; exit 1; }
  status=0
  while read -r id; do
    if ! jq -e --arg id "${id}" 'any(.[]; .id == $id)' "${RESOURCE}" >/dev/null; then
      echo "licences: the dependency ${id} of a Package.resolved is missing from ${RESOURCE} (scripts/licences.sh)" >&2
      status=1
    fi
  done < <(identities)
  while read -r id version; do
    jq -e --arg id "${id}" --arg v "${version}" 'any(.[]; .id == $id and .version == $v)' "${RESOURCE}" >/dev/null || {
      echo "licences: ${id} ${version} (the app's Package.resolved) differs from ${RESOURCE} (scripts/licences.sh)" >&2
      status=1
    }
  done < <(jq -r '.pins[] | "\(.identity) \(.state.version)"' "${RESOLVED}")
  jq -e '.[0].id == "vettid"' "${RESOURCE}" >/dev/null || { echo "licences: the app's own licence is not first" >&2; status=1; }
  jq -e 'all(.[]; (.text | length) > 200)' "${RESOURCE}" >/dev/null || { echo "licences: an entry without a licence text" >&2; status=1; }
  [[ ${status} -eq 0 ]] && echo "licences: ${RESOURCE} lists every dependency ($(identities | tr '\n' ' '))"
  exit ${status}
fi

CHECKOUTS=${SOURCE_PACKAGES:-}
if [[ -z "${CHECKOUTS}" ]]; then
  products=$(xcodebuild -project VettID.xcodeproj -scheme VettID -showBuildSettings 2>/dev/null | sed -n 's/^ *BUILD_DIR = //p')
  CHECKOUTS="${products%/Build/Products}/SourcePackages/checkouts"
fi
[[ -d "${CHECKOUTS}" ]] || { echo "licences: no package checkouts at ${CHECKOUTS}; build the VettID scheme or set SOURCE_PACKAGES" >&2; exit 1; }

entries=$(mktemp)
trap 'rm -f "${entries}"' EXIT
add() { # id name version licence url text-file...
  local id=$1 name=$2 version=$3 licence=$4 url=$5
  shift 5
  local text
  text=$(for f in "$@"; do cat "${f}"; printf '\n'; done)
  jq -n --arg id "${id}" --arg name "${name}" --arg version "${version}" --arg licence "${licence}" --arg url "${url}" \
    --arg text "${text}" '{id: $id, name: $name, version: $version, licence: $licence, url: $url, text: $text}' >>"${entries}"
}

add vettid "VettID" "" "AGPL-3.0" "https://github.com/vettid/vettid-ios" LICENSE

while read -r id version revision location; do
  info=$(meta "${id}") || { echo "licences: no entry for the dependency ${id}: add it to meta() in scripts/licences.sh" >&2; exit 1; }
  IFS='|' read -r name licence file <<<"${info}"
  dir="${CHECKOUTS}/$(basename "${location}" .git)"
  [[ -d "${dir}" ]] || { echo "licences: no checkout of ${id} at ${dir}" >&2; exit 1; }
  [[ "$(git -C "${dir}" rev-parse HEAD)" == "${revision}" ]] ||
    { echo "licences: the checkout of ${id} is not at revision ${revision} of Package.resolved" >&2; exit 1; }
  files=("${dir}/${file}")
  [[ -f "${dir}/NOTICE.txt" ]] && files+=("${dir}/NOTICE.txt")
  add "${id}" "${name}" "${version}" "${licence}" "${location%.git}" "${files[@]}"
done < <(jq -r '.pins[] | "\(.identity) \(.state.version) \(.state.revision) \(.location)"' "${RESOLVED}")

# Vendored code and fonts of this repository (their SOURCE.md files name the sources and versions).
add mlkem-native "mlkem-native" "v2.0.0" "Apache-2.0 OR ISC OR MIT" "https://github.com/pq-code-package/mlkem-native" \
  Packages/VettIDCrypto/Sources/CMLKEM/mlkem-native/LICENSE
add font-inter "Inter (font)" "" "SIL OFL 1.1" "https://rsms.me/inter/" Packages/VettIDUI/Sources/VettIDUI/Resources/Fonts/Inter-LICENSE.txt
add font-plus-jakarta-sans "Plus Jakarta Sans (font)" "" "SIL OFL 1.1" "https://github.com/tokotype/PlusJakartaSans" \
  Packages/VettIDUI/Sources/VettIDUI/Resources/Fonts/PlusJakartaSans-OFL.txt

mkdir -p "$(dirname "${RESOURCE}")"
jq -s '.' "${entries}" >"${RESOURCE}"
echo "licences: wrote $(jq length "${RESOURCE}") entries to ${RESOURCE}"
"$0" --verify
