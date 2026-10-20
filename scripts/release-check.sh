#!/usr/bin/env bash
# Release check (IOS-PLAN §5, I0.1): the counterpart of vettid-android's
# checkReleaseApk and checkStagingApk.
#
# Archives the Release and Staging configurations unsigned and fails when
# either app carries:
#   - a TEST-only marker (the VettIDTesting package, VettIDData's
#     VettIDDataTesting target, VettIDKeys's VettIDKeysTesting target with
#     the software phone key, VettIDAltChan's VettIDAltChanTesting target
#     with the TEST iOS attester and the dev stack's helpers, the TEST
#     attester's App ID, the VettIDDevStack app's wiring and the symbols of
#     the TEST attester and the software keys),
#   - a dev-stack address or a debug-only tool,
#   - the other environment's hosts,
#   - the VAULT-MESSAGING §16 TEST manifest key (a canary manifest is
#     accepted only under the keys the build pins),
# or lacks its own account host, the Secure Enclave phone key or the JSON
# document type a canary manifest is opened with, or has another bundle id,
# or is not signed for App Attest's production environment. The archives
# must hold the VettID app alone; the VettID and VettIDStagingUITests
# schemes must not name the VettIDDevStack app or its UI tests (IOS-PLAN
# §8 exit I1 (a): built by its own scheme, in the DevStack configuration);
# the VettID target must link no `*Testing` product and compile no file of
# AppDevStack/; and the VettIDDevStack targets must be simulator only.
#
#   scripts/release-check.sh              build both, check both
#   scripts/release-check.sh --self-test  also plant a TEST string and a
#                                         staging host in a copy of each
#                                         app and require the check to fail
set -euo pipefail

cd "$(dirname "$0")/.."

OUT=build/release-check
SELF_TEST=0
[[ "${1:-}" == "--self-test" ]] && SELF_TEST=1

# Strings no Release or Staging app may contain.
# The deterministic randomness hook of VettIDCrypto (debug builds only), VettIDDataTesting's fake, VettIDKeysTesting's
# software keys (IOS-PLAN §6.3: no software phone key in Release or Staging) and VettIDAltChanTesting's TEST iOS
# attester (IOS-PLAN §6.2) carry "VETTID TEST ONLY".
# The VettIDDevStack app's wiring (AppDevStack/DevStackWiring.swift), its launch environment's names, and the type names of
# the TEST attester and the software keys it composes are refused by name too.
TEST_MARKERS=("VettIDTesting" "VettIDDataTesting" "VettIDKeysTesting" "VettIDAltChanTesting" "TESTTEAM00" "VETTID TEST ONLY"
  "DevStackWiring" "VETTID_DEVSTACK" "TestIOSAttester" "SoftwareAppKeyStore" "SoftwarePhoneSecretSource")
# "Scan: another environment", "Keys gone, earlier keys to try", "Held: messages and a call waiting" and "Drawer open"
# are titles of the onboarding, unlock, owner-check and shell screen catalogs (App/Debug, debug builds only); "Xcode
# (development)" is the development builds' "Installed from" line (IOS-PLAN ID15, App/InstalledFromBuild.swift).
DEV_ONLY=("127.0.0.1" "relay.vettid.test" "vettid.start" "vettid.theme" "Component gallery" "Screen catalog"
  "Scan: another environment" "Keys gone, earlier keys to try" "Held: messages and a call waiting" "Drawer open"
  "Xcode (development)")

PRODUCTION_HOSTS=("account.vettid.org")
STAGING_HOSTS=("staging.vettid.org")
# The staging channel's manifest key A (its SPKI and its key id): pinned by Staging and Debug builds only (ID10 of the
# manifest pins; VettIDAttestation's ManifestKeys holds only the production keys).
STAGING_KEYS=("MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEok8gqeC5VcGx4KL+B5fL7UgENBXf" "e9b3a403423120ac")
# The VAULT-MESSAGING §16 TEST manifest key (private scalar 32 x 0x21, public; its SPKI and key id): the tests sign canary
# manifests with it; no build may pin it, or anyone could sign a canary manifest that build accepts.
TEST_MANIFEST_KEY=("MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAERi26GuT8GpaLTazyDN1tvh" "1edbb48b6669decd")
# The document type a canary manifest is opened with (VAULT-RELEASES §10.1 step 9): it works in Release and Staging too.
DOCUMENT_TYPES=("public.json")

archive() {
  local config=$1
  echo "== archiving ${config} (unsigned)"
  xcodebuild archive \
    -project VettID.xcodeproj -scheme VettID -configuration "${config}" \
    -destination 'generic/platform=iOS' \
    -archivePath "${OUT}/${config}.xcarchive" \
    -derivedDataPath "${OUT}/DerivedData" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
    -quiet
}

# Everything readable in an app bundle: printable strings of each Mach-O
# file, property lists as XML, and every other file as is.
bundle_text() {
  local app=$1
  find "${app}" -type f -print0 | while IFS= read -r -d '' f; do
    if file -b "${f}" | grep -q 'Mach-O'; then
      strings -a "${f}"
    elif [[ "${f}" == *.plist ]]; then
      plutil -convert xml1 -o - "${f}" 2>/dev/null || cat "${f}"
    else
      cat "${f}"
    fi
  done
}

# check_app <app> <expected bundle id> <required...> -- <forbidden...>
check_app() {
  local app=$1 bundle_id=$2
  shift 2
  local required=() forbidden=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do required+=("$1"); shift; done
  shift
  forbidden=("$@")

  local text
  text=$(mktemp)
  bundle_text "${app}" >"${text}"

  local problems=()
  local actual
  actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app}/Info.plist")
  [[ "${actual}" == "${bundle_id}" ]] || problems+=("bundle id ${actual}, expected ${bundle_id}")
  for s in "${required[@]}"; do
    grep -qF -- "${s}" "${text}" || problems+=("missing '${s}'")
  done
  for s in "${forbidden[@]}"; do
    grep -qF -- "${s}" "${text}" && problems+=("forbidden '${s}'")
  done
  rm -f "${text}"

  if [[ ${#problems[@]} -gt 0 ]]; then
    printf '%s: %s\n' "${app}" "${problems[@]}" >&2
    return 1
  fi
  echo "${app}: ${#forbidden[@]} forbidden strings absent, ${#required[@]} required present"
}

# The Secure Enclave phone key, the only phone key a Release or Staging app may hold (IOS-PLAN §6.3), and the real
# App Attest service (IOS-PLAN §6.2) are linked.
HARDWARE_KEYS=("SecureEnclavePhoneSecretSource" "DeviceCheckAppAttestService")

check_release() {
  check_app "$1" com.vettid.app "${PRODUCTION_HOSTS[@]}" "${HARDWARE_KEYS[@]}" "${DOCUMENT_TYPES[@]}" \
    -- "${TEST_MARKERS[@]}" "${DEV_ONLY[@]}" "${STAGING_HOSTS[@]}" "${STAGING_KEYS[@]}" "${TEST_MANIFEST_KEY[@]}"
}

check_staging() {
  check_app "$1" com.vettid.app.staging "account.staging.vettid.org" "${HARDWARE_KEYS[@]}" "${DOCUMENT_TYPES[@]}" \
    -- "${TEST_MARKERS[@]}" "${DEV_ONLY[@]}" "${PRODUCTION_HOSTS[@]}" "${TEST_MANIFEST_KEY[@]}"
}

app_of() { echo "${OUT}/$1.xcarchive/Products/Applications/VettID.app"; }

# An archive holds the VettID app alone: never the VettIDDevStack app (SKIP_INSTALL, and not in the VettID scheme).
check_archive_products() {
  local config=$1 products
  products=$(find "${OUT}/${config}.xcarchive/Products" -mindepth 1 -maxdepth 3 -name '*.app' -exec basename {} \; | sort | tr '\n' ' ')
  [[ "${products}" == "VettID.app " ]] || { echo "${config} archive: apps '${products}', expected VettID.app alone" >&2; return 1; }
  echo "${config} archive: VettID.app alone"
}

# The package products the VettID app links: exactly these (one per shipping package of project.yml).
APP_PRODUCTS="VettIDCrypto VettIDAttestation VettIDRelay VettIDAltChan VettIDVault VettIDKeys VettIDData VettIDMedia
VettIDNotify VettIDUI VettIDOnboarding VettIDSettings VettIDShell VettIDConnections VettIDMessages VettIDApprovals
VettIDNotifications"

# The VettID app target (whatever the scheme) links exactly APP_PRODUCTS (each product id resolved to its productName)
# and compiles no file of AppDevStack/, read from the project file: its package products and its Sources phase.
check_app_target() {
  local pbxproj=$1
  python3 - "${pbxproj}" AppDevStack "${APP_PRODUCTS}" <<'PY'
import os, re, sys
text = open(sys.argv[1]).read()
devstack = {f for f in os.listdir(sys.argv[2]) if f.endswith(".swift")}
allowed = set(sys.argv[3].split())
m = re.search(r"\n\t\t(\w+) /\* VettID \*/ = \{\n\t\t\tisa = PBXNativeTarget;(.*?)\n\t\t\};", text, re.S)
if not m:
    sys.exit("no VettID target in the project file")
target = m.group(2)
def listed(key, block):
    l = re.search(r"\t" + key + r" = \((.*?)\);", block, re.S)
    return re.findall(r"(\w+) /\* (.*?) \*/", l.group(1)) if l else []
def product(pid):
    d = re.search(r"\n\t\t" + pid + r" /\* .*? \*/ = \{\n\t\t\tisa = XCSwiftPackageProductDependency;(.*?)\n\t\t\};", text, re.S)
    n = re.search(r"\n\t\t\tproductName = \"?([^\";]+)\"?;", d.group(1)) if d else None
    return n.group(1) if n else "<unresolved " + pid + ">"
products = [product(pid) for pid, _ in listed("packageProductDependencies", target)]
phases = [i for i, name in listed("buildPhases", target) if name == "Sources"]
if not products or len(phases) != 1:
    sys.exit("the VettID target's package products or Sources phase not found")
phase = re.search(r"\n\t\t" + phases[0] + r" /\* Sources \*/ = \{(.*?)\n\t\t\};", text, re.S).group(1)
sources = [re.sub(r" in Sources$", "", name) for _, name in listed("files", phase)]
if not sources:
    sys.exit("the VettID target's Sources phase is empty")
if set(products) != allowed or len(products) != len(allowed):
    sys.exit("the VettID target links " + ", ".join(sorted(set(products) ^ allowed)) + " against the allowlist")
bad = [f for f in sources if f in devstack]
if bad:
    sys.exit("the VettID target compiles TEST-only " + ", ".join(bad))
print(f"VettID target: the {len(products)} allowed package products, {len(sources)} sources, none TEST-only")
PY
}

# The VettIDDevStack app and its UI tests are built for the simulator only: never an iPhone, a Mac or a headset.
check_devstack_platforms() {
  local target settings
  for target in VettIDDevStack VettIDDevStackUITests; do
    settings=$(xcodebuild -showBuildSettings -project VettID.xcodeproj -target "${target}" -configuration DevStack 2>/dev/null)
    grep -qE '^ *SUPPORTED_PLATFORMS = iphonesimulator$' <<<"${settings}" ||
      { echo "${target}: SUPPORTED_PLATFORMS is not iphonesimulator alone" >&2; return 1; }
    grep -qE '^ *SUPPORTS_MACCATALYST = NO$' <<<"${settings}" ||
      { echo "${target}: SUPPORTS_MACCATALYST is not NO" >&2; return 1; }
  done
  echo "VettIDDevStack, VettIDDevStackUITests: simulator only"
}

# The schemes that archive Release and Staging never build the VettIDDevStack app or its UI tests.
SHIPPING_SCHEMES=(VettID VettIDStagingUITests)
check_schemes() {
  local scheme file
  for scheme in "${SHIPPING_SCHEMES[@]}"; do
    file="VettID.xcodeproj/xcshareddata/xcschemes/${scheme}.xcscheme"
    [[ -f "${file}" ]] || { echo "no scheme ${scheme}" >&2; return 1; }
    if grep -qF "VettIDDevStack" "${file}"; then
      echo "the ${scheme} scheme names the VettIDDevStack app or its UI tests" >&2
      return 1
    fi
  done
  echo "schemes ${SHIPPING_SCHEMES[*]}: no VettIDDevStack target"
}

# The archives are unsigned, so their entitlements are checked at the source: Release and Staging sign with the
# production App Attest environment (IOS-PLAN §6.2; the vault accepts only it).
check_entitlements_file() {
  local what=$1 file=$2 env
  [[ -n "${file}" && -f "${file}" ]] || { echo "${what}: no entitlements file" >&2; return 1; }
  env=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.devicecheck.appattest-environment' "${file}" 2>/dev/null || true)
  [[ "${env}" == "production" ]] || { echo "${what}: App Attest environment '${env}', expected production" >&2; return 1; }
  echo "${what}: App Attest environment production (${file})"
}

check_entitlements() {
  local config=$1 file
  file=$(xcodebuild -showBuildSettings -project VettID.xcodeproj -target VettID -configuration "${config}" 2>/dev/null |
    sed -n 's/^ *CODE_SIGN_ENTITLEMENTS = //p')
  check_entitlements_file "${config}" "${file}"
}

# The test-only hooks of the pure packages are compiled into debug builds only (#if DEBUG). The app may not link a
# package's code yet (it is then dead-stripped and the scan above proves nothing), so the packages are also built on
# their own: the release build must not contain the marker, and the debug build must (or the scan finds nothing).
# The package's compiled objects under a SwiftPM bin path, in either build system's layout; fails when there are none.
package_objects() {
  local bin=$1 pkg=$2 files
  files=$(find "${bin}" -maxdepth 1 \( -name "${pkg}.o" -o -name "lib${pkg}.a" \) 2>/dev/null)
  [[ -z "${files}" && -d "${bin}/${pkg}.build" ]] && files=$(find "${bin}/${pkg}.build" -name '*.o')
  if [[ -z "${files}" ]]; then
    echo "no compiled objects of ${pkg} under ${bin}" >&2
    return 1
  fi
  echo "${files}"
}

check_package_hooks() {
  local pkg=$1 marker=$2
  echo "== ${pkg}: test hooks in debug builds only"
  swift build --package-path "Packages/${pkg}" -c debug --quiet
  swift build --package-path "Packages/${pkg}" -c release --quiet
  local found_debug found_release debug_bin release_bin
  debug_bin=$(swift build --package-path "Packages/${pkg}" -c debug --show-bin-path)
  release_bin=$(swift build --package-path "Packages/${pkg}" -c release --show-bin-path)
  found_debug=$(package_objects "${debug_bin}" "${pkg}" | xargs strings -a | grep -cF -- "${marker}" || true)
  found_release=$(package_objects "${release_bin}" "${pkg}" | xargs strings -a | grep -cF -- "${marker}" || true)
  if [[ "${found_debug}" -eq 0 ]]; then
    echo "${pkg}: the debug build lacks the marker '${marker}'; the check would prove nothing" >&2
    return 1
  fi
  if [[ "${found_release}" -ne 0 ]]; then
    echo "${pkg}: the release build contains the test hook ('${marker}')" >&2
    return 1
  fi
  echo "${pkg}: test hook present in debug, absent in release"
}

check_package_hooks VettIDCrypto "VETTID TEST ONLY"
check_schemes
check_app_target VettID.xcodeproj/project.pbxproj
check_devstack_platforms
check_entitlements Release
check_entitlements Staging

rm -rf "${OUT}/Release.xcarchive" "${OUT}/Staging.xcarchive"
archive Release
archive Staging
check_archive_products Release
check_archive_products Staging
check_release "$(app_of Release)"
check_staging "$(app_of Staging)"

# Every object file the two archives compiled (the app's and every package's, before the linker strips unused code)
# is free of the TEST markers too.
echo "== objects compiled for the Release and Staging archives"
objects=$(find "${OUT}/DerivedData/Build/Intermediates.noindex" -name '*.o' | wc -l | tr -d ' ')
[[ "${objects}" -gt 0 ]] || { echo "no compiled objects under ${OUT}/DerivedData" >&2; exit 1; }
for marker in "${TEST_MARKERS[@]}"; do
  if find "${OUT}/DerivedData/Build/Intermediates.noindex" -name '*.o' -exec strings -a {} + | grep -qF -- "${marker}"; then
    echo "an object compiled for Release or Staging contains '${marker}'" >&2
    exit 1
  fi
done
echo "${objects} objects: ${#TEST_MARKERS[@]} TEST markers absent"

if [[ ${SELF_TEST} -eq 1 ]]; then
  # plant <config> <checker> <string>: the check must refuse a copy of the
  # app that carries <string>.
  plant() {
    local config=$1 checker=$2 planted=$3
    local copy="${OUT}/planted/${config}/VettID.app"
    rm -rf "${OUT}/planted/${config}"
    mkdir -p "$(dirname "${copy}")"
    cp -R "$(app_of "${config}")" "${copy}"
    printf '%s\n' "${planted}" >"${copy}/planted.txt"
    if "${checker}" "${copy}" 2>/dev/null; then
      echo "self-test FAILED: ${config} accepted a planted '${planted}'" >&2
      exit 1
    fi
    echo "self-test: ${config} refuses a planted '${planted}'"
  }
  plant Release check_release "VettIDTesting"
  plant Release check_release "VettIDDataTesting"
  plant Release check_release "VETTID TEST ONLY: the repository-level fake"
  plant Release check_release "VETTID TEST ONLY: deterministic randomness drew the wrong size"
  plant Release check_release "VettIDKeysTesting"
  plant Release check_release "VETTID TEST ONLY: software keys instead of the Secure Enclave"
  plant Staging check_staging "VettIDKeysTesting"
  plant Staging check_staging "VETTID TEST ONLY: software keys instead of the Secure Enclave"
  plant Release check_release "VettIDAltChanTesting"
  plant Release check_release "VETTID TEST ONLY: the TEST App Attest attester"
  plant Staging check_staging "VettIDAltChanTesting"
  plant Staging check_staging "VETTID TEST ONLY: the TEST App Attest attester"
  plant Release check_release "VETTID TEST ONLY: the local dev stack's helpers"
  plant Release check_release "VETTID TEST ONLY: the dev stack app's wiring"
  plant Staging check_staging "VETTID TEST ONLY: the dev stack app's wiring"
  plant Release check_release "DevStackWiring"
  plant Staging check_staging "VETTID_DEVSTACK_NITRO_ROOT"
  plant Release check_release "TestIOSAttester"
  plant Staging check_staging "SoftwareAppKeyStore"
  plant Release check_release "SoftwarePhoneSecretSource"
  plant Release check_release "account.staging.vettid.org"
  plant Release check_release "Scan: another environment"
  plant Staging check_staging "Scan: another environment"
  plant Staging check_staging "TESTTEAM00.com.vettid.app"
  plant Staging check_staging "127.0.0.1"
  plant Release check_release "Installed from: Xcode (development)"
  plant Staging check_staging "Installed from: Xcode (development)"
  plant Release check_release "Drawer open"
  plant Staging check_staging "Drawer open"
  for key in "${TEST_MANIFEST_KEY[@]}"; do
    plant Release check_release "${key}"
    plant Staging check_staging "${key}"
  done
  # An entitlements file for the development environment, or none, must be refused.
  dev="${OUT}/planted/development.entitlements"
  mkdir -p "$(dirname "${dev}")"
  sed 's|<string>production</string>|<string>development</string>|' Config/VettID-production.entitlements >"${dev}"
  for f in "${dev}" "${OUT}/planted/none.entitlements"; do
    if check_entitlements_file planted "${f}" >/dev/null 2>&1; then
      echo "self-test FAILED: the entitlement check accepted ${f}" >&2
      exit 1
    fi
  done
  echo "self-test: the entitlement check refuses the development environment and a missing file"
  # An archive that also holds the VettIDDevStack app, and a shipping scheme that names it, must be refused.
  extra="${OUT}/Release.xcarchive/Products/Applications/VettIDDevStack.app"
  mkdir -p "${extra}"
  if check_archive_products Release >/dev/null 2>&1; then
    rm -rf "${extra}"
    echo "self-test FAILED: the archive check accepted an archive with VettIDDevStack.app" >&2
    exit 1
  fi
  rm -rf "${extra}"
  echo "self-test: the archive check refuses an archive with VettIDDevStack.app"
  planted_schemes="${OUT}/planted/schemes"
  rm -rf "${planted_schemes}"
  mkdir -p "${planted_schemes}"
  cp VettID.xcodeproj/xcshareddata/xcschemes/VettID.xcscheme "${planted_schemes}/"
  if (
    cd "${planted_schemes}" && mkdir -p VettID.xcodeproj/xcshareddata/xcschemes &&
      cp VettID.xcscheme VettID.xcodeproj/xcshareddata/xcschemes/ &&
      cp VettID.xcscheme VettID.xcodeproj/xcshareddata/xcschemes/VettIDStagingUITests.xcscheme &&
      printf '%s\n' '<BuildableReference BlueprintName = "VettIDDevStack">' >>VettID.xcodeproj/xcshareddata/xcschemes/VettID.xcscheme &&
      check_schemes
  ) >/dev/null 2>&1; then
    echo "self-test FAILED: the scheme check accepted a VettID scheme naming VettIDDevStack" >&2
    exit 1
  fi
  echo "self-test: the scheme check refuses a shipping scheme naming VettIDDevStack"
  # A VettID target that links a product off the allowlist (a TEST one), or compiles the dev stack wiring, must be refused.
  planted_pbx="${OUT}/planted/project.pbxproj"
  for swap in "s|productName = VettIDKeys;|productName = VettIDKeysTesting;|" \
    "s|/\* AppDelegate.swift in Sources \*/|/* DevStackWiring.swift in Sources */|"; do
    sed "${swap}" VettID.xcodeproj/project.pbxproj >"${planted_pbx}"
    if cmp -s "${planted_pbx}" VettID.xcodeproj/project.pbxproj; then
      echo "self-test FAILED: '${swap}' changed nothing in the project file" >&2
      exit 1
    fi
    if check_app_target "${planted_pbx}" >/dev/null 2>&1; then
      echo "self-test FAILED: the target check accepted a project file after '${swap}'" >&2
      exit 1
    fi
  done
  echo "self-test: the target check refuses a VettID target with a TEST product or the dev stack wiring"
  # A required string removed (renamed in place, same length) from a copy of each app must fail the check.
  unplant() {
    local config=$1 checker=$2 required=$3
    local copy="${OUT}/planted/${config}-without/VettID.app"
    rm -rf "${OUT}/planted/${config}-without"
    mkdir -p "$(dirname "${copy}")"
    cp -R "$(app_of "${config}")" "${copy}"
    find "${copy}" -type f -exec perl -0777 -pi -e "s/\Q${required}\E/'X' x length('${required}')/ge" {} +
    if "${checker}" "${copy}" 2>/dev/null; then
      echo "self-test FAILED: ${config} accepted an app without '${required}'" >&2
      exit 1
    fi
    echo "self-test: ${config} refuses an app without '${required}'"
  }
  for key in "${HARDWARE_KEYS[@]}" "${DOCUMENT_TYPES[@]}"; do
    unplant Release check_release "${key}"
    unplant Staging check_staging "${key}"
  done
fi

echo "release check passed"
