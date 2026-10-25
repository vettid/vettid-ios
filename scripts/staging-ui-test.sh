#!/usr/bin/env bash
# Staging end-to-end UI tests on a real iPhone (STAGING-TESTING §3 "Enrolling a phone", §5): builds the Staging app and
# the UI tests once (VettIDStagingUITests scheme), then runs one test of AppUITests/StagingTests.swift on the iPhone with
# the inputs handed to the test runner at run time. Nothing secret is in the repository; this script issues no codes:
# the enrollment code comes from the account site's "Enroll a phone", signed in as the test member, just before the run
# (it lives 5 minutes and works once).
#
#   scripts/staging-ui-test.sh --device <id> --test <test> [--inputs <file>] [--fresh] [--skip-build] [--keep-result] [--auto-match]
#
#   --device <id>     the iPhone (`xcrun devicectl list devices`)
#   --test <test>     testStagingEnroll, testStagingUnlockLock, testStagingApproveUpdate,
#                     testStagingApproveUpdateAtUnlock, testStagingCheckNow, testStagingWrongPinInPasswordChange,
#                     testStagingConnectAccept, testStagingConnectApprove, testStagingMessageSend,
#                     testStagingMessageReceive, testStagingPhotoSend, testStagingPhotoReceive, testStagingInvite,
#                     testStagingApproveRequest, testStagingRotate, testStagingSendAll, testStagingWaitMessage,
#                     testStagingTransferIn, testStagingTransferOut, testStagingLook or testStagingCheck
#   --inputs <file>   a private file outside the repository (chmod 600) with lines NAME=value for
#                     VETTID_STAGING_EMAIL, VETTID_STAGING_CODE, VETTID_STAGING_PIN, VETTID_STAGING_PASSWORD and, for
#                     the connect tests, VETTID_STAGING_LINK and VETTID_STAGING_SAFETY_CODE, and for the message
#                     tests, VETTID_STAGING_PEER_NAME, VETTID_STAGING_MESSAGE and VETTID_STAGING_EXPECT, and for the
#                     photo tests, VETTID_STAGING_PEER_NAME and optionally VETTID_STAGING_PHOTO_TIMEOUT (quotes around
#                     a value and CRLF line ends are stripped), and for the transfer tests, VETTID_STAGING_TRANSFER_CODE
#                     (testStagingTransferIn) and optionally VETTID_STAGING_TRANSFER_TIMEOUT. Only the file is read
#                     then; without it they are read from the environment of the same names. Prefer the file:
#                     nothing lands in the shell history.
#   --fresh           remove VettID Staging from the iPhone first, and its vault keys with it: only for
#                     testStagingEnroll with all four inputs set; asks y/N on a terminal
#   --skip-build      reuse the last build-for-testing
#   --auto-match      only with --test testStagingTransferOut: the test taps "The codes match" itself, so the safety
#                     codes are NOT compared (a warning is printed first). Only this flag enables it.
#   --keep-result     keep the result bundle (it holds what was typed) in the private cache directory
#
# The tests (each ends with the vault locked and the lock confirmed, except testStagingTransferOut, which locks only when
# the move did not happen and never after "moved", and testStagingTransferIn, which locks only after moved_unlocked):
#   testStagingEnroll                    a fresh app enrolled with the code, the PIN and the password
#   testStagingUnlockLock                unlock with the PIN (and the password when the daily check is due), then lock
#   testStagingApproveUpdate             Settings -> "Update available", approved with the PIN; skipped without one
#   testStagingApproveUpdateAtUnlock     the unlock screen's update offer, approved with the unlock; skipped without one
#   testStagingCheckNow                  Settings -> the daily check's "Check now" with the PIN and the password: the
#                                        voluntary check passes
#   testStagingWrongPinInPasswordChange  Settings -> Credential -> Change password with a wrong PIN (the input PIN with
#                                        its last digit changed): the vault's refusal is shown and the form is left
#                                        without a retry, so the password is never changed. The wrong PIN counts as
#                                        a failed owner check (VAULT-MESSAGING §3.6.1), which the next passed check
#                                        resets; so follow it with testStagingCheckNow.
#   testStagingConnectAccept             Connections -> add -> "Paste a link" with VETTID_STAGING_LINK (another
#                                        member's https invitation link), "Connect", and the compare screen; prints
#                                        "SAFETY_CODE: <code>" for the other member to compare (and keeps it as the
#                                        attachment "safety-code"). Nothing is approved.
#   testStagingConnectApprove            Connections -> the request card that can be approved (the one showing
#                                        VETTID_STAGING_SAFETY_CODE when it is set, which then must match or nothing is
#                                        approved; otherwise the only one), "Approve"; prints "SAFETY_CODE: <code>" and
#                                        "CONNECT_STATE: <state>" (approved_waiting_for_peer or connected when it
#                                        passes; ended, peer_declined, error or unknown when it fails).
#   testStagingMessageSend               Messages -> the conversation with the connection shown as
#                                        VETTID_STAGING_PEER_NAME (or the compose button's picker when there is none
#                                        yet), VETTID_STAGING_MESSAGE typed and sent, its bubble followed to
#                                        "Delivered"; prints "MESSAGE_STATE: <state>" (delivered or read when it passes;
#                                        sent or none when it fails).
#   testStagingMessageReceive            the conversation with VETTID_STAGING_PEER_NAME, until a message from it shows
#                                        VETTID_STAGING_EXPECT (within a minute); prints "MESSAGE_RECEIVED: yes|no".
#   testStagingPhotoSend                 the conversation with VETTID_STAGING_PEER_NAME -> the photo button ->
#                                        "Choose photos", the first photo of the system's picker, Send on the prepared
#                                        photo, its bubble followed to "Delivered"; prints "PHOTO_STATE: <state>"
#                                        (delivered when it passes; sending, failed or none when it fails). The
#                                        iPhone's photo library must hold at least one photo (the test fails without
#                                        one and never adds any).
#   testStagingPhotoReceive              the conversation with VETTID_STAGING_PEER_NAME, until a new photo from it
#                                        shows its thumbnail (one already in the conversation when it opened never
#                                        counts: start this test first and send once it is waiting), then that photo
#                                        in the viewer, shown and not a failure; prints "PHOTO_RECEIVED: yes|no" and
#                                        "PHOTO_VIEWER: shown|failed|loading".
#   testStagingInvite                    Connections -> add -> invite, a 24-hour remote invitation; prints
#                                        "INVITE_LINK: <link>" for the other member to paste (testStagingConnectAccept
#                                        there). The invitation stays open on the vault.
#   testStagingApproveRequest            Approvals -> the link requests whose safety codes are VETTID_STAGING_SAFETY_CODE
#                                        (comma-separated), each opened and approved: an incoming request, or the
#                                        member's own after joining a link (both members approve, VAULT-MESSAGING
#                                        §6.4); prints "CONNECT_STATE: approved|not_approved|not_opened|missing" for
#                                        each.
#   testStagingRotate                    Settings -> Credential -> "Rotate the credential key" with the password (the
#                                        vault's keys rotate with it, VAULT-MESSAGING §3.5.5); prints
#                                        "ROTATE_STATE: done|failed|none".
#   testStagingSendAll                   to each connection of VETTID_STAGING_PEER_NAME ("Name=label;Name=label"),
#                                        "<VETTID_STAGING_MESSAGE> to <label> <UTC>" followed to Delivered (a
#                                        "MESSAGE_STATE:" line each, in order); then each conversation checked for an
#                                        new incoming message holding VETTID_STAGING_EXPECT (a "MESSAGE_RECEIVED:" line
#                                        each).
#   testStagingWaitMessage               the conversation with VETTID_STAGING_PEER_NAME kept open until a message from
#                                        it holds VETTID_STAGING_EXPECT (one already there does not count); prints
#                                        "MESSAGE_RECEIVED: yes|no".
#   testStagingTransferOut               the old phone, unlocked: Settings -> Security -> "Move to a new phone", start;
#                                        prints "TRANSFER_LINK: <link>" for the new phone (VETTID_STAGING_TRANSFER_CODE
#                                        there), waits up to VETTID_STAGING_TRANSFER_TIMEOUT (300 s) for the new phone,
#                                        prints "SAFETY_CODE: <code>" and "TRANSFER_OPERATOR: ...", then WAITS (up to the
#                                        same time) for a person to compare the codes on both phones and tap "The codes
#                                        match" or "Reject" on this iPhone; it never approves by itself. After a person taps
#                                        "The codes match" the test goes on BY ITSELF: it accepts the change of signer
#                                        when shown and confirms "Move" (a person decides only the comparison). The
#                                        change of signer when shown ("TRANSFER_SIGNER: shown", a move between platforms),
#                                        PIN on the keypad (nothing is sent unless it holds every digit) and the password,
#                                        "Move"; prints "TRANSFER_AFTER: kept|welcome_notice|welcome|none" (release R keeps the keys
#                                        until the new phone has finished: nothing more is tapped and nothing is locked;
#                                        or the app erased itself) and "TRANSFER_STATE: moved|rejected|expired|no_decision|
#                                        no_link|no_phone|no_safety_code|approve_failed|approve_unknown|error|none". After a state other
#                                        than moved the vault is locked only from a screen before the approval and never
#                                        once "Move" was tapped; a stuck confirmation or a running approval leaves it unlocked. With --auto-match
#                                        (this test only) the test taps "The codes match" itself and prints
#                                        "TRANSFER_SAS_UNCHECKED": the comparison is then NOT made. It cannot be set by the
#                                        inputs file or the environment.
#   testStagingTransferIn                the new phone, a fresh app (no --fresh: remove the app by hand): "Move from my
#                                        old phone", the code pasted from VETTID_STAGING_TRANSFER_CODE, prints
#                                        "SAFETY_CODE: <code>", waits up to VETTID_STAGING_TRANSFER_TIMEOUT for the old
#                                        phone's approval (a handshake that will not finish is cancelled), "Finish the move"
#                                        with the PIN (all digits or nothing is sent); prints "TRANSFER_STATE:
#                                        moved_unlocked|moved_locked|moved|code_refused|no_safety_code|rejected|timed_out|
#                                        not_answered|finish_held|finish_failed|owner_check|owner_check_failed|
#                                        moved_unconfirmed|error|none". VETTID_STAGING_PASSWORD is used only if an owner check
#                                        is due after the move.
#   testStagingLook, testStagingCheck    screenshots only, nothing tapped beyond navigation: Connections and Approvals
#                                        (Look); Connections, the conversation with VETTID_STAGING_PEER_NAME,
#                                        Connections again and History (Check). Use --keep-result to read them.
#
# Inputs per test: testStagingEnroll needs all four of EMAIL, CODE, PIN and PASSWORD; every other test PIN and PASSWORD;
# testStagingConnectAccept also VETTID_STAGING_LINK; VETTID_STAGING_SAFETY_CODE is optional (testStagingConnectApprove);
# testStagingMessageSend also VETTID_STAGING_PEER_NAME and VETTID_STAGING_MESSAGE, testStagingMessageReceive
# VETTID_STAGING_PEER_NAME and VETTID_STAGING_EXPECT; testStagingPhotoSend and testStagingPhotoReceive also
# VETTID_STAGING_PEER_NAME, with VETTID_STAGING_PHOTO_EXISTING=1 optional (testStagingPhotoReceive takes the newest photo
# already in the conversation and checks its viewer) and VETTID_STAGING_PHOTO_TIMEOUT optional (the seconds they wait for the delivery or the
# arrival; 180 without it). testStagingInvite, testStagingRotate and testStagingLook need only PIN and PASSWORD;
# testStagingApproveRequest also VETTID_STAGING_SAFETY_CODE; testStagingSendAll VETTID_STAGING_PEER_NAME,
# VETTID_STAGING_MESSAGE and VETTID_STAGING_EXPECT; testStagingWaitMessage VETTID_STAGING_PEER_NAME and
# VETTID_STAGING_EXPECT; testStagingCheck VETTID_STAGING_PEER_NAME. VETTID_STAGING_WAIT (seconds) is optional for
# testStagingWaitMessage (600), testStagingSendAll (300) and testStagingLook (10).
#
# Inputs of the transfer tests: testStagingTransferOut needs PIN and PASSWORD; testStagingTransferIn needs PIN and
# VETTID_STAGING_TRANSFER_CODE. Two-phone run (both at once; the code window is about 5 minutes and the code works once):
# start testStagingTransferOut on the old phone; copy its "TRANSFER_LINK:" line into the new phone's file as
# VETTID_STAGING_TRANSFER_CODE (the link is not an input of the old phone: it is printed there, and nowhere else, to be
# handed over); start testStagingTransferIn on the new phone; compare the two "SAFETY_CODE:" lines and tap "The codes
# match" on the old phone. The safety codes are not shared through VETTID_STAGING_SAFETY_CODE. iPhone <-> iPhone: build once
# (the first run), then give the second run --skip-build, so that the window is not spent building; an iPhone <-> Android
# move has the other side run its own test. Use a separate private file for each phone.
#
# A test without its inputs is skipped. The inputs reach only the test step, as TEST_RUNNER_<NAME> (xcodebuild passes
# them to the runner as <NAME>), never a command line or the build; xcodebuild's output is shown with them (the link
# included, the connection's name, the message texts, and the keypad's digits) redacted, except the SAFETY_CODE,
# CONNECT_STATE, MESSAGE_STATE, MESSAGE_RECEIVED, PHOTO_STATE, PHOTO_RECEIVED, PHOTO_VIEWER, INVITE_LINK,
# TRANSFER_LINK (its value is then redacted from every later line), TRANSFER_STATE, TRANSFER_SIGNER, TRANSFER_AFTER, TRANSFER_OPERATOR, TRANSFER_SAS_UNCHECKED and ROTATE_STATE lines, which are printed with the code, the state or the answer alone; the result bundle is deleted, an interrupted run's too, unless --keep-result. The build
# and results live under ${XDG_CACHE_HOME:-~/Library/Caches}/vettid-ios/staging-ui-test (mode 700).
#
# Example (enrollment; the code was issued a minute ago and is in the private file):
#   scripts/staging-ui-test.sh --device <id> --test testStagingEnroll --inputs <private file> --fresh
# Example (connect: the accepting phone's private file also holds VETTID_STAGING_LINK; then, on the inviter's phone,
# with the printed code as VETTID_STAGING_SAFETY_CODE in its file):
#   scripts/staging-ui-test.sh --device <id> --test testStagingConnectAccept --inputs <private file>
#   scripts/staging-ui-test.sh --device <id> --test testStagingConnectApprove --inputs <private file>
# Example (messages: one phone sends, the other, whose file has the same text as VETTID_STAGING_EXPECT, receives):
#   scripts/staging-ui-test.sh --device <id> --test testStagingMessageSend --inputs <private file>
#   scripts/staging-ui-test.sh --device <id> --test testStagingMessageReceive --inputs <private file>
# Example (photos: the receiving phone starts waiting first, then the other phone sends):
#   scripts/staging-ui-test.sh --device <id> --test testStagingPhotoReceive --inputs <private file>
#   scripts/staging-ui-test.sh --device <id> --test testStagingPhotoSend --inputs <private file>
set -euo pipefail

cd "$(dirname "$0")/.."
REPO=$(pwd -P)

NAMES=(VETTID_STAGING_EMAIL VETTID_STAGING_CODE VETTID_STAGING_PIN VETTID_STAGING_PASSWORD)
# The connect, message and photo tests' inputs: optional, never counted as missing for the others.
OPTIONAL=(VETTID_STAGING_LINK VETTID_STAGING_TRANSFER_CODE VETTID_STAGING_TRANSFER_TIMEOUT VETTID_STAGING_SAFETY_CODE VETTID_STAGING_PEER_NAME VETTID_STAGING_MESSAGE VETTID_STAGING_EXPECT
  VETTID_STAGING_PHOTO_TIMEOUT VETTID_STAGING_PHOTO_EXISTING VETTID_STAGING_WAIT)
ALL=("${NAMES[@]}" "${OPTIONAL[@]}")
BUNDLE_ID=com.vettid.app.staging

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }

DEVICE="" TEST="" INPUTS="" FRESH=0 SKIP_BUILD=0 KEEP=0 AUTO_MATCH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE=${2:-}; shift 2 ;;
    --test) TEST=${2:-}; shift 2 ;;
    --inputs) INPUTS=${2:-}; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --keep-result) KEEP=1; shift ;;
    --auto-match) AUTO_MATCH=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[[ -n "${DEVICE}" ]] || { echo "--device is required" >&2; usage; }
case "${TEST}" in
  testStagingEnroll|testStagingUnlockLock|testStagingApproveUpdate|testStagingApproveUpdateAtUnlock|testStagingCheckNow) ;;
  testStagingWrongPinInPasswordChange|testStagingConnectAccept|testStagingConnectApprove) ;;
  testStagingMessageSend|testStagingMessageReceive|testStagingPhotoSend|testStagingPhotoReceive) ;;
  testStagingInvite|testStagingApproveRequest|testStagingRotate|testStagingSendAll|testStagingWaitMessage) ;;
  testStagingTransferIn|testStagingTransferOut) ;;
  testStagingLook|testStagingCheck) ;;
  *) echo "--test must be testStagingEnroll, testStagingUnlockLock, testStagingApproveUpdate," \
       "testStagingApproveUpdateAtUnlock, testStagingCheckNow, testStagingWrongPinInPasswordChange," \
       "testStagingConnectAccept, testStagingConnectApprove, testStagingMessageSend, testStagingMessageReceive," \
       "testStagingPhotoSend, testStagingPhotoReceive, testStagingInvite, testStagingApproveRequest," \
       "testStagingRotate, testStagingSendAll, testStagingWaitMessage, testStagingTransferIn, testStagingTransferOut," \
       "testStagingLook or testStagingCheck" >&2
     usage ;;
esac

# The comparison of the safety codes is never skipped by accident: only the flag, only for the old phone's test, and
# never through an inputs file (an unknown name there is refused) or the environment.
if [[ -n "${VETTID_STAGING_TRANSFER_AUTO_MATCH:-}" || -n "${TEST_RUNNER_VETTID_STAGING_TRANSFER_AUTO_MATCH:-}" ]]; then
  echo "refusing: VETTID_STAGING_TRANSFER_AUTO_MATCH in the environment; use --auto-match" >&2
  exit 1
fi
if [[ ${AUTO_MATCH} -eq 1 && "${TEST}" != testStagingTransferOut ]]; then
  echo "refusing --auto-match: it is only for --test testStagingTransferOut" >&2
  exit 1
fi

# The inputs this test needs (the others are passed when set, and unused).
case "${TEST}" in
  testStagingEnroll) NEEDED=("${NAMES[@]}") ;;
  testStagingConnectAccept) NEEDED=(VETTID_STAGING_PIN VETTID_STAGING_PASSWORD VETTID_STAGING_LINK) ;;
  testStagingMessageSend)
    NEEDED=(VETTID_STAGING_PIN VETTID_STAGING_PASSWORD VETTID_STAGING_PEER_NAME VETTID_STAGING_MESSAGE) ;;
  testStagingMessageReceive|testStagingWaitMessage)
    NEEDED=(VETTID_STAGING_PIN VETTID_STAGING_PASSWORD VETTID_STAGING_PEER_NAME VETTID_STAGING_EXPECT) ;;
  testStagingApproveRequest) NEEDED=(VETTID_STAGING_PIN VETTID_STAGING_PASSWORD VETTID_STAGING_SAFETY_CODE) ;;
  testStagingSendAll)
    NEEDED=(VETTID_STAGING_PIN VETTID_STAGING_PASSWORD VETTID_STAGING_PEER_NAME VETTID_STAGING_MESSAGE VETTID_STAGING_EXPECT) ;;
  testStagingTransferIn) NEEDED=(VETTID_STAGING_PIN VETTID_STAGING_TRANSFER_CODE) ;;
  testStagingCheck) NEEDED=(VETTID_STAGING_PIN VETTID_STAGING_PASSWORD VETTID_STAGING_PEER_NAME) ;;
  testStagingPhotoSend|testStagingPhotoReceive)
    NEEDED=(VETTID_STAGING_PIN VETTID_STAGING_PASSWORD VETTID_STAGING_PEER_NAME) ;;
  *) NEEDED=(VETTID_STAGING_PIN VETTID_STAGING_PASSWORD) ;;
esac

# The inputs are kept in IN_<NAME>, unexported, and the variables of the same names leave the environment: nothing the
# build runs sees them.
for n in "${ALL[@]}"; do
  if [[ -z "${INPUTS}" ]]; then printf -v "IN_${n}" '%s' "${!n:-}"; else printf -v "IN_${n}" '%s' ""; fi
  unset "${n}"
done

# The private input file: outside the repository (so that it can never be committed), readable by its owner only.
if [[ -n "${INPUTS}" ]]; then
  [[ -f "${INPUTS}" ]] || { echo "no such input file: ${INPUTS}" >&2; exit 1; }
  file=$(cd "$(dirname "${INPUTS}")" && pwd -P)/$(basename "${INPUTS}")
  if [[ "${file}" == "${REPO}" || "${file}" == "${REPO}/"* ]]; then
    echo "refusing: the input file is inside the repository; keep it in a private place outside it" >&2
    exit 1
  fi
  if (( 8#$(stat -f %Lp "${file}") & 8#077 )); then
    echo "refusing: the input file is readable by others; chmod 600 it" >&2
    exit 1
  fi
  # NAME=value lines, read as data (never sourced); blank lines and # comments are ignored.
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line=${line%$'\r'}
    [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    name=${line%%=*}
    value=${line#*=}
    if [[ ${#value} -ge 2 && ( ( "${value:0:1}" == '"' && "${value: -1}" == '"' ) ||
      ( "${value:0:1}" == "'" && "${value: -1}" == "'" ) ) ]]; then
      value=${value:1:${#value}-2}
    fi
    known=0
    for n in "${ALL[@]}"; do [[ "${name}" == "${n}" ]] && known=1; done
    [[ ${known} -eq 1 ]] || { echo "unknown name in the input file: ${name}" >&2; exit 1; }
    printf -v "IN_${name}" '%s' "${value}"
  done <"${file}"
fi

missing=()
for n in "${NEEDED[@]}"; do v="IN_${n}"; [[ -n "${!v}" ]] || missing+=("${n}"); done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "note: not set: ${missing[*]} (a test without its inputs is skipped)"
fi

# --fresh deletes the app's vault keys: only for an enrollment that will run.
if [[ ${FRESH} -eq 1 ]]; then
  if [[ "${TEST}" != testStagingEnroll || ${#missing[@]} -gt 0 ]]; then
    echo "refusing --fresh: it is only for testStagingEnroll with all four inputs set" >&2
    exit 1
  fi
fi

CACHE="${XDG_CACHE_HOME:-${HOME}/Library/Caches}/vettid-ios/staging-ui-test"
mkdir -p "${CACHE}/results"
chmod 700 "${CACHE}" "${CACHE}/results"
DERIVED="${CACHE}/DerivedData"
DEST="platform=iOS,id=${DEVICE}"

if [[ ${AUTO_MATCH} -eq 1 ]]; then
  echo "WARNING: --auto-match: the safety code will NOT be compared; the old phone approves by itself" >&2
fi
if [[ ${SKIP_BUILD} -eq 0 ]]; then
  echo "== build-for-testing (Staging)"
  xcodebuild build-for-testing \
    -project VettID.xcodeproj -scheme VettIDStagingUITests -configuration Staging \
    -destination "${DEST}" -derivedDataPath "${DERIVED}" -allowProvisioningUpdates -quiet
fi

if [[ ${FRESH} -eq 1 ]]; then
  name=$(xcrun devicectl list devices 2>/dev/null | grep -F -- "${DEVICE}" | head -1 | sed -E 's/ {2,}.*//' || true)
  apps=$(xcrun devicectl device info apps --device "${DEVICE}" --bundle-id "${BUNDLE_ID}" 2>&1) || {
    echo "could not list the apps on the iPhone:" >&2
    echo "${apps}" >&2
    exit 1
  }
  if grep -qF -- "${BUNDLE_ID}" <<<"${apps}"; then
    echo "== removing ${BUNDLE_ID} (and its vault keys) from the iPhone \"${name:-unknown}\""
    if [[ -t 0 ]]; then
      read -r -p "Remove it? [y/N] " answer
      [[ "${answer}" == [yY] || "${answer}" == [yY][eE][sS] ]] || { echo "not removed; stopping"; exit 1; }
    fi
    out=$(xcrun devicectl device uninstall app --device "${DEVICE}" "${BUNDLE_ID}" 2>&1) || {
      echo "removing the app failed:" >&2
      echo "${out}" >&2
      exit 1
    }
  else
    echo "== ${BUNDLE_ID} is not installed on the iPhone \"${name:-unknown}\""
  fi
fi

# The runner's inputs, from here on and through the environment only.
for n in "${ALL[@]}"; do
  v="IN_${n}"
  if [[ -n "${!v}" ]]; then export "TEST_RUNNER_${n}=${!v}"; fi
done

if [[ ${AUTO_MATCH} -eq 1 ]]; then export TEST_RUNNER_VETTID_STAGING_TRANSFER_AUTO_MATCH=1; fi
RESULT="${CACHE}/results/${TEST}-$(date +%Y%m%d-%H%M%S).xcresult"
if [[ ${KEEP} -eq 0 ]]; then
  # The bundle holds what was typed: it goes however the run ends.
  trap 'rm -rf "${RESULT}"' EXIT
  trap 'exit 130' INT TERM
fi
echo "== ${TEST} on the iPhone"
set +e
xcodebuild test-without-building \
  -project VettID.xcodeproj -scheme VettIDStagingUITests -configuration Staging \
  -destination "${DEST}" -derivedDataPath "${DERIVED}" \
  -only-testing:"VettIDAppUITests/StagingTests/${TEST}" \
  -resultBundlePath "${RESULT}" 2>&1 |
  perl -pe '
    BEGIN {
      $| = 1;  # a line reaches the operator as it is printed (the transfer link is wanted at once)
      # Longest first, so that a value holding another (a message holding the name) goes whole.
      # A list of connections ("Name=label;Name=label") is redacted whole and name by name (not the labels).
      @s = sort { length($b) <=> length($a) } grep { length }
        map { my $v = $ENV{"TEST_RUNNER_$_"} // ""; ($v, ($_ eq "VETTID_STAGING_PEER_NAME" ? map { my $n = (split /=/, $_, 2)[0]; $n =~ s/^\s+|\s+$//g; $n } split(/;/, $v) : ())) }
        qw(VETTID_STAGING_EMAIL VETTID_STAGING_CODE VETTID_STAGING_PIN VETTID_STAGING_PASSWORD VETTID_STAGING_LINK
           VETTID_STAGING_TRANSFER_CODE VETTID_STAGING_PEER_NAME VETTID_STAGING_MESSAGE VETTID_STAGING_EXPECT)
    }
    # The connect, message and photo tests report lines: the code, the state or the answer alone, never anything else of the
    # line.
    if (/SAFETY_CODE: ([0-9]{6})\s*$/) { $_ = "SAFETY_CODE: $1\n"; next }
    if (/CONNECT_STATE: ([a-z_]+)\s*$/) { $_ = "CONNECT_STATE: $1\n"; next }
    if (/MESSAGE_STATE: (none|sent|delivered|read)\s*$/) { $_ = "MESSAGE_STATE: $1\n"; next }
    if (/MESSAGE_RECEIVED: (yes|no)\s*$/) { $_ = "MESSAGE_RECEIVED: $1\n"; next }
    if (/INVITE_LINK: (https:\/\/[A-Za-z0-9._~:\/?#\[\]@!\$\&()*+,;=%-]+|none)\s*$/) { $_ = "INVITE_LINK: $1\n"; next }
    if (/TRANSFER_LINK: (https:\/\/[A-Za-z0-9._~:\/?#\[\]@!\$\&()*+,;=%-]+|none)\s*$/) {
      # Printed alone; the link is remembered, so that any later line that shows it is redacted.
      my $l = $1; $_ = "TRANSFER_LINK: $l\n";
      if ($l ne "none") { push @s, $l; @s = sort { length($b) <=> length($a) } @s }
      next
    }
    if (/TRANSFER_STATE: ([a-z_]+)\s*$/) { $_ = "TRANSFER_STATE: $1\n"; next }
    if (/TRANSFER_AFTER: (kept|welcome_notice|welcome|none)\s*$/) { $_ = "TRANSFER_AFTER: $1\n"; next }
    if (/TRANSFER_SAS_UNCHECKED\s*$/) { $_ = "TRANSFER_SAS_UNCHECKED\n"; next }
    if (/TRANSFER_OPERATOR: compare the safety codes on both phones and tap on this iPhone\s*$/) {
      $_ = "TRANSFER_OPERATOR: compare the safety codes on both phones and tap on this iPhone\n"; next
    }
    if (/TRANSFER_SIGNER: shown\s*$/) { $_ = "TRANSFER_SIGNER: shown\n"; next }
    if (/ROTATE_STATE: (done|failed|none)\s*$/) { $_ = "ROTATE_STATE: $1\n"; next }
    if (/PHOTO_STATE: (none|sending|delivered|failed)\s*$/) { $_ = "PHOTO_STATE: $1\n"; next }
    if (/PHOTO_RECEIVED: (yes|no)\s*$/) { $_ = "PHOTO_RECEIVED: $1\n"; next }
    if (/PHOTO_VIEWER: (shown|failed|loading)\s*$/) { $_ = "PHOTO_VIEWER: $1\n"; next }
    for my $v (@s) { s/\Q$v\E/<redacted>/g }
    s/Type .*? into/Type <redacted> into/g;
    s/pin_[0-9]/pin_#/g;
  '
status=${PIPESTATUS[0]}
set -e

if [[ ${KEEP} -eq 1 ]]; then
  echo "result bundle (private; it holds what was typed): ${RESULT}"
fi
exit "${status}"
