# I4 audit: hardening and polish

Audit of the iPhone app for phase I4 of
[IOS-PLAN](https://github.com/vettid/vettid.org/blob/master/docs/IOS-PLAN.md) §8 ("VoiceOver and Dynamic Type pass
on every screen; offline and error states; an audit like vettid-android `docs/A6-AUDIT.md`; TestFlight external
testing of VettID Staging"). It follows the layout of vettid-android's
[A6 audit](https://github.com/vettid/vettid-android/blob/master/docs/A6-AUDIT.md), and every area ends with a table of
that audit's findings and whether the iPhone app has the same problem. This is an audit only: nothing in the app was
changed.

- **Audited commit:** `79c06ba` (master, 2026-10-29).
- **Method:** reading the code of every package under `Packages/`, the app target, `project.yml`, `Config/`,
  `scripts/` and the CI workflows; contrast ratios computed from the theme's colour tokens. Nothing was built or run
  on a phone, simulator, dev stack or staging, so nothing here was observed running.
- **What the vault, relay and member API do** is taken from VAULT-MESSAGING, RELAY-PROTOCOL and MEMBER-API, never
  from server code. Where a finding depends on that, it says "per spec".
- **App Store and TestFlight rules** (area 7) are stated from Apple's published guidelines, not from the repository:
  confirm each in App Store Connect before acting on it.
- **Paths** are repository-relative. Areas 1 and 3 state their shortened forms at their top; elsewhere a bare file
  name is unique in the repository, or the path is given in full.

## How to read the findings

**Severity**

| Severity | Meaning |
|---|---|
| **Blocker** | For the first members (owner plus up to ten testers): data loss, lock-out, a security or privacy leak, or a core flow that cannot be used with VoiceOver. Also, since I4's exit is a TestFlight build: anything that stops a build from being uploaded to TestFlight (G1, G2). |
| **Public** | Should be fixed before a public App Store listing. |
| **Polish** | Worth doing; nobody is harmed if it waits. |

**Status**

| Mark | Meaning |
|---|---|
| **V** | Verified in code: every step of the claim was read at the cited lines. |
| **C** | Computed (contrast ratios; the numbers are shown). |
| **S** | Suspected: the code path is read, but the visible effect needs a phone. Each area's "Needs a real iPhone" list says what to try. |
| **V/S** | The code is verified; how it behaves at run time is suspected. |

**Fix size:** S = under a day, M = a few days, L = a week or more.

## Counts

| Area | Blocker | Public | Polish |
|---|---|---|---|
| 1. Accessibility (A) | 0 | 16 | 11 |
| 2. Offline and poor network (N) | 1 | 3 | 5 |
| 3. Error states (E) | 0 | 5 | 9 |
| 4. Robustness (R) | 0 | 4 | 5 |
| 5. Client security hygiene (S) | 0 | 3 | 6 |
| 6. Performance and battery (P) | 0 | 1 | 6 |
| 7. App Store and TestFlight readiness (G) | 2 | 7 | 0 |
| 8. Tests (T) | 0 | 2 | 5 |
| **Total** | **3** | **41** | **47** |

No accessibility blocker was verified. A1 (nothing that changes by itself is spoken: a wrong PIN, the checks left, a
failure notice) and A2 (step changes are not announced) become blockers if one of the first testers uses VoiceOver.
S3 (the app lock's wall clock) and R3 are the same finding seen from two areas.

## Blockers

- **N1. A request that failed in transport can still be delivered later** (area 2). A failed deposit stays in the
  outbox and goes out at the next flush, while the member was told it failed. For a credential operation that the
  member retried successfully, the late copy carries the superseded credential, which the vault treats as a clone
  (VAULT-MESSAGING §3.5.3 step 3, `credential_frozen`). Messages, new items and approvals can be applied twice or
  after a reported failure. This is vettid-android's A6 N2, fixed there in vettid-android #185.
- **G1. The app has no icon** (area 7): no upload is accepted without one.
- **G2. No privacy manifest** (area 7) while required-reason APIs are used.

## Suggested order of work

1. N1 (the outbox), then G1 and G2 with G8 (the build number) so that a first TestFlight build can be uploaded.
2. A1 and A2 (announcements), then the other VoiceOver and Dynamic Type findings, screen by screen.
3. The error-state findings that show "nothing here" for a failed read (E1, E2) and the lost-work findings (R1, E5).
4. S1 and R3/S3, then the remaining Public findings; Polish last.

---

## 1. Accessibility

Audited commit `79c06ba`. Paths are shortened: `UI/X.swift` is `Packages/VettIDUI/Sources/VettIDUI/X.swift`;
`Onboarding/X.swift` is `Packages/VettIDOnboarding/Sources/VettIDOnboardingUI/X.swift` (the same for `Settings`,
`Items`, `Connections`, `Messages`, `Approvals`, `History`, `Notifications`, with their `…UI` target); `Shell/X.swift`
is `Packages/VettIDShell/Sources/VettIDShellUI/X.swift`; `App/X.swift` is in the app target. A path into a package's
logic target names it in full.

**What the plan requires.** IOS-PLAN ID5: VoiceOver labels are required. IOS-PLAN §3: Dynamic Type up to the
accessibility sizes. IOS-PLAN §8 I0.2: "Dynamic Type at the largest size does not clip"; I3.1: typing, the keyboard and
VoiceOver work inside the secure container; I4: a VoiceOver and Dynamic Type pass on every screen. IOS-PLAN §4.12 (the
approvals indicator): `updatesFrequently` while urgent, a 44 pt target, announcements at 2 minutes and 1 minute.
ANDROID-PLAN §4 for the typed recovery code: the count and every refusal are announced, the layout holds at the
largest text size.

**What the code does.** The groundwork is good and in places better than Android's: every icon-only control goes
through `IconButton`, which requires a label and has a 48 pt target; decorative images are hidden; titles carry the
header trait; settings rows, list rows and notification rows are single elements; notification rows expose archive,
read, move back and delete as VoiceOver actions; the drawer is modal, answers the escape gesture and moves VoiceOver in
and out; the in-app PIN keypad reads its keys by digit and the dots as "N entered"; the safety code is read digit by
digit; the app lock and the owner-check overlay hide what is under them from VoiceOver. The gaps are of four kinds:
**nothing that changes by itself is ever spoken** (the code uses the `updatesFrequently` trait as if it were Android's
live region; it is not), step changes inside a flow are silent, several text-entry and chip components ignore
Dynamic Type, Bold Text or the 44 pt minimum, and the theme's `outline` is too faint for the boundaries it draws.

No accessibility blocker was verified. A1 and A2 become blockers if one of the first testers uses VoiceOver: the
unlock, the owner check and the transfer can be completed, but every failure and every step change is silent.

### Public

### A1. The result of an attempt is never announced: wrong PIN, wrong password, checks left, backoff, failure notices

- **Severity:** Public (a Blocker for a tester who uses VoiceOver). **Status:** V/S. **Size:** M.
- **Where:** the app posts an announcement in four places only: `Items/Screens/TagSheet.swift:41`,
  `Onboarding/Screens/VaultDeletingScreen.swift:119-120`, `Onboarding/Screens/RecoverScreen.swift:297`,
  `UI/Components/QrScanner.swift:229`. Everywhere else a changing text is marked `.accessibilityAddTraits(.updatesFrequently)`
  or nothing: `UI/Secure/SecretField.swift:75` (every password error); `Onboarding/Screens/OnboardingParts.swift:156-162`
  (the PIN error under every keypad, no trait); `Onboarding/Screens/UnlockScreen.swift:169-182` (wrong PIN, the wait),
  `:308-323` (the comment says "each is announced to VoiceOver when it does", the code adds `updatesFrequently`),
  `:381-409`; `Onboarding/Screens/OwnerCheckScreen.swift:222-247,259-277,293-316,331` (wrong PIN, wrong password,
  "N checks left", backoff, "may have counted"); `Approvals/Screens/ApprovalDetailScreen.swift:161-167` (a failed
  decision); `Onboarding/Screens/RecoverParts.swift:10-26,82-95`; `Onboarding/Screens/RecoveryOpenScreen.swift:335,370`;
  `UI/Components/Forms.swift:138-174` (`NoticeCard`, used for every failure notice, announces nothing).
- **What happens:** `updatesFrequently` only tells VoiceOver to poll an element *while it has focus*; it posts nothing
  for an element elsewhere on the screen. After "Unlock" the keypad buffer is taken (`UnlockScreen.swift:88-92`), so
  the Unlock button turns disabled under the VoiceOver cursor and the error appears below the keypad: the member hears
  nothing and finds an empty keypad. In the owner check each silent failure spends one of the ten checks before the
  vault locks (VAULT-MESSAGING §3.6.5).
- **Why it matters:** the two flows every member goes through daily give no audible result.
- **Suggested fix:** one helper in VettIDUI (`announce(_:)` posting `AccessibilityNotification.Announcement`, with
  `.accessibilitySpeechAnnouncementPriority(.high)` for failures) called from `onChange` of the state that carries the
  failure; use it in `SecretField`, `PinEntry` and a `live:` flag on `NoticeCard`. Never on a ticking countdown (A5).
  Remove `updatesFrequently` from texts that are not counters.

### A2. Step changes inside a flow, and layers that appear by themselves, are not announced

- **Severity:** Public. **Status:** V/S. **Size:** S.
- **Where:** flows swap a whole `FormScaffold` per step with a `switch`: `Onboarding/OnboardingFlow.swift:156-214`,
  `Onboarding/Screens/TransferInScreen.swift:48-152`, `Onboarding/Screens/RecoverScreen.swift:122-218`,
  `Onboarding/Screens/ReleaseUpdateFlowScreen.swift`, `Settings/Screens/TransferOutScreen.swift:106-242`,
  `Approvals/Screens/ApprovalDetailScreen.swift:72-128` (the decision turns into "gone" when it expires). The only
  `.screenChanged` post in the app is the drawer's (`UI/Components/DrawerContainer.swift:59-61`). The owner-check overlay
  slides in with `.isModal` but no post (`Shell/AppShell.swift:237-246`); the app-lock window is made key with no post
  (`App/AppLockGate.swift:118-125`). The scaffold's title has the header trait only (`UI/Components/Forms.swift:410-414`).
- **What happens:** several swaps are caused by the other phone (the safety code appears on "Waiting for your new
  phone"; the connect flow's code). VoiceOver's cursor stays on a removed element or jumps without saying where it is.
  Pushes through the shell's `NavigationStack` are fine: UIKit announces those.
- **Suggested fix:** post `.screenChanged` (argument: the title) from `FormScaffold` when its title changes and from
  the overlay and the lock window when they appear; `AccessibilityFocusState` on the title as the alternative.

### A3. Enrolment and release-update progress is silent

- **Severity:** Public. **Status:** V. **Size:** S.
- **Where:** `UI/Components/Forms.swift:292-321`: each `StepList` row is one element "label: state", nothing is
  announced when a state changes; used at `Onboarding/Screens/VaultScreens.swift:342` and
  `Onboarding/Screens/ReleaseUpdateFlowScreen.swift:167`. A failure shows `ErrorNotice` (`OnboardingParts.swift:10-25`),
  also silent.
- **What happens:** a VoiceOver member hears nothing while the vault is created (80 s or more on a cold host) and
  nothing when it fails.
- **Suggested fix:** announce the step that became active and any failure (A1's helper).

### A4. Typed recovery code: the count and the refusals are not announced, and the grid goes ragged at large sizes

- **Severity:** Public. **Status:** V (announcements); V/S (wrap). **Size:** S–M.
- **Where:** `Onboarding/Screens/RecoverScreen.swift:180-186` (the "N of 12 groups" count, `updatesFrequently`),
  `:221-232` (`TypedProblemText`: "announced at once" in its comment, `updatesFrequently` in code),
  `Onboarding/Screens/RecoverParts.swift:10-26` (code refusal), `:30-46` (`ClaimFailure`, no trait). The editor uses
  the body text style scaled with Dynamic Type (`UI/Secure/SecretTextEditor.swift:107-108`) and the text has a hard
  line break after every fourth group (`RecoverParts.swift:101-116`).
- **What happens:** ANDROID-PLAN §4's "the count and every refusal are announced" does not hold on iOS: focus is in
  the editor, so none of these is spoken. From the larger sizes a row of four groups (19 characters) no longer fits and
  soft-wraps into 3 + 1, so the grid stops matching the account site.
- **Suggested fix:** announce the count when a group completes and each refusal (with its group) as it appears; scale
  the group font down or let the row wrap by whole groups at accessibility sizes.

### A5. Timed windows: the time left is never announced, is spoken as a clock time, and the transfer wait re-reads every second while focused

- **Severity:** Public. **Status:** V/S. **Size:** S–M.
- **Where:** transfer out: `Settings/Screens/TransferOutScreen.swift:237` ("expires in m:ss"), `:287-296` (`Window`,
  "m:ss left to approve"), window 600 s at `Packages/VettIDSettings/Sources/VettIDSettings/TransferOutViewModel.swift:119`;
  transfer in: `Onboarding/Screens/TransferInScreen.swift:152` puts "Waiting for your old phone (m:ss left)" in a
  `WaitingRow` with `updatesFrequently` (`Onboarding/Screens/MoveParts.swift:35-49`); every wait is formatted
  `%d:%02d` (`Packages/VettIDOnboarding/Sources/VettIDOnboarding/UnlockState.swift:154-156`).
- **What happens:** inside the 10 minutes the member compares a code, reads a notice, types PIN and password; no
  warning is spoken before it runs out. "4:59" is read as a time of day. If VoiceOver rests on the transfer-in wait (the
  row right under the safety code), the polled text changes every second and is likely re-read, on the screen where six
  digits must be heard.
- **Suggested fix:** keep the countdown text out of the waiting row; a separate label with "4 minutes 59 seconds" as
  its accessibility label (`DateComponentsFormatter`, `.full`), without `updatesFrequently`; announce at 2 minutes and
  30 seconds (as IOS-PLAN §4.12 already asks for approvals).

### A6. Return and "Next" do nothing on the first of two fields

- **Severity:** Public. **Status:** V/S. **Size:** S.
- **Where:** `UI/Secure/SecretField.swift:171-174` calls `onSubmit`, which defaults to nothing (`:50`). Without one:
  the new password (`Onboarding/Screens/VaultScreens.swift:128`), the current and new passwords
  (`Settings/Screens/ChangePasswordScreen.swift:66-75`, `Settings/Screens/NewCredentialScreen.swift:72-77`). The first
  name declares `.submitLabel(.next)` and passes no action (`Settings/Screens/ChangeNameScreens.swift:121-124,160-161`).
- **What happens:** password → confirmation: Return (or Enter on a hardware keyboard) leaves the cursor where it is; on
  the first name the keyboard shows "Next" and it only closes the keyboard.
- **Suggested fix:** a `next:` action that moves focus (`SecretFocus` already exists), and `returnKeyType = .next` there.

### A7. The one-time code is read as two numbers and its time left as "12 s"

- **Severity:** Public. **Status:** V. **Size:** S.
- **Where:** `Items/Screens/ItemDetailParts.swift:120-137` shows `grouped(code)` ("123 456") with no accessibility
  label; `items_otp_left` is "%lld s" (`Packages/VettIDItems/Sources/VettIDItems/Support/ItemsStrings+2.swift:209-211`).
  A "Copy code" button exists (`:132-135`), unlike Android's.
- **What happens:** "one hundred twenty-three, four hundred fifty-six, twelve s"; with 30 s to read and type it.
- **Suggested fix:** the digits spaced in the accessibility label, as `SafetyCode` does; "12 seconds left".

### A8. Security values are cut at two lines and cannot be selected

- **Severity:** Public. **Status:** V/S. **Size:** S.
- **Where:** `UI/Components/Settings.swift:225-240`: below the accessibility sizes a `SettingsInfoRow`'s value has
  `lineLimit(2)`. Affected: the release fingerprint (`Settings/Screens/AttestationScreen.swift:78,90`), the boot key
  fingerprint (`:152`), the vault id (`Settings/Screens/VaultStatusScreen.swift:67`), the email and membership lines of
  the account sheet (`Shell/AccountSheet.swift:109,144-160`).
- **What happens:** "Release N · <64 hex>" needs about three lines at the default size in a row about 280 pt wide; the
  fingerprint a member would compare ends in "…". VoiceOver reads the whole value (the label is not truncated), sighted
  members do not see it.
- **Suggested fix:** no line limit on info rows; fingerprints monospaced, grouped and selectable.

### A9. Saving an item with invalid fields gives no feedback where the member is

- **Severity:** Public. **Status:** V/S. **Size:** M.
- **Where:** `Packages/VettIDItems/Sources/VettIDItems/ItemEditViewModel+Save.swift:11-14` only sets `showErrors`;
  "Save item" is in the top bar (`Items/Screens/ItemEditScreen.swift:187`); the problems are field texts and a card at
  the end of a long form (`:233-238`).
- **What happens:** "Save item" appears to do nothing, with VoiceOver and for sighted members at large sizes.
- **Suggested fix:** scroll to and focus the first invalid field (`ScrollViewReader`, `AccessibilityFocusState`);
  announce the number of problems.

### A10. A new incoming message is not announced in an open conversation

- **Severity:** Public. **Status:** V. **Size:** S.
- **Where:** `Messages/Screens/ConversationParts.swift:35-41`: a new last message only scrolls the list. (The send
  button keeps its "Send" label while sending, `Messages/Screens/ConversationScreen.swift:195`: Android's second half of
  this finding is not here.)
- **Suggested fix:** announce "<name>: <text>" for a new incoming message while the conversation is open (not for the
  member's own, not for a page of older ones).

### A11. Masked values are read as bullets; label and value are separate stops

- **Severity:** Public. **Status:** V. **Size:** S.
- **Where:** `items_masked_value` is "••••••••" (`Packages/VettIDItems/Sources/VettIDItems/Support/ItemsStrings+2.swift:141`),
  shown with no accessibility label at `Items/Screens/ItemDetailParts.swift:73-78,104-109`; the row is a container
  (`:100`), so the label and the value are two elements.
- **What happens:** "bullet bullet …" for every hidden password; two swipes per field.
- **Suggested fix:** "Hidden" as the masked value's label; combine label and value into one element and keep the
  show and copy buttons as its own elements or as custom actions.

### A12. Two sheets cannot grow or scroll, so their options are cut at large sizes

- **Severity:** Public. **Status:** V/S. **Size:** S.
- **Where:** "Add a connection" (`Connections/Screens/AddConnection.swift:33,66-80`): three options in a plain `VStack`,
  detent `.medium` only. "Protection" (`Items/Screens/ItemDetailParts.swift:176-179,190-206`): three choices with
  descriptions and Cancel, `.medium` only, no scroll. (Confirmations are system alerts, which scroll: Android's dialog
  half of this finding is not here. The other sheets scroll or offer `.large`.)
- **What happens:** from the larger accessibility sizes the third option, or Cancel, is below the sheet's edge and
  cannot be reached by scrolling.
- **Suggested fix:** a `ScrollView` and `[.medium, .large]` on both.

### A13. Secret and code fields do not follow Dynamic Type

- **Severity:** Public. **Status:** V. **Size:** S.
- **Where:** `UI/Secure/SecretField.swift:188-205`: the `UITextField` behind `SecretField` and `VisibleSecretField`
  gets a scaled font only when `monospaced` (`:195-199`); otherwise it keeps UIKit's fixed default (17 pt, no
  `adjustsFontForContentSizeCategory`). Every credential password (23 `SecretField` sites) and the visible secret fields
  (item values of secret items, `Items/Screens/ItemFieldEditors.swift:168,256,400`; the setup and transfer codes;
  `Settings/Screens/DeleteVaultScreen.swift:108`) are affected, including the placeholder, which is the field's label.
- **What happens:** at the largest sizes every label around the field grows and the text in it stays small.
- **Suggested fix:** `UIFontMetrics(forTextStyle: .body).scaledFont(for: <Inter body>)` and
  `adjustsFontForContentSizeCategory = true` for every field.

### A14. Bold Text is ignored by almost all text

- **Severity:** Public. **Status:** V/S. **Size:** S.
- **Where:** `UI/Theme/Typography.swift:84-92`: every `vettIDFont` is `Font.custom` with the PostScript name of a fixed
  weight instance; nothing reads `legibilityWeight` (no use in the repository).
- **What happens:** SwiftUI makes system fonts heavier for Bold Text but not a custom font named by a weight instance,
  so the setting changes almost nothing in the app.
- **Suggested fix:** read `@Environment(\.legibilityWeight)` in `VettIDTextStyleModifier` and step each weight up one
  instance when it is `.bold`.

### A15. Touch targets under 44 pt: filter chips, removable tags, and text buttons whose frame is not their target

- **Severity:** Public. **Status:** V (chips); V/S (text buttons). **Size:** S.
- **Where:** chips with a 32 pt minimum height and nothing larger to hit: `UI/Components/Chips.swift:117`
  (`RemovableTagChip`, the item editor's tags), `:149` (`VettIDFilterChip`, also the month picker,
  `Items/Screens/ItemFieldEditors.swift:343`), `:176` (`ClearFiltersChip`); `Items/Screens/ItemsScreen.swift:207`
  (category and tag menus); `History/Screens/HistoryFilterRow.swift:91,123`. Text buttons with
  `.buttonStyle(.plain)` and `.frame(minHeight: Spacing.touchTarget)` applied outside the label, without a
  `contentShape`, so the hit area stays the text: `Onboarding/Screens/OnboardingParts.swift:64` (`TextLink`: "Type the
  code instead", "Allow the camera", the unlock notices' actions), `Approvals/Screens/ApprovalsScreen.swift:206`
  (`NoticeAction`), `Onboarding/Screens/UnlockScreen.swift:364`, `Onboarding/Screens/UnlockParts.swift:100`,
  `Onboarding/Screens/WhatsNew.swift:50`, `Messages/Screens/ConversationParts.swift:155`,
  `Messages/Screens/MessagesScreen.swift:148`, `Messages/Screens/NewMessageScreen.swift:48`,
  `Connections/Screens/ConnectionsListParts.swift:43`, `Approvals/Screens/ApprovalFacts.swift:329`,
  `Settings/Screens/ProfileItemsCard.swift:30`, `Settings/Screens/ChoiceSheet.swift:121`.
- **What happens:** about 32 pt (chips) or about 22 pt (text buttons) of height to hit at the default size. VoiceOver
  is not affected; members with tremor and Switch Control point-mode users are.
- **Suggested fix:** move the `frame` and a `contentShape(Rectangle())` inside the label; give the chips a 44 pt
  content shape around their 32 pt pill.

### A16. The theme's `outline` is far below 3:1, and it is the only boundary of every text field

- **Severity:** Public. **Status:** C. **Size:** S.
- **Where:** computed below ([Contrast](#contrast-ios)). `outline` on `background`: 1.81 (dark), 1.41 (light). It
  strokes every text field (`UI/Secure/SecretField.swift:73,128`, `UI/Secure/SecretTextEditor.swift:56`,
  `Onboarding/Screens/OnboardingParts.swift:120`, the composer `Messages/Screens/ConversationScreen.swift:169`, the
  name and profile fields), the secondary button (`UI/Components/Forms.swift:60`), unselected filter chips
  (`UI/Components/Chips.swift:151,177`), the empty PIN dots (`UI/Secure/PinKeypad.swift:78`) and the safety-code box.
  The fields have no fill, so the stroke is all there is.
- **What happens:** an empty, unfocused field is barely visible, worst in light (1.41). The switches are not affected
  (iOS draws `Toggle` itself), unlike Android's.
- **Suggested fix:** an `outline` of at least 3:1 (InkBody in dark: 7.86; InkMuteLight in light: 8.46, or a lighter
  grey that clears 3:1) and keep the faint one as `outlineVariant` for decorative hairlines; extend `ThemeTests`.

### Polish

### A17. Two text pairs are slightly under 4.5:1

- **Severity:** Polish. **Status:** C. **Size:** S.
- **Where:** the time under an incoming bubble, `onSurfaceVariant` at 80 % on `surfaceContainerHigh`, 11 pt:
  4.04 (dark), 4.24 (light) (`UI/Components/Conversation.swift:53,60,64`). `TagLabel` in light over the grouped
  background: 4.14 (`UI/Components/Badges.swift:35-40`); today it is drawn only on cards (4.52).
- **Suggested fix:** drop the alpha.

### A18. State shown by colour or weight only

- **Severity:** Polish. **Status:** V. **Size:** S.
- **Where:** an approval that needs a decision is bold only (`Approvals/Screens/ApprovalsScreen.swift:120`,
  `UI/Components/Rows.swift:66-67`); `NoticeCard`'s kind (info, success, warning, urgent) is an icon and a colour, the
  icon hidden from VoiceOver (`UI/Components/Forms.swift:153-160`); the password strength bar's colour is spoken through
  its label, fine.
- **Suggested fix:** "Needs your decision" in the row's accessibility value; the kind as a word before the title
  ("Warning: …") in the card's label.

### A19. Repeated, context-free button labels

- **Severity:** Polish. **Status:** V. **Size:** S.
- **Where:** "Cancel invitation" on every pending invitation (`Connections/Screens/ConnectionsListParts.swift:98`);
  "Resume requests" and "Remove" on every paused connection (`Approvals/Screens/ApprovalsScreen.swift:179-183`).
- **Suggested fix:** name the invitation or the connection in the label.

### A20. Section titles without the header trait; two checkbox conventions

- **Severity:** Polish. **Status:** V. **Size:** S.
- **Where:** no `.isHeader`: `Items/Screens/ItemEditScreen.swift:221` (Fields), `Items/Screens/ItemEditSections.swift:133,162`
  (Protection, Tags), `Items/Screens/RuleEditParts.swift:262,293`, `History/Screens/HistoryExportScreen.swift:172`,
  `Onboarding/Screens/WhatsNew.swift:90`. The backup acknowledgement is a button with `.isSelected`
  (`Onboarding/Screens/VaultScreens.swift:269-287`), the delete acknowledgement a toggle with value "1"/"0"
  (`Settings/Screens/DeleteVaultScreen.swift:136-137`). The month picker's year change is silent
  (`Items/Screens/ItemFieldEditors.swift:335-338`).
- **Suggested fix:** the header trait; one checkbox component with `.isToggle`.

### A21. Confirmations that are not spoken, or gone too soon

- **Severity:** Polish. **Status:** V. **Size:** S.
- **Where:** "Copied" swaps the button's text (`Settings/Screens/TransferOutScreen.swift:262-270`,
  `Connections/Screens/InviteScreen.swift:204-205`); an item value copy has no confirmation at all
  (`Items/Screens/ItemDetailScreen.swift:28`); the archive's Undo toast lasts 4 s, is not announced and is not
  lengthened while VoiceOver runs (`Notifications/Screens/NotificationsScreen.swift:80,98-102`).
- **Suggested fix:** announce "Copied"; keep the Undo toast until dismissed while VoiceOver or Switch Control runs.

### A22. Truncation and layouts that do not adapt at the largest sizes

- **Severity:** Polish. **Status:** V/S. **Size:** S.
- **Where:** list rows show one line of title and one of preview at every size (`UI/Components/Rows.swift:76,91`),
  which cuts item names and approval summaries; the drawer screens' title is one line and the top bar is capped at
  `xxxLarge` without the Large Content Viewer (`UI/Components/TopBars.swift:117-122,141`), so "Notifications" can read
  "Notifica…" beside three buttons; earlier releases' notes are one line (`Onboarding/Screens/WhatsNew.swift:94`); up to
  eight banners stack above the content without a bound or a scroll (`Shell/AppShell.swift:208-217`,
  `Shell/MoveNotices.swift:35-62`); icons use fixed `.system(size:)` and do not scale (rows, notices, buttons). The
  notification rows are not affected: the detail sheet shows the full text (Android's half of that is not here).
- **Suggested fix:** two lines in rows at accessibility sizes; `accessibilityShowsLargeContentViewer()` on capped
  top-bar items; banners in a bounded, scrolling area.

### A23. Reduce Motion, Smart Invert and Increase Contrast are not handled

- **Severity:** Polish. **Status:** V. **Size:** S.
- **Where:** no read of `accessibilityReduceMotion`, `colorSchemeContrast` or `accessibilityIgnoresInvertColors`
  anywhere. The drawer slides (`UI/Components/DrawerContainer.swift:50-53`), the owner-check overlay slides up
  (`Shell/AppShell.swift:242-246`), a new message scrolls with animation (`Messages/Screens/ConversationParts.swift:37`);
  QR codes, profile photos and message photos are inverted by Smart Invert.
- **Suggested fix:** a cross-fade instead of the slides when Reduce Motion is on; `accessibilityIgnoresInvertColors()`
  on `QrCode`, `InitialTile`'s photo and the photo views; a higher-contrast `outline` under Increase Contrast.

### A24. A photo bubble's value is the hard-coded English word "shown"

- **Severity:** Polish. **Status:** V. **Size:** S.
- **Where:** `Messages/Screens/PhotoParts.swift:219` (`.accessibilityValue(thumb == nil ? "" : "shown")`).
- **What happens:** VoiceOver says "shown" after the photo's label, in every language.
- **Suggested fix:** drop it (use an identifier for tests) or a localised string.

### A25. A connection row is three or four stops and is not called a button

- **Severity:** Polish. **Status:** V/S. **Size:** S.
- **Where:** `UI/Components/Rows.swift:113-116`: a row with a trailing action (the favourite star, every connection
  row, `ConnectionRow`) is a container; its title, date and preview are separate elements and the row opens on a tap
  gesture, without the button trait.
- **Suggested fix:** combine the texts into one button element and offer the star as a custom action.

### A26. The capture shield and the app-lock window: what VoiceOver can reach while they show

- **Severity:** Polish. **Status:** S. **Size:** S.
- **Where:** `UI/Secure/PrivacyShield.swift:62-104`: while the screen is recorded or mirrored, the capture text is shown
  in a window at `.alert + 1` above the app, but the app's views underneath are not hidden from accessibility (the app
  lock hides them, `App/AppLockGate.swift:27-30`; the shield does not). The cover shown while inactive is itself hidden
  from VoiceOver (`:13`), which is right.
- **What happens:** VoiceOver may still move to and speak vault content under the "hidden while recording" text.
- **Suggested fix:** make the shield's window modal for accessibility (`accessibilityViewIsModal` on its root view) or
  post `.screenChanged` to its text when it appears; check on a phone.

### A27. Content on the secure layer: VoiceOver order and focus need a phone check

- **Severity:** Polish. **Status:** S. **Size:** S.
- **Where:** `UI/Secure/SecureContainer.swift:53-91` hosts content in a separate `UIHostingController` on a text
  field's canvas: the item values and editor, the safety codes, the transfer and invitation codes, the typed recovery
  code, approval data. The staging UI test reads the safety code's label from that layer
  (`AppUITests/StagingTests+Connect.swift:185-197`), so it is in the accessibility tree; the identifier set on the
  container is not, and the order relative to the rest of the screen and the focus after a change are not checked.
- **Suggested fix:** walk each protected screen with VoiceOver (checklist below) and add the result to I3.1's check.

### Contrast (iOS)

Ratios computed with the WCAG 2 formula from `UI/Theme/Palette.swift` and `UI/Theme/VettIDColors.swift`. The iPhone's
palette and role mapping are Android's, colour for colour, so the first table equals Android's. Bold: under the minimum
for the use (4.5 text, 3.0 large text, icons and control boundaries).

| Foreground on → | background | surfaceContainerLow | surfaceContainer / card (dark) | surfaceContainerHigh | grouped |
|---|---|---|---|---|---|
| **Dark** onSurface | 16.88 | 15.53 | 13.47 | 11.58 | 15.53 |
| onSurfaceVariant | 7.86 | 7.23 | 6.27 | 5.39 | 7.23 |
| primary (gold) | 11.10 | 10.21 | 8.85 | 7.61 | 10.21 |
| error | 6.51 | 5.98 | 5.19 | **4.46** | 5.98 |
| success | 9.84 | 9.05 | 7.85 | 6.75 | 9.05 |
| warning | 9.87 | 9.08 | 7.87 | 6.77 | 9.08 |
| outline | **1.81** | **1.67** | **1.45** | **1.24** | **1.67** |
| **Light** onSurface | 18.93 | 17.70 | 17.23 | 15.25 | 17.23 |
| onSurfaceVariant | 8.46 | 7.91 | 7.70 | 6.82 | 7.70 |
| primary (gold ink) | 5.63 | 5.27 | 5.13 | 4.54 | 5.13 |
| error | 6.54 | 6.11 | 5.95 | 5.27 | 5.95 |
| success | 5.35 | 5.00 | 4.87 | **4.31** | 4.87 |
| warning | 5.93 | 5.54 | 5.40 | 4.77 | 5.40 |
| outline | **1.41** | **1.31** | **1.28** | **1.13** | **1.28** |

In light the card is white, so its column equals `background`.

| Other pairs (iOS components) | Dark | Light |
|---|---|---|
| Gold button and own bubble (onPrimaryContainer on primaryContainer) | 11.63 | 11.63 |
| Urgent banner, destructive button (onError on error) | 6.82 | 6.54 |
| Info banner: text / warning icon / gold action / close (on surfaceContainerHigh) | 11.58 / 6.77 / 7.61 / 5.39 | 15.25 / 4.77 / 4.54 / 6.82 |
| Notice card: message / icons info, success, warning, urgent (on surfaceContainer) | 6.27 / 8.85, 7.85, 7.87, 5.19 | 7.70 / 5.13, 4.87, 5.40, 5.95 |
| Safety code and one-time code (primary on background) | 11.10 | 5.63 |
| Time under an own bubble (80 %) | 7.56 | 7.56 |
| Time under an incoming bubble (80 %) | **4.04** | **4.24** |
| `TagLabel` on card / grouped | 6.21 / 7.19 | 4.52 / **4.14** |
| Selected filter chip (onSecondaryContainer on secondaryContainer) | 13.47 | 17.23 |
| Drawer label, unselected (87 %) | 11.94 | 12.60 |
| Empty PIN dot outline (outline on background) | **1.81** | **1.41** |
| PIN key disc against the screen (surfaceContainerHigh on background; the digit inside is 11.58 / 15.25) | 1.46 | 1.24 |
| Strength bar, empty segment against the screen | 1.46 | 1.24 |
| Disabled button label (38 % on 12 %), exempt | 3.13 | 2.39 |
| Send button disabled (gold at 38 % against the screen), exempt | 2.59 | 1.22 |
| Gold fill against the screen (button, own bubble edge) | 11.10 | 1.63 (the label inside is 11.63) |

The failing cells of the first table other than `outline` (dark `error`, light `success` on `surfaceContainerHigh`)
are pairs no screen uses today. The PIN key discs and empty strength segments are under 3:1 but carry no information
the digit or the strength label does not.

**What `ThemeTests` covers** (`Packages/VettIDUI/Tests/VettIDUITests/ThemeTests.swift:24-48`): the same pairs as
Android's `ContrastTest`. **What it does not cover:** `outline` and every boundary; `success` and `warning`; `error`
on cards and containers; `onError`/`error`; any colour drawn with an alpha (bubble times, `TagLabel`, disabled states).

### Checked and sound

- **Labels:** every icon-only control goes through `IconButton`, whose initialiser requires a label (`UI/Components/TopBars.swift:51-75`);
  the bell says the unread count and urgency; the avatar says "Account, <name>"; the FAB, the floating chip (with its
  on/off value) and the pill bar are labelled; decorative icons, tiles and logos are hidden (`InitialTile`, `EmptyState`,
  `RookLogo(decorative:)`); QR codes are one image element with a label (`UI/Components/QrCode.swift:38-40`).
- **PIN keypad** (`UI/Secure/PinKeypad.swift`): no keyboard, so nothing autofills or learns; keys read their digit, delete
  is labelled, the dots read "N entered", keys are 72 pt. As on Apple's own passcode pad, VoiceOver speaks a digit when
  it is touched.
- **Safety code:** read digit by digit (`UI/Components/Conversation.swift:154-155`), 40 pt, fits two groups on the
  narrowest phone.
- **QR scanning alternatives:** every scan step has a type-or-paste action (setup, transfer in, recovery, connect), the
  denied and no-camera states say so, and the no-camera note is announced (`UI/Components/QrScanner.swift:229`).
- **Drawer and modal layers:** the drawer hides the content from VoiceOver, is modal, closes with the escape gesture and
  moves VoiceOver in and out (`UI/Components/DrawerContainer.swift:27-61`); the owner-check overlay and the app lock hide
  what is under them (`Shell/AppShell.swift:233-241`, `App/AppLockGate.swift:26-30`); the app-switcher cover is hidden
  from VoiceOver.
- **Rows:** settings, list and notification rows are single elements; notification rows expose archive, read, move back
  and delete as named actions (`Notifications/Screens/FeedRows.swift:83-86,150-167`); message bubbles read as one item
  with the delete and each link as actions (`UI/Components/Conversation.swift:69-96`).
- **Dynamic Type in the components:** the whole type scale is `relativeTo` a text style; settings rows lift their line
  limit at accessibility sizes; the info and urgent banners stack their action under the text there
  (`UI/Components/Forms.swift:200-202,258-259`); every `FormScaffold` scrolls; the drawer rows have a minimum, not a
  fixed, height.
- **Timeouts:** apart from the transfers (A5) and the approvals' own expiry (per spec), nothing times out under the
  member: revealed values have no auto-hide timer.
- **Colour alone:** strength, history categories, tag chips and notification priority all carry words; the exceptions
  are A18.

### Android A6 area 1 on the iPhone

| Android finding | iOS | Note |
|---|---|---|
| A1 results never announced | same | A1; wider on iOS: `updatesFrequently` is used as if it were a live region. |
| A2 transfer-in wait re-announced every second | partly | A5: `updatesFrequently` re-reads it only while focused (`Onboarding/Screens/MoveParts.swift:47`), but it sits right under the safety code. |
| A3 step changes not announced | same | A2; also the owner-check overlay and the app-lock window. |
| A4 backoff hidden by "wrong PIN" | not here | Both lines show: `Onboarding/Screens/UnlockScreen.swift:169-182`, `OwnerCheckScreen.swift:261-266,300-303`. |
| A5 keyboard "Next" does nothing | same | A6. |
| A6 progress silent | same | A3. |
| A7 one-time code as two numbers, no copy, "12 s" | same, in part | A7; a "Copy code" button exists (`Items/Screens/ItemDetailParts.swift:132-135`). |
| A8 security values cut at two lines | same | A8. |
| A9 unlabelled switch in the rule editor | not here | Labelled: `Items/Screens/RuleEditParts.swift:241-244`. |
| A10 invalid save gives no feedback | same | A9. |
| A11 10-minute transfer window, time left never announced | same | A5. |
| A12 new message not announced; send button loses its label | same, in part | A10; the send button keeps "Send" (`Messages/Screens/ConversationScreen.swift:195`). |
| A13 masked values read as bullets | same | A11. |
| A14 dialog and sheet bodies do not scroll | partly | A12 (two sheets); confirmations are system alerts, which scroll. |
| A15 fixed heights at 200 % | partly | A22 (top bar title); drawer rows use a minimum height (`UI/Components/Drawer.swift:95`); the safety code fits. |
| A16 typed code: a refusal not announced, grid ragged | same, worse | A4: neither the count nor any refusal is announced. |
| A17 app-lock layer swallows key events | not here (S) | The lock is a key window with a normal button (`App/AppLockGate.swift:118-125`); check Full Keyboard Access. |
| A18 `outline` under 3:1 | same, in part | A16 (text fields, chips, PIN dots); switches are the system's on iOS. |
| A19 two text pairs under 4.5:1 | same | A17 (4.04/4.24; 4.14). |
| A20 repeated context-free labels | same | A19. |
| A21 section titles without heading; radio groups | same, in part | A20; SwiftUI has no radio-group role to miss. |
| A22 fields with a weak name | partly | Fields are labelled (`Settings/Screens/SharedProfileScreen.swift:125`, `ChangeNameScreens.swift:166`); the month picker's year change is silent (A20). |
| A23 confirmations not announced or too short | same | A21. |
| A24 state by colour or weight only | same | A18. |
| A25 roles on custom clickables | partly | A25 (connection rows); the FAB, bubbles and busy buttons are fine on iOS. |
| A26 truncation at any size | partly | A22; notification rows are not affected. |
| A27 smaller layout risks | partly | A22 (banner stack); tag pills are A15. |

### Needs a real iPhone (area 1)

**VoiceOver walkthrough of each core flow.** For each, listen for the things in brackets.

1. Onboarding: Welcome → scan → type the code → confirm account → PIN → confirm (type a different PIN) → password →
   backup → progress → done. [Is each new title spoken (A2)? Is the PIN mismatch spoken (A1)? The progress (A3)?
   Return on the password field (A6)?]
2. Unlock with a wrong PIN, then wait out the backoff. [Spoken (A1)? Where is the cursor after "Unlock"?]
3. Owner check with a wrong password. [Is the failure and "N checks left" spoken (A1)?]
4. Transfer in: reach "Compare the code", leave the cursor on the waiting line for 15 s. [Re-read every second (A5)?
   Six digits one by one? Can VoiceOver reach the code on the secure layer, in order (A27)?]
5. Transfer out: leave focus on the QR; scan from the other phone. [Is the safety-code step announced (A2)?]
6. Typed recovery code: type a full wrong code; type a refused character. [Anything spoken (A4)?]
7. An item with a password and a one-time code: reveal, read, copy. [Bullets (A11)? The code (A7)? A confirmation (A21)?]
8. A conversation: receive a reply while it is open (A10).
9. Approvals: decide with a wrong password (A1); let a request expire while open (A2).
10. Start a screen recording with VoiceOver on: can VoiceOver still move to vault content under the capture text (A26)?
11. App lock with Full Keyboard Access: lock, cancel the system prompt, Tab to "Unlock" and press Space.

**Largest accessibility text size (AX5), on the smallest supported iPhone.**

1. The password, PIN-with-password and owner-check screens with the keyboard up: how much of the form is left between
   the keyboard and the bottom buttons?
2. Any password field and the item editor's secret values: does the typed text grow (A13)?
3. "Add a connection" and the item's "Protection" sheet (A12).
4. Settings → Vault → Attestation: are the fingerprints in full at the default size and at AX1 (A8)?
5. The typed recovery code with all twelve groups (A4).
6. Items and History filter rows; the item editor's tags (A15: try tapping the chips' edges and the gold text links'
   blank space).
7. A drawer screen's title with search and the bell (A22); several banners at once (A22).

**Settings to switch on once each:** Bold Text (A14), Reduce Motion (A23), Smart Invert with a QR code on screen
(A23), Increase Contrast with an empty text field (A16).

### Counts (area 1)

| Blocker | Public | Polish |
|---|---|---|
| 0 | 16 (A1–A16) | 11 (A17–A27) |

Not covered: IOS-PLAN §4.12's approvals toolbar indicator and its VoiceOver announcements are not in the code yet
(`Shell/AppShell.swift` has no such item), so they could not be audited; the camera capture screens
(`Settings/Screens/PhotoCaptureScreens.swift`, `Messages/Screens/PhotoOverlays.swift`) were checked for labels only.

---

## 2. Offline and poor network

**What the plan requires.** Only the phase line of IOS-PLAN §8 I4 ("offline and error states"). IOS-PLAN §6.6 says
what happens on leaving the foreground (finish what is in flight, then stop). The specifications expect the phone to
come back and collect what waits in its mailbox, to retry with jittered backoff (VAULT-MESSAGING §8.6, RELAY-PROTOCOL
§7.2), and never to deliver a `vault.lock` late (§8.6).

**What the code does.** No list is cached on the phone. Connections, messages, items, the feed, History and the
profile are held in memory and cleared at the lock (IOS-PLAN §6.9), so nothing stale is shown as fresh. The device
keeps a persisted **outbox** of every message it seals, requests included. A deposit that fails in transport stays in
the outbox and is sent again when the app comes back to the foreground, leaves it, unlocks, or starts collecting
(N1). One ephemeral `URLSession` serves everything, with the system defaults: a 60 s idle timeout per request,
`waitsForConnectivity` off, and no network monitor (N5). With no network at all, a request fails within about a
second or two ("VettID could not reach the service…"). On a link that stalls without failing, a relay deposit can take
about 3 minutes, and all that time it holds the device's lock (N2).

Several flows that the Android audit found fragile hold up here. Enrolment is resumable, the transfer to a new phone
is resumable, the member's lock is kept on the phone and retried, the release update's way back is persisted, and the
member API signs every attempt afresh and retries one 401. Credential operations carry an `exp` and are tracked until
they are settled (VAULT-MESSAGING §11.14.9). Collection runs only while the app is in the foreground. It is a 25 s
long poll, not the WebSocket that IOS-PLAN §6.6 names (P1).

### Operations under bad conditions

| Operation | No network | Relay down, API up | API down, relay up | Cold vault (release starting) | Killed or suspended mid-way |
|---|---|---|---|---|---|
| App start | "Cannot connect" with Try again. Not re-read on return to the foreground (N5) | Opens: the phase comes from the member API. Every list then errors | "Cannot connect", although the vault is reachable | – | – |
| Setup code | Fails at once | Works | Fails | – | A lost answer may burn the code (per spec: every failure of a code is `invalid_code`; S) |
| Enrol | Fails at once | The enrol posts, then `vault.enrolled` never comes (90 s). The retry waits for it and does not post twice (`VaultManager+Enroll.swift:53-56`) | Fails | Waits up to 10 min in 2 s steps, with no "starting" text (N3) | Resumes: the nonces and attempts are kept, and `vault_exists` is checked against this phone's own `vault.enrolled` (`:109-113`) |
| Create credential | Fails | Fails | – | – | Resumes; `exists` fetches instead (`:209-215`) |
| Unlock | Fails, "Try again" | Unlocks; the lists fail | Fails | A busy keypad with no text and no cancel; no client deadline (N3) | The request may still apply (per spec); the next start reads the phase |
| Lock | Locked on the phone at once; pending and retried at 1, 2, 5 and 10 s, then every 30 s and 60 s; relay first, then the member API | Falls back to the member API after 10 s | Works | – | Resumed at the next start (`LockKeeper`) |
| Owner check, PIN or password change, critical item, transfer approval | Fails, and **stays in the outbox with a 10-minute `exp`** (N1) | Same | – | – | Settled by the vault's clock (§11.14.9) |
| Recovery open | Fails; never retried by the app (`AltChannelFlow.swift:405-417`) | Fails at the handshake | Fails | Waits | Lands where the record says |
| Transfer in | Fails; the claim is never retried (per spec, single fetch) | Fails | – | – | Resumable: `device.paired{transfer}` is applied in the message handler, and one deadline is stored (`VaultDevice+Receive.swift:105-109`, `VaultManager+Move.swift:295-312`) |
| Release update | Failed step | Works through the API | Fails | "Starting" line shown | The move marker is persisted; "Return to release N" stays offered |
| Send a message | Fails at once, draft kept; **sent later anyway** (N1) | Same | – | – | Re-sent from the outbox at the next start |
| Items, sharing, approvals, connections (writes) | Error; **applied later anyway** (N1) | Same | – | – | Same |
| Lists (reads) | Error state with Retry on Connections, Messages, Items, Tags, Approvals, Notifications and History | Same | – | – | Read-only |
| Collection | Backs off: 0.25 s × 2ⁿ, capped at 30 s, with jitter | Same | – | – | Acks only after persisting; stops 25 s after leaving the foreground |

### Timeouts and retries

| What | Value | Bounded | Backoff |
|---|---|---|---|
| `URLSession` | `.ephemeral` with defaults: 60 s idle per request, 7 days per resource, no `waitsForConnectivity` (`App/Composition/AppComposition.swift:50`) | yes | – |
| `HTTPTransport` | 2 retries, 0.25 s and 1 s; an 8 s wait for the network that never applies, because the gate is `.always` (`VettIDRelay/Transport.swift:49-51,64-71`; N5) | yes | fixed |
| Relay request | 3 attempts. Every non-fatal `URLError` is retried, timeouts included (`RelayClient.swift:128,195-217`) | yes | 0.25 s × 2ⁿ, half jitter, honours `retry_after` |
| Long poll | `wait=25`, request timeout 60 s (`RelayClient.swift:129,133`) | – | – |
| Mailbox collector | runs for ever in the foreground; stops at background (`RelayStream.swift:164-186`; `VaultManager+Events.swift:121-124`) | – | 0.25 s × 2ⁿ, cap 30 s, jitter |
| Vault request | 30 s × 3, same inner id (`VaultDevice.swift:35`, `VaultDevice+Send.swift:178-195`) | 90 s | fixed |
| Event wait (`vault.enrolled`, `device.paired`) | 90 s; the enrolment's grace 15 s (`VaultManagerConfig.swift:207`) | yes | – |
| Member-API slot poll | every 0.6 s, **no client deadline** for enrol, unlock and recovery (`MemberApiClient.swift:42,328-337`; N3); 12 s for a lock | the slot's 15 min TTL only (per spec §11.5) | fixed |
| `release_starting` | 2 s steps, 10 min in all (`MemberApiClient.swift:47-49,268-281`) | yes | fixed |
| Lock | relay answer 10 s, `exp` 30 s; member API 12 s; retries at 1, 2, 5 and 10 s, then 4 × 30 s, then every 60 s (`LockKeeper.swift:511-523`) | runs while the process runs | stepped, +20 % jitter |
| Unresolved PIN or password change | recheck 30 s, doubling to 300 s (`VaultManager+Changes.swift:33-34`) | until decided | exponential |
| Routing after an unconfirmed move | 5, 10, 15, 15, 15 s (`VaultManager+Unlock.swift:317`) | yes | stepped |
| Leaving the foreground | ≤ 25 s background task (`App/VettIDApp.swift:239-255`) | yes | – |

### Blocker

#### N1. A request that fails in transport is shown as failed, but stays in the persisted outbox and is delivered later. A credential operation retried in the meantime then raises a false clone alarm.

- **Severity:** Blocker. **Status:** V on the phone; what the vault does with the late copy is per spec (VAULT-MESSAGING §3.5.3 step 3, §3.5.9). **Size:** M.
- **Where:**
  - Every request is appended to `st.outbox`, saved, then delivered: `VaultDevice+Send.swift:60-81` (append at `:75`).
  - `deliver` handles only a `RelayError`. A transport `URLError` passes through and leaves the entry in place; so does a retryable relay error or `quota_exceeded` (`:85-106`).
  - `request()` then throws at once (`:175-177`).
  - `flushOutbox` re-deposits every entry (`:146-153`). It runs:
    - when the collection starts (`VaultDevice.swift:386`);
    - on every return to the foreground (`VaultManager+Events.swift:87`);
    - on every **departure** from the foreground (`:106`);
    - after every unlock (`VaultManager+Unlock.swift:245`);
    - before a change of PIN or password (`VaultDevice+Settle.swift:73`).
  - The entries have no expiry and no limit. `attempts` is counted and never read (`DeviceState.swift:138-146`).
  - The design is deliberate (`VaultDevice+Send.swift:155-159`: "a caller that tries again does so with the same innerID"). Only the photo send (`Attachments.swift:95`) and the credential operations reuse an id. `message.send`, `item.put` (create), `connection.invite.create`, `grant.decide` and the other writes take a fresh id on every tap (`VaultApi+Messages.swift:10-12`, `VaultApi+Items.swift:65-76`, `VaultApi+Connections.swift:22`).
- **What happens.** The clone alarm:
  1. A credential operation (a critical item opened with the password, an owner check, an approval of a critical-secret use, …) seals the current blob version *n* under an `exp` 10 minutes ahead (`CredentialOps.swift:205-212,418-421,484`).
  2. Its deposit fails: no signal, or a relay 5xx three times. The member is told it failed.
  3. The member taps again within 10 minutes and it works. Nothing checks that the earlier request is settled: the gate only looks for PIN and password changes (`CredentialOps.swift:137-150`, `VaultManager+Changes.swift:172-177`).
  4. The vault rotates the blob to *n + 1*. The phone keeps it and confirms it with `credential.ack` (`CredentialOps.swift:51-52`).
  5. The member leaves the app (or returns, or unlocks), and the flush delivers the first request, still inside its `exp`.
  6. Per §3.5.3 step 3, a superseded blob that is not the holder's retry of an *unconfirmed* version is a clone. The vault answers `credential_frozen` and opens a `credential.alarm`, and the credential stays frozen until the member confirms and rotates.

  If the first request had the wrong password, the same happens; the blob check comes before the password.

  Outside credential operations:
  - A message sent while offline shows an error and keeps the draft. The member sends again, and the peer gets it twice.
  - A new item saved twice becomes two items.
  - A grant, an approval, a removal or an unlink that the member was told had failed is applied later, with no notice. A member who then changed their mind and denied loses to the stored approval.
  - Nothing is shown as pending.
- **Why it matters.** A false clone alarm on a tester's credential is a security alarm that is not true, and it blocks every credential operation until the member rotates. It looks exactly like a theft. It needs only one failed deposit and a successful retry within 10 minutes. This is the same defect as vettid-android N2, which was fixed there by #185.
- **Suggested fix.** As vettid-android #185:
  - Never write requests to the outbox. Keep it for fire-and-forget protocol messages (`relay.token.*`, the answers to the vault's own requests).
  - Drop the request entries that earlier versions left, at load.
  - Until then, at the very least, remove the entry when `request()` gives up, and drop every credential request from the outbox once a later credential operation has gone out.
  - Add an idempotency key to the creating writes (a spec question; see vettid-android N11).

### Public

| ID | Finding | Evidence | Effect | Fix | Status |
|---|---|---|---|---|---|
| N2 | The device lock is held across network I/O, and nothing bounds a relay call except the system's 60 s idle timeout. | `send`, `request` and the resends hold `lock` around `sendLocked` → `deliver` → `deposit` (`VaultDevice+Send.swift:10,176,190`). So does the flush, entry by entry (`:148-151`). `handle()` takes the same lock for every incoming message (`VaultDevice+Receive.swift:11`), and inside it may deposit `hs.fin`, an `hs.resp` or a token refresh (`VaultDevice+Enroll.swift:121`; `VaultDevice+Receive.swift:118,171,236,240`). `RelayClient.execute` retries `timedOut` 3 times (`RelayClient.swift:210-215`). The session has no `timeoutIntervalForRequest` of its own (`AppComposition.swift:50`). The plain `AsyncLock.acquire()` cannot be cancelled (`Concurrency.swift:24-36`). | On a link that stalls (a weak cell edge, a captive network), one deposit can hold the lock for about 3 minutes. Meanwhile no answer is processed, every other request times out behind it (30 s × 3), and the lists read at unlock fail together. | M: seal and persist under the lock, deposit outside it. Set `timeoutIntervalForRequest` (for example 20 s) and keep 60 s for the long poll only. | V; effect S |
| N3 | The unlock's, the enrolment's and the recovery open's slot polls have no client deadline and cannot be cancelled. A cold start is not explained. | `poll(_:atMost:)` loops without `atMost` (`MemberApiClient.swift:328-337`), called from `postAndPoll` (`AltChannelFlow.swift:190-200`) and `recoveryOpen` (`:430`). The unlock screen's route has no `onStarting` (`VaultManager+Unlock.swift:133-138`, `UnlockRoute()` at `:21-35`). Only the release update wires it (`VaultManager+ReleaseUpdate.swift:153-155`). `enclaveWait` waits up to 10 min (`MemberApiClient.swift:268-281`). The unlock screen shows a spinner with "checking" while it loads (`UnlockScreen.swift:229-235`) and nothing that ends the wait. | With a cold host, or a slot the host never answers, the member watches a busy keypad for minutes. Only the slot's 15-minute TTL (per spec §11.5) ends it. | S: a client deadline (about 3 min) with "Your vault is starting… this can take a minute or two" after 10 s, as in the update flow, and a Cancel. | V; timing S |
| N4 | A wrong phone clock is recognised only on a member-API 401. Every other symptom is shown as a network or "no answer" failure. | `clock_skew` comes only from a 401 whose `Date` is more than 240 s off (`MemberApiClient.swift:119-126`; `MemberApiModels.swift:12`). A relay `timestamp_stale` (more than 90 s off, RELAY-PROTOCOL §4.1) is retried 3 times, re-signed with the same wrong clock, and then becomes `.network` (`RelayClient.swift:43,48`; `VaultFailures.swift:41`). A phone more than 5 minutes behind drops every vault answer as "from the future" (`VaultDevice+Receive.swift:77-83`), and the `droppedForTime()` stream that reports it has no subscriber outside its package (`VaultDevice.swift:233-234`): "Your vault did not answer in time". A transfer code is checked against the phone's clock (`VaultDevice+Transfer.swift:42`). | Between 90 s and 4 minutes off, the unlock works and then every relay action says "check your connection". Further off, the answers vanish. The member is sent after the wrong cause. | M: take the skew from the relay's and the API's `Date` headers. Say "Check the date and time" when it is large. Subscribe to `droppedForTime()`. | V |

### Polish

| ID | Finding | Evidence | Fix | Status |
|---|---|---|---|---|
| N5 | No connectivity awareness. | `NetworkGate`'s comment says the app passes one backed by `NWPathMonitor` (`Transport.swift:4-5`). The app passes nothing, so it is `.always` (`AppComposition.swift:50`), and the 8 s wait for the network after a wake never happens. `notConnectedToInternet` is retried only for GETs (`Transport.swift:154-159`), so an unlock or lock POST right after the phone wakes or changes network fails at once. No offline banner. The root "cannot connect" screen is re-read only for `.starting` and a locked iPhone (`App/VettIDApp.swift:224-235`), not when the app comes back to the foreground or the network returns. | S: pass an `NWPathMonitor` gate. Re-read an `.unreachable(.network)` phase on `.active` and when a path becomes satisfied. Optionally a small offline banner. | V |
| N6 | Every relay error is shown as the network text. | `case let r as RelayError: VaultFailure(.network, …)` (`VaultFailures.swift:41`) covers `quota_exceeded` (outside photos), `payload_too_large`, `token_revoked`, `rate_limited` and every `http_4xx`. | S: map `rate_limited`, the quotas and the stale signature (N4) to their own kinds. | V |
| N7 | A lost `hs.fin` burns a pairing or a transfer code. | `handleResp` deposits `hs.fin` once (`VaultDevice+Enroll.swift:121`). A failure is swallowed and the message acked (`VaultDevice+Receive.swift:28-32`). | S: keep `hs.fin` and retry its deposit. | V |
| N8 | A lost `credential.ack` reports a successful operation as failed. | `keep` stores the blob and then awaits `credential.ack` as an ordinary request; its failure throws out of the operation (`CredentialOps.swift:35-54`). Safe: the blob is stored first. | S: send the ack best effort (and again at the next operation). | V |
| N9 | Nothing keeps the screen on during the long waits. | No `isIdleTimerDisabled` anywhere. The waits are the transfer comparison (up to 11 min), the enrolment's `vault.enrolled`, a cold start and the release update. The auto-lock puts the app in the background, the collection stops after 25 s (`VaultManager+Events.swift:95-124`), and the member-API poll is suspended. | S: disable the idle timer while these screens wait. The transfer and the enrolment already resume, so this only avoids a failure text on return. | V; effect S |

### Android A6 area 2 on the iPhone

| Android finding | iOS | Note |
|---|---|---|
| N1 transfer not resumable | not here | `device.paired{transfer}` is applied in the handler (`VaultDevice+Receive.swift:105-109`). One stored deadline, and a collect at it (`VaultManager+Move.swift:126-131,276-312`). The screen-on part is N9. |
| N2 failed request replayed from the outbox | same, **N1** | Credential requests are bounded by their 10-min `exp`, which is exactly the clone-alarm window. |
| N3 enrolment not resumable | not here | The nonce and attempts are kept; no second post while one is outstanding (`VaultManager+Enroll.swift:53-56,109-113`; `VaultDevice+Enroll.swift:56-80`). |
| N4 member-API GET re-sent with the same signature | not here | Built and signed per attempt; one fresh retry of a 401 (`MemberApiClient.swift:84-104`). |
| N5 wrong clock | same, **N4** | Partly fixed: a member-API 401 with a skewed `Date` is "check the date and time". |
| N6 empty status body destroys the keys | not here | Only an explicit `"vault": null` is "no vault" (`MemberApiClient.swift:195-210`), and the member then confirms the start-over (`StuckWays.swift`). |
| N8 slot poll without deadline | same, **N3** | |
| N9 failed phase read closes the open app | not here | `refresh()` runs while the app is open only on a `device.unlinked` of another reason or after a failed lock, and a pending lock returns `.locked` (`VaultManager.swift:578-583`). |
| N10 lock fails silently | not here | The lock is pending on the phone, which shows locked at once, and it is retried (`ShellModel.swift:171-179`, `VaultManager+Lock.swift`). |
| N11 no idempotency key on creating writes | same, part of **N1** | |
| N12 device mutex across network I/O | same, **N2** | |
| N13 malformed 2xx ends the process | not here | The collector's errors end the run, which is reported and restarted at the next foreground or unanswered request (`VaultDevice.swift:394-404`, `VaultDevice+Send.swift:187`). Swift errors do not crash. |
| N14 no connectivity awareness | same, **N5** | Also an unwired network gate. |
| N15 coarse failure kinds | same, **N6** | |
| N16 lost `hs.fin` | same, **N7** | |
| N17 lost `credential.ack` | same, **N8** | |
| N18 release-update progress memory-only | not here | The move marker is persisted, and "Return to release N" stays on the unlock screen (`VaultManager+MoveMarker.swift:27-31`). |
| N19 two transfer timers; UTK spent | not here | One stored deadline (`VaultManager+Move.swift:126-131`); the view model only shows the seconds (`TransferInViewModel.swift:218-232`). |
| N20 70 s read timeout vs 80 s cold start | n/a | The slot is polled, not held open; the system's 60 s idle timeout applies to each poll. |

### Checked and sound

- **Ack after persist:** each message is recorded, processed and saved before the relay ack. The state is written to a temporary file with `fsync` and renamed (`VaultDevice+Receive.swift:10-35`, `EncryptedFileStore.swift:167-197`).
- **Lock:** `vault.lock` never goes through the outbox (`sendOnce`, `VaultApi.swift:114-123`). Leftovers of earlier versions are dropped at every unlock (`VaultManager+Unlock.swift:243`). The lock is pending and retried, with backoff and jitter, within the member API's rate limit.
- **Credential operations and changes:** every one carries an `exp`, is tracked until its answer or its `exp` by the vault's clock, and a change waits for them (§11.14.9). N1's window is the 10 minutes before that.
- **Retries:** the app's own resends reuse the inner id. Relay and member-API signatures are made afresh for every attempt. A claim fetch is never retried.
- **Leaving the foreground:** the background task is capped at 25 s, its work is cancelled at expiry, and the collection stops after it (`App/VettIDApp.swift:239-255`, `VaultManager+Events.swift:95-124`).
- **Captive portals and TLS:** certificate and ATS failures are never retried (`Transport.swift:161-166`). A non-JSON member-API body is "malformed", not "no vault".
- **Reconnect:** jittered and capped at every level, and resumed at the next foreground.

---

---

## 3. Error states

**Paths.** `Target/…` is `Packages/<package>/Sources/Target/…`: `VettIDData/Vault/VaultManager.swift` is
`Packages/VettIDData/Sources/VettIDData/Vault/VaultManager.swift`, and `VettIDItemsUI/Screens/ItemsScreen.swift` is
`Packages/VettIDItems/Sources/VettIDItemsUI/Screens/ItemsScreen.swift`. `App/…` is the app target.

**What the plan requires.** Failures reach the screens as `VaultFailure(kind)`, and each kind's member-facing text comes from
`FailureKind.message` (`VettIDData/Vault/FailureText.swift:10`). IOS-PLAN §4.4 (2) approves one exception: a vault code with
no text of its own is shown as "Something went wrong (code: …)". The code must match `[a-z0-9_]{1,40}`; anything else is
shown as `unknown` (`VettIDData/Vault/VaultFailures.swift:177-185`).

**What the code does.** There are 67 failure kinds, each with its own sentence. All failures from the layers below pass
through one mapper (`VaultFailures.map`, `VettIDData/Vault/VaultFailures.swift:21-49`).

- **Nothing raw reaches a screen.** No `localizedDescription`, exception text, URL or stack trace is shown. The only codes
  shown are the approved filtered ones and the cases in E9.
- **Enclave failures are split.** Unlike vettid-android, an enclave, manifest or release-list failure is a different kind
  from this phone's attestation (`enclaveFailure`, `:189-192`), so Android's E6 is not here.
- **Root stuck screens are titled by cause** and offer confirmed ways out: start over, erase, clear data, recover
  (`VettIDOnboardingUI/Screens/UnreachableScreen.swift:51-58`; `VettIDOnboarding/StuckWays.swift:36-46`).
- **An erase that does not finish is never shown as a clean start** (`VettIDData/Vault/WipeRun.swift:20,36-42`).

The weak points are:

- lists that say "nothing here" when they could not be read;
- errors the state holds but the screen only renders on an empty list;
- one editor that opens empty after a failed load;
- a few texts that are false, show a raw word, or drop the wait.

No blocker was found in this area.

### Public

#### E1. Approvals: lists that could not be read show "Nothing to approve", and action failures are never shown on a non-empty list

- **Severity:** Public · **Status:** V · **Size:** S–M
- **Where:**
  - `VettIDData/Social/ApprovalsManager.swift:327` (`try?` on the connection requests) and `:397-404` (`try?` on each of
    the three lists).
  - `VettIDApprovalsUI/Screens/ApprovalsScreen.swift:51-66`.
  - `VettIDApprovals/ApprovalsViewModel.swift:124-137`.
- **What happens:**
  - A list that fails is treated like a list the vault does not have: nil, "not covered".
  - `refreshApprovals` throws only when the operations object cannot be made, which is local, so offline it returns normally.
    After an unlock with the relay unreachable, the screen therefore shows the empty state "Nothing to approve", not its
    error card.
  - Requests known from an earlier read are kept (`listed.filter { !lists.covers($0) }`, `:333`), so the problem is the
    first read and new requests.
  - Separately, `act` (Resume requests, Remove connection) sets `local.error`. The screen renders `state.error` only when
    `state.nothing` (`ApprovalsScreen.swift:55`). Both actions exist only on a row of a paused connection, so the list is
    never empty and their failure is never shown.
- **Why it matters:** pending grant, critical-use and share decisions are invisible, and nothing says the list is unknown.
  The member tapped "Remove connection" and is told nothing when it failed.
- **Suggested fix:**
  - When every list fails for a transport or vault reason, throw. Keep nil only for "not supported" (an older release).
  - Show the error as an inline card above a non-empty list, as Connections does
    (`VettIDConnectionsUI/Screens/ConnectionsScreen.swift:95-97`).

#### E2. Other lists present "could not be read" as "nothing here"

- **Severity:** Public · **Status:** V · **Size:** S each
- **Where:**
  - What you share with a connection: the load at `VettIDItems/ConnectionSharingViewModel.swift:77-95`. After a failure
    the screen still renders "You share nothing with %@ by tag." and "%@ can fetch nothing from your vault."
    (`VettIDItemsUI/Screens/ConnectionSharingScreen.swift:119-124,140-145`). The error card has only "OK"
    (`VettIDItemsUI/Screens/SharingParts.swift:15-19`).
  - "%@ shares nothing with you." after a failure (`VettIDItemsUI/Screens/SharedWithYouScreen.swift:115-123`).
  - "No tags yet" under an OK-only card (`VettIDItemsUI/Screens/TagsScreen.swift:78-84,100-103`).
  - The new-message picker sets `error` (`VettIDMessages/MessagesViewModel.swift:139-142`), but
    `VettIDMessagesUI/Screens/NewMessageScreen.swift` never reads it. It shows "No connections" with "Invite".
  - A conversation that failed to load shows "Say hello" under an OK-only card
    (`VettIDMessagesUI/Screens/ConversationScreen.swift:61-64,117-122`).
- **Why it matters:** the sharing texts are false statements about what the member shares, and dismissing the card leaves
  only them. "New rule" stays enabled on a screen whose rules are unknown.
- **Suggested fix:** a load-failed state with "Try again", and no empty-state text while `error != nil`.

#### E3. Editing an item whose load failed opens an empty form titled "Not saved", with no retry

- **Severity:** Public · **Status:** V · **Size:** S
- **Where:** `VettIDItems/ItemEditViewModel.swift:164-180`, `VettIDItems/ItemEditState.swift:21`,
  `VettIDItemsUI/Screens/ItemEditScreen.swift:166-170,249-256`.
- **What happens:** on a failed `item.get`, the draft stays empty with `version` 0, the form is shown, and the error notice
  is titled `items_error_save` ("Not saved"), with OK only. Save stays available. Per spec (VAULT-MESSAGING §10.7), the
  vault refuses an `item.put` at the wrong version as a conflict, so nothing is overwritten, but there is no way forward.
- **Why it matters:** the member's item looks empty, and the title names the wrong operation.
- **Suggested fix:** a load-failed state with "Try again", and Save disabled until the item is loaded.

#### E4. Transfer to this phone: a refused or failed code left in front of the camera is sent again every two seconds

- **Severity:** Public · **Status:** V/S · **Size:** S
- **Where:**
  - `VettIDOnboarding/TransferInViewModel.swift:74-77`: `scanned` checks only the step and `busy`.
  - `:190-205`: `connectFailed` returns to `.scan`.
  - `VettIDUI/Components/QrScanner.swift:54-69`: `QrTextGate` passes the same text again after 2 s, and the scanner is
    rebuilt with a new gate on each step change.
  - Setup and recovery guard against this (`VettIDOnboarding/OnboardingViewModel.swift:27,245-249`;
    `VettIDOnboarding/RecoverViewModel.swift:211-212`).
- **What happens:** each repeat starts a new handshake (`.connecting`), and the accurate error text flickers away.
- **Why it matters:** the member cannot read why the code failed, and per spec (VAULT-MESSAGING §6.7.1) each attempt is a
  pairing the vault and the old phone see.
- **Suggested fix:** remember the last refused text, as the setup flow does (`failedScan`).

#### E5. "What you entered is kept" is false on the iPhone

- **Severity:** Public · **Status:** V/S · **Size:** S–M
- **Where:**
  - The text is `data_failure_owner_check_required`: "Your daily check is due. What you entered is kept: the check opens
    when you leave this screen."
  - A refusal with `owner_check_required` marks the check due (`VettIDData/Vault/OwnerCheckManager.swift:261-267`).
  - The gate then replaces the whole shell at once (`App/VettIDApp.swift:299,341-351`).
  - The editors' view models are view `@State` (`VettIDItemsUI/Screens/ItemEditScreen.swift:60,84`), so they go with the
    shell.
  - Delete vault clears the PIN and password on every failure (`VettIDSettings/DeleteVaultViewModel.swift:117-122`).
- **What happens:** the check opens immediately, not "when you leave this screen". The draft that is said to be kept is
  dropped (see R1).
- **Why it matters:** the member trusts the text and loses the edit.
- **Suggested fix:**
  - Either keep the editors' drafts across the gate (R1), or give the iPhone its own text.
  - On Delete vault, keep the fields for this kind.

### Polish

| ID | Finding | Evidence | Fix | Status |
|---|---|---|---|---|
| E6 | A failed refresh is silent when the list has rows. | Items, Messages and Approvals render `state.error` only when the list is empty (`VettIDItemsUI/Screens/ItemsScreen.swift:97`, `VettIDMessagesUI/Screens/MessagesScreen.swift:71`, `ApprovalsScreen.swift:55`). History with rows shows a bare "Try again" with no reason (`VettIDHistoryUI/Screens/HistoryScreen.swift:195-196`). Connections does it right (`ConnectionsScreen.swift:95-97`). | S: an inline notice above the rows. | V |
| E7 | An unclassified load failure on the Vault screens reads "Your vault refused this item. Check its fields and try again." | `VettIDItems/ItemsText.swift:35-37` gives this text to `.other` without a code (or with `bad_request`). It is used by the list (`ItemsScreen.swift:97-98`), the item screen, tags and sharing. `.other` without a code comes from `VaultFailures.map`'s default (`VaultFailures.swift:47`) and from `error as? VaultFailure ?? VaultFailure(.other)` in the view models. Narrower than Android E8: keystore failures carry a code and show it. | S: the refusal text only for writes; "could not be read" for loads. | V |
| E8 | A release rollback on the unlock screen has no "Check again". | `primaryLabel` is nil when `recoverOnly` (`VettIDOnboardingUI/Screens/UnlockScreen.swift:75-79`), and `recoverOnly` includes `preflight.rollback` and `stateRollback` (`VettIDOnboarding/UnlockState.swift:113`). "Recover your vault" and "Contact support" are offered (`VettIDOnboardingUI/Screens/UnlockParts.swift:159-178`), so this is not a dead end. Nothing re-runs the preflight on return to the foreground, so only killing the app re-checks. | S: a "Check again" link (`retryPreflight`). | V |
| E9 | Raw wire words shown. | "The update was refused (%@)." with the sealed result's code, unfiltered (`UnlockScreen.swift:390-391`; the code comes from `VettIDData/Vault/VaultManager+Unlock.swift:198`), while the update flow maps the same codes to sentences (`VettIDOnboardingUI/Screens/ReleaseUpdateFlowScreen.swift:213-223`). "Your vault did not move (%@)." for an unknown code, not through `shownCode` (`:222`). "Release %lld is %@" with `deprecated`/`retired` (`UnlockParts.swift:35-38`, `ReleaseUpdateScreen.swift:166,172`). Vault status's raw recovery state and release status (`VettIDSettingsUI/Screens/VaultStatusScreen.swift:118,124`). | S: reuse `refusalText`, filter with `VaultFailures.shownCode`, one word per status. | V |
| E10 | Backoff without the wait. | A rate-limited setup-code redeem keeps `retryAfterSeconds` only for `.enrollmentStarted` (`OnboardingViewModel.swift:180-181`). Change PIN (`VettIDSettings/ChangePinViewModel.swift:241-242`), Delete vault (`DeleteVaultViewModel.swift:109-125`), the unlock-window dialog (`VettIDSettings/CredentialViewModels.swift:119-123`), Rotate, New credential and New phone secret never read it. Recovery, transfer out, the password prompt, the history export and the approval detail do. | S: reuse `PasswordPrompt`'s countdown. | V |
| E11 | Wrong-cause texts. | Any `bad_request` in the History export reads "needs a newer vault release" (`VettIDHistory/HistoryExportViewModel.swift:300`). Any failure while transfer-out waits for the new phone goes to `expire()`, titled "expired" with the real error under it (`VettIDSettings/TransferOutViewModel.swift:186-197`). The way back to release N, refused before anything was sent, reads "Something went wrong. Try again." (`VettIDOnboarding/UnlockViewModel.swift:270`). | S each. | V |
| E12 | History's "does not match" banner offers "Try again", which can never clear it. | `chainBroken` is sticky (`VettIDHistory/HistoryViewModel.swift:265`); with rows, `retry()` only loads more (`:185-191`). | S: reset on a full reload, or drop the action. | V |
| E13 | Swallowed failures of smaller consequence. | A JSON file opened with VettID that cannot be read: nothing happens (`App/VettIDApp.swift:212-216`; Settings' import does say so, `VettIDSettingsUI/Screens/SettingsRoutes.swift:206`). The hold-off banner's "Turn on" and "OK" (`VettIDShell/ShellModel.swift:183,185`). The editor's sharing dry run reads as "shares nothing new" after a failure (`VettIDItems/ItemEditViewModel.swift:111-120`). Attestation's load failure has no retry (`VettIDSettingsUI/Screens/AttestationScreen.swift:50`). "Go" on the last screen of a transfer or a recovery runs `try? await vault.finishSetup()` with no busy or error state (`TransferInViewModel.swift:259-261`, `RecoverViewModel.swift:432-434`), while the setup flow's Done screen shows the same failure. A setup link opened on a phone that already has a vault is queued and ignored with no word (`App/VettIDApp.swift:190-192`; consumed only by onboarding, `OnboardingViewModel.swift:263-264`). | S each. | V |
| E14 | "Unblock it first" with no block list. | `data_failure_blocked`, and the block confirmation's "…unless you unblock it" (`VettIDConnectionsUI/Support/ConnectStrings.swift:344`). `VaultApi.blockList` and `blockRemove` have no caller (`VettIDVault/VaultApi+Connections.swift:114-119`). | S. | V |

### Empty states

| List | Empty | Load failed | Failure with rows |
|---|---|---|---|
| Conversations | Yes, three variants | Card with retry | Silent (E6) |
| A conversation | "Say hello" | Not distinct (E2) | Card |
| New-message picker | Yes | Not rendered (E2) | – |
| Connections | Yes | Card with retry | Card |
| Connection detail | – | Card with retry | – |
| Approvals | Yes | Swallowed (E1) | Silent (E1, E6) |
| Items | Yes | Card, wrong text (E7) | Silent (E6) |
| Tags, sharing rules, shared with you | Yes | Not distinct (E2) | Card, OK only |
| History | Yes | Card with retry | Bare retry (E6) |
| Notifications | Yes | Distinct, with retry | Toast |
| Vault status, credential | – | Card with retry | – |

### Checked and sound

- **Cancellation.** `VaultFailures.map` keeps a cancellation as one (`:24`). About 150 `try? await` sites swallow
  cancellation as Kotlin's `runCatching` does; those read are each followed by a return or a state write (Android E24).
- **Unlock.** Wrong PIN, backoff with its countdown, paused service with its wait, recovery pending, state rollback, signer
  refused, "not recognised", keys gone with the earlier-secret step, and the lock notices are separate states. An erase from
  the unlock screen that fails says so and leaves the screen as it was (`VettIDOnboarding/UnlockViewModel.swift:210-226`).
- **Stuck screens.** The root's stuck screen and the vault-being-deleted screen offer confirmed ways out. Their erase cannot
  fail silently, because the phase becomes `eraseFailed` with "Try again" and "Erase VettID's data on this phone".
- **Recovery.** A registered recovery can be left with a confirmed "Start over" that shows its own failure (Android E1 is
  not here). A stage that cannot be read has its own step with "Try again" and Back (Android E20 is not here).
- **Gates and covers.** The owner-check gate always offers submit or "Lock vault". The credential-required cover offers
  "Try again" and "Lock vault".
- **The scanner.** Setup and recovery ignore a refused text until another is seen. The scanner drops texts over 4096
  bytes.
- **Raw errors.** No raw error is shown. Codes appear only through the approved filtered text.

### Android A6 area 3 on the iPhone

| Android finding | iOS | Note |
|---|---|---|
| E1 recovery cannot be left | not here | Confirmed "Start over" on the open step (`RecoverViewModel.swift:400-430`). |
| E2 Approvals "Nothing to approve" | same | iOS E1; known requests are kept, and action failures are also hidden. |
| E3 lists "nothing here" | same | iOS E2. |
| E4 cancel deletion silent | n/a | No pending-deletion banner; deletion is the `.deleting` phase (`App/VettIDApp.swift:264-267`). |
| E5 scanner resubmits per frame | partly | 2 s gate (`QrScanner.swift:54-69`); setup and recovery guarded; transfer-in is iOS E4. |
| E6 every attestation exception is "this phone" | not here | Separate enclave, manifest, release-unknown, App Attest and hardware kinds (`VaultFailures.swift:62-91,189-192`). |
| E7 unlock dead ends | partly | Release ended and rollback offer Recover and Contact support; rollback has no re-check (iOS E8). |
| E8 "Your vault refused this item" on loads | same | iOS E7 (narrower). |
| E9 empty editor after a failed load | same | iOS E3. |
| E10 undecodable answer crashes | not here | Swift decoding throws, mapped to `.other` (`VaultFailures.swift:47`). For stored state, see R4. |
| E11 recovery and update flatten answers | not here | Route-pending and state rollback have their own texts (`UnlockScreen.swift:384-386`, `:298-300`); one generic case is in iOS E11. |
| E12 wire codes shown | same | iOS E9. The "(code: …)" text is approved (IOS-PLAN §4.4 (2)). |
| E13 backoff without the wait | same | iOS E10. |
| E14 "What you entered is kept" | same | iOS E5. |
| E15 wrong-cause mappings | same, partly | iOS E11. |
| E16 blank screens, sticky banner | partly | Connection detail has a retry (`VettIDConnectionsUI/Screens/ConnectionDetailScreen.swift:79-83`); History banner is iOS E12. |
| E17 silent refresh with cached rows | same | iOS E6; Connections is sound. |
| E18 incomplete erase looks complete | not here | `WipeRun.swift:20,36-42`. |
| E19 swallowed failures | same | iOS E13. |
| E20 failed stage read restarts recovery | not here | Own step with retry (`VettIDOnboardingUI/Screens/RecoverScreen.swift:43,121-133`). |
| E21 stale onboarding copy | not here | No "next update" copy found in the catalogs. |
| E22 "Unblock it first" | same | iOS E14. |
| E23 `REJECTED` and `NOT_FOUND` texts | partly | Rejection is a transfer step of its own (`TransferInViewModel.swift:180-182`); "Nothing was found." remains for `.notFound` outside Items. Not raised. |
| E24 `runCatching` catches cancellation | same, harmless | `try? await`; none of the sites read is harmful. |

---

## 4. Robustness

**What the plan requires.**

- IOS-PLAN §6.3: typed secrets are dropped when the app leaves the foreground and when the iPhone locks.
- IOS-PLAN §6.6: what is in flight is finished in a background task, then the collection stops.
- ID17: the app lock covers everything, sheets and alerts included.

**What the code does.**

- **Shape.** The app is iPhone only and portrait only (`Config/Base.xcconfig:8`, `project.yml:118`), so rotation, size
  classes and multiple windows do not arise.
- **No state restoration.** There is no `@SceneStorage` and no `NSUserActivity`. After the app is killed, the phase is read
  again from the stored records and the vault, and the open app starts at its start destination.
- **The app lock does not rebuild.** It hides the content under a window of its own and keeps it
  (`App/AppLockGate.swift:28-33`), so Android's R1 does not exist here.
- **The shell.** Its place (destination, pushed screens) lives in `ShellModel`, above the owner-check gate
  (`VettIDShell/ShellModel.swift:7-20`).
- **Concurrency checking.** Strict concurrency is `complete` with Swift 6 (`Config/Base.xcconfig:9-10`).
- **No crash reachable by data was found.**
  - The two force casts are of keychain results asked for as `SecKey` (`VettIDKeys/SecureEnclaveKeychain.swift:74`,
    `VettIDKeys/AppLockKeys.swift:146`).
  - The preconditions guard pinned constants and test seeds.
  - JSON integers are read failably (`VettIDVault/VaultMessage.swift:43-45`).
  - Arithmetic overflow on values from the vault was sampled, not exhaustively audited.

The weak points are:

- what the shell's screens hold in view state when the gate or a lock replaces the shell;
- the system back swipe, which bypasses the flows' own Back;
- the app lock's timeout measured on the wall clock;
- a stored file that cannot be decoded, which lands on a stuck screen with no way out for a week.

### After the app is killed

| Flow | The member lands on |
|---|---|
| Setup code typed or scanned | Welcome; input gone |
| After redeem, enrolment, credential | The setup stage read from the records and the vault (`VettIDData/Vault/VaultManager.swift:555-566`) |
| Unlock | Unlock, empty keypad |
| Recovery | The stage from the stored recovery record |
| Transfer in | Resumed from the stored transfer (`resumeTransferIn`, `VaultManager.swift:555`) |
| Transfer out | Settings is gone; the open transfer expires per spec (VAULT-MESSAGING §6.7.1) |
| Owner check | The gate again if due |
| Release update | Unlock, with the unconfirmed move's notice (IOS-PLAN §4.3) |
| A wipe under way | Finished at the next launch (`App/Composition/AppComposition.swift:119-124`) |
| Item or rule editor, message draft, name change | The start destination; unsaved work lost (as R1) |
| History export | History; nothing written (the file is written only by the system exporter) |

### Public

#### R1. Drafts are dropped without a word whenever the shell is replaced: the owner check's deadline, a lock, a release update

- **Severity:** Public · **Status:** V (the effect on a phone: S) · **Size:** M
- **Where:**
  - `App/VettIDApp.swift:299,341-351`: `OwnerCheckGateView` swaps the whole `AppShell` for the check, re-reading the
    deadline every 15 s.
  - `:203-209`: `closeIfNotOpen` resets the shell when the phase leaves `.unlocked`.
  - `:264-271`: the release update and the deleting phase replace everything.
  - `VettIDShell/ShellModel.swift:157-169`: only the path survives.
  - The editors' state lives in view `@State`: `VettIDItemsUI/Screens/ItemEditScreen.swift:60`,
    `VettIDItemsUI/Screens/RuleEditScreen.swift:48`, `VettIDMessages/ConversationViewModel.swift:64` (`draft`),
    `VettIDMessagesUI/Screens/MessagesRoutes.swift:72`.
- **What happens:**
  - When the daily deadline passes mid-edit (or a refusal marks the check due, E5), the editor's view model is freed.
  - After the check, `ShellModel` pushes the same route again, and a new view model reloads the item. The typed changes,
    the message draft and a rule being made are gone.
  - A vault lock (the vault's idle lock, another device's lock, the member's own) resets the path too.
  - Unlike vettid-android after its R1 fix, the app lock does not cause this: its content is kept.
- **Why it matters:** a long edit is lost silently, and in the owner-check case the text says it is kept (E5).
- **Suggested fix:**
  - Hold the editors' drafts in `ShellModel`, or in an object owned above the gate.
  - At least say "Your changes were not saved" when the route comes back.
  - For a lock, say what was dropped.

#### R2. The system back swipe is on for every pushed flow except the two editors, and it bypasses the flow's own Back

- **Severity:** Public · **Status:** V/S · **Size:** S
- **Where:**
  - `VettIDShellUI/AppShell.swift:220-226` turns the edge swipe on for the whole stack.
  - `VettIDUI/Components/DrawerContainer.swift:194-198`: blocked only by `blocksBackGesture`, which only the item and rule
    editors use (`ItemEditScreen.swift:174`, `RuleEditScreen.swift:171`).
  - The flows' own Back is disabled while busy (`VettIDUI/Components/Forms.swift:426-438`), but the swipe is not.
  - Transfer out cancels its open transfer only in `leave()`, which only its own Back and Done call
    (`VettIDSettingsUI/Screens/TransferOutScreen.swift:37-43,108,115,127`). There is no `onDisappear`.
  - The view model's `deinit` cancels its work and waits (`VettIDSettings/TransferOutViewModel.swift:148-152`).
- **What happens:**
  - A swipe on transfer out while the code is shown leaves the transfer open at the vault until it expires. Per spec
    (VAULT-MESSAGING §6.7.1) the new phone can still pair and wait for an approval that will not come.
  - A swipe while the approval is in flight frees the screen. Per spec, the vault may complete the transfer, and the old
    phone then erases itself without having shown the outcome.
  - On Change PIN, Change password, Rotate, New credential and New phone secret, a swipe during the request cancels the
    wait. The change's marker then decides the outcome later (VAULT-MESSAGING §11.14.9), and the shell's change notice
    shows it, so nothing is lost, but the screen that asked never says how it ended.
- **Why it matters:** this is iOS's version of Android R9, and the guard the in-app Back has does not apply.
- **Suggested fix:**
  - `blocksBackGesture(state.busy)` on every flow with a request in flight, and on transfer out while a transfer is open.
  - In transfer out, call `leave()` from `onDisappear` (it already rejects best effort).

#### R3. The app lock's timeout is measured on the wall clock: setting the clock back keeps the app open

- **Severity:** Public · **Status:** V · **Size:** S
- **Where:**
  - `VettIDData/Lock/AppLock.swift:340-350`: `backgroundAt = now()`, then
    `now().timeIntervalSince(at) >= Double(timeout.rawValue)`.
  - `now` is `Date()` (`:156`, defaulted in `App/Composition/AppComposition.swift:94-99`).
- **What happens:**
  - If the iPhone's date is moved back while VettID is in the background, the elapsed time is negative and the lock never
    engages on return, whatever the timeout.
  - The clock can be changed from Settings without the device passcode.
  - A clock moved forward has the opposite, harmless effect: an early lock.
- **Why it matters:** someone holding the unlocked iPhone after the timeout can bypass the app lock (ID17). The vault's
  own lock and owner check still apply.
- **Suggested fix:**
  - Measure on `ContinuousClock`, which counts while the device sleeps and cannot be set.
  - Also lock when the wall clock went backwards.
  - A process that died starts locked already (`AppLock.swift:193`).

#### R4. A stored device state that cannot be decoded leaves "VettID cannot connect" with only "Try again", for 7 days

- **Severity:** Public (a latent trap for every app update) · **Status:** V; the trigger is S · **Size:** S
- **Where:**
  - `VettIDVault/DeviceState.swift:7-41`: synthesized `Codable`. Non-optional fields with defaults (`seen`, `utks`,
    `outbox`, `signerSeen` and others) are required when decoding. The fields added later are optional by convention, as
    the comments say.
  - `VettIDVault/VaultDevice.swift:223-226` decodes it.
  - A `DecodingError` falls to `VaultFailures.map`'s default, `.other` with no code (`VaultFailures.swift:47`).
  - `refresh` turns only the code `keystore` into `.localState` (`VettIDData/Vault/VaultManager.swift:516-523`).
  - `WayOut.of(.other)` is nil until the 7-day long-unreachable rule (`VettIDOnboarding/StuckWays.swift:36-46`).
  - Compare `LocalAccount`, decoded field by field with `decodeIfPresent`
    (`VettIDData/Vault/AccountRecord.swift:148-167`).
- **What happens:** one non-optional field added to `DeviceState`, `VaultRecord`, `RecoveryRecord` or `OutboxEntry` in a
  later build makes every existing install undecodable after the update. The member sees "VettID cannot connect /
  Something went wrong. Try again." with no erase or recover offer for a week.
- **Why it matters:** testers update TestFlight builds in place, so this would lock out every tester who installs that
  build.
- **Suggested fix:**
  - Map a `DecodingError` of a stored file to `localState` (its erase way out).
  - Add a test that decodes a fixture of today's stored state with each new build.
  - Or decode with `decodeIfPresent` as `LocalAccount` does.

### Polish

| ID | Finding | Evidence | Fix | Status |
|---|---|---|---|---|
| R5 | A scanned invitation is accepted again whenever its accept screen is rebuilt. | The scanner puts the link in the route (`VettIDConnectionsUI/Screens/ConnectRoutes.swift:109`). `AcceptViewModel.init` accepts a non-opened input at once (`VettIDConnections/AcceptViewModel.swift:89`). The owner-check gate rebuilds the route (R1). | S: mark the route as accepted, or keep the model above the gate. | V/S |
| R6 | Countdowns count one-second ticks, not a deadline. | `VettIDOnboarding/UnlockViewModel.swift:424-439` (backoff and service wait), `RecoverViewModel` (`startRetryWait`), `VettIDSettings/TransferOutViewModel.swift:376-386`. A suspended app returns to a wait that is too long. Transfer in does use a deadline (`TransferInViewModel.swift:224-229`). | S: store the end instant. | V/S |
| R7 | The credential-required cover does not close every presentation, so it can sit hidden under a sheet. | The cover closes presentations that read `vettIDCovered` (`VettIDOnboardingUI/Screens/CredentialRequiredScreen.swift:45-52`). These do not: History's range and connection sheets (`VettIDHistoryUI/Screens/HistoryFilterRow.swift:44,51`), the Notifications detail sheet (`VettIDNotificationsUI/Screens/NotificationsScreen.swift:74`), the photo cover and share sheet (`ConversationScreen.swift:87`, `PhotoViewerScreen.swift:61`), the photo picker, the file importer and exporter, the finish-move sheet (`VettIDShellUI/MoveNotices.swift:65`, outside the covered subtree) and the canary alert. | S. | V/S |
| R8 | "Opening VettID" has no way out while the first read hangs. | `StartingScreen` is a spinner only (`VettIDOnboardingUI/Screens/UnreachableScreen.swift:167-171`); the phase stays `.starting` until `refresh` returns (`App/VettIDApp.swift:154`). How long that can take on a black-holed network is area 2's question. | S: after a bound, the stuck screen with "Try again". | S |
| R9 | The canary manifest dialog shows over any phase. | It is the root's alert (`VettIDSettingsUI/Screens/CanaryManifestDialog.swift:74-85`, `App/VettIDApp.swift:140`), so it shows over onboarding and the unlock. Only file URLs are taken, bounded, and the `Inbox` copy is removed (`App/CanaryManifestFiles.swift:15-19`). | S: hold it until the vault is open, as invitations are. | V |

### Checked and sound

- **The app lock.**
  - It covers sheets and alerts from a window of its own above the alert level and takes the keyboard
    (`App/AppLockGate.swift:117-169`).
  - The prompt is idempotent across `.inactive` and `.active` (`UnlockPromptGate`).
  - It counts only `.background`, never the in-process system pickers. Android R3 does not occur by design; checklist
    item 2.
  - An invalidated key turns the lock off with a notice and never locks the member out (`AppLock.swift:260-297`).
- **Scene phases.**
  - Typed PINs, passwords and pasted codes are dropped at `.background` and when protected data goes
    (`UnlockScreen.swift:143-150`, `TransferInScreen.swift:283-286`, `VettIDSettingsUI/Support/ForgetsSecrets.swift`).
  - Leaving the foreground finishes in-flight work under a bounded background task, cancelled at expiry
    (`App/VettIDApp.swift:239-255`).
  - A start before the first unlock reads again on `protectedDataDidBecomeAvailable`.
- **Re-entrancy.** Primary buttons ignore taps while busy (`VettIDUI/Components/Forms.swift:23,426-427`). Unlock, erase,
  the retry of the stuck screen and the vault-deletion checks guard their own state. Transfer in cancels its handshake
  when its screen goes (`TransferInScreen.swift:280,290-300`).
- **Opened links.**
  - URLs are bounded at 4096 bytes (`App/OpenedLinks.swift:15-24`).
  - Invitations wait for the open vault and a confirmation.
  - The setup-link inbox is cleared at a wipe (`App/Composition/AppComposition.swift:104-113`).
- **Wire formats.** Timestamps are built from a Gregorian UTC calendar with ASCII digits, or with `ISO8601DateFormatter`
  and the POSIX locale (`VettIDCrypto/Envelope/Ulid.swift:36-44`, `VettIDAltChan/MemberApiClient.swift:152-159`), so
  Android R2 is not here.
- **History export.** The system exporter writes the document from memory: no empty or half-written file is left
  (`VettIDHistoryUI/Screens/HistoryExportScreen.swift:275-286`).
- **Concurrency.** Classes marked `@unchecked Sendable` hold their state under a lock (`VettIDVault/Concurrency.swift`;
  `VaultDevice`'s reads go through `mem.withLock`, `VettIDVault/VaultDevice.swift:257-284`). The camera and QR delegates
  hop to the main actor on the main queue only. This was sampled, not exhaustive.
- **Wipe.** It is crash-safe, resumed at launch, and fail-secure (`WipeRun.swift`).

### Android A6 area 4 on the iPhone

| Android finding | iOS | Note |
|---|---|---|
| R1 root navigation rebuilds on recreation and unlock | not here | No recreation (portrait, no restoration); the app lock keeps the content (`AppLockGate.swift:28-33`). The gate and lock case is iOS R1. |
| R2 relay timestamp in the phone's locale | not here | `Ulid.swift:36-44`; `ISO8601DateFormatter`; POSIX `DateFormatter`. |
| R3 "Immediately" locks on rotation and system dialogs | not here | No rotation; lock only at `.background` (`AppLockGate.swift:43-51`). Checklist item 2. |
| R4 unsaved work dropped when the phase leaves Unlocked | same | iOS R1, with the owner-check gate as a further trigger. |
| R5 accept re-sent when rebuilt | same | iOS R5. |
| R6 deep-link input unbounded | not here | 4096-byte bound (`OpenedLinks.swift:15-24`). |
| R7 setup link queued while a vault exists | partly | Cleared at a wipe (`AppComposition.swift:104-113`); the silent ignore is in iOS E13. |
| R8 History export leaves broken files | not here | `fileExporter` from memory. |
| R9 transfer out cancels on any Back | same, via the swipe | iOS R2: the swipe skips the cancel and the busy guard. |
| R10 relaunch re-processes the intent | n/a | `onOpenURL` delivers each open once. |
| R11 notification actions from any app | n/a | Push is phase P (IOS-PLAN §6.7), not built. |
| R12 canary share target, any scheme, any phase | partly | File URLs only; any phase is iOS R9. |
| R13 countdowns count ticks | same | iOS R6. |
| R14 reveal state survives rotation and app lock | partly | `SecretField`'s show state is `@State` (`VettIDUI/Secure/SecretField.swift:44`) and survives the app lock, but the screens drop the value itself at `.background`. Not raised. |
| R15 forced theme misses the splash | not checked | Area 1. |
| R16 large screens, landscape | n/a | iPhone only, portrait (`Config/Base.xcconfig:8`, `project.yml:118`). |
| R17 invitation links lack an environment check | not checked | Area 5. |
| R18 date-picker values saveable | n/a | No state restoration. |
| R19 restored destination before the phase | n/a | No state restoration; `.starting` shows `StartingScreen`. |
| R20 translation readiness | n/a here | Areas 1 and 7. |

---

## Needs a real iPhone (areas 3 and 4)

1. **The owner-check deadline mid-edit (R1, E5, R5).**
   - With a short-deadline staging vault, open an item's editor, type changes, and wait for the deadline. Pass the check,
     then see what the editor shows.
   - Repeat with a message draft, and with a scanned invitation on the accept screen.
2. **App lock "Immediately" (R3, Android R3).**
   - Open the History export's "Save to…", the photo picker, the share sheet and Face ID. None should lock.
   - Contact support (Mail) should lock on return.
3. **The clock back (R3).** With the app lock at 1 minute, leave VettID for 2 minutes, set the date back a day in
   Settings, and return.
4. **The back swipe (R2).**
   - On Transfer out, swipe back while the code is shown. Check that the new phone still pairs, and what each phone shows.
   - Swipe back during "Move" with the approval sent.
   - Swipe back during a PIN change, and check the change notice.
5. **Transfer-in scan (E4).** Scan an expired transfer code and keep it in view for 10 s.
6. **Airplane mode (E1, E2, E6, R8).**
   - Unlock with the relay reachable, then cut the network.
   - Open Approvals, a connection's sharing, Tags, Shared with you, the new-message picker and a new conversation.
   - Pull to refresh Items and Messages with rows.
   - Cold-start on a network that drops packets and time "Opening VettID".
7. **A suspended countdown (R6).** Trigger an unlock backoff, background the app for its length, and return.
8. **The credential-required cover (R7).** With the Notifications detail sheet open, cause a `credential_required` refusal
   on the staging vault.
9. **An update of the app over an existing install (R4).** Install the previous TestFlight build, enrol, then install the
   current one over it and open.

---

## 5. Client security hygiene

**What the plan requires.** IOS-PLAN §6.1 (every key per vault, `ThisDeviceOnly`, never synchronizable, none bound to
biometry or the passcode except the app-lock key; state files `CompleteUntilFirstUserAuthentication` and excluded from
backups; a first-run cleanup of keychain leftovers), §6.4 (app-switcher cover, capture hiding, `SecureContainer`),
§6.5 (third-party keyboards refused, the PIN on an in-app keypad, no AutoFill or "Save Password?", copies local-only and
expiring), §6.8 (links), §6.9 (vault content in memory only; what is cleared at a lock, a hold and a wipe).

**What the code does.** This area is in better shape than Android's was at its audit: the two Android blockers (S1
Recents and capture, S2 keyboard learning on secret items) do not exist here. Keys, keychain classes, file protection,
backup exclusion, the keyboard refusal, the keypad, the privacy shield, the wipe and the release check all match the
plan. The gaps are one §6.9 rule that is not built (the clipboard at the vault lock), the setup Universal Link that is
not entitled, and the app lock's clock.

### Keys and storage (checked against §6.1 and §6.9)

| Item | Where | Class | Synchronizable | Bound to user auth |
|---|---|---|---|---|
| Generic keychain items (file key, wrapped seeds, records) | `Packages/VettIDKeys/Sources/VettIDKeys/Keychain.swift:33-41,72-82` | `AfterFirstUnlockThisDeviceOnly` or `WhenUnlockedThisDeviceOnly`, data-protection keychain | `false` on every item | No |
| Secure Enclave keys (app key, phone key, seed-wrap key) | `Packages/VettIDKeys/Sources/VettIDKeys/SecureEnclaveKeychain.swift:36-62` | the item's class through `SecAccessControl`, `.privateKeyUsage` only | n/a (Secure Enclave keys never sync) | No |
| App-lock key | `Packages/VettIDKeys/Sources/VettIDKeys/AppLockKeys.swift:88-95` | `WhenUnlockedThisDeviceOnly` | – | `.biometryCurrentSet` or `.devicePasscode` (the only one, as §6.1 allows) |
| State files | `Packages/VettIDKeys/Sources/VettIDKeys/EncryptedFileStore.swift:119-134,167-175` | `completeUntilFirstUserAuthentication`, mode 0600, atomic replace | directory `isExcludedFromBackup` | – |
| App directories | `App/AppDelegate.swift:22-33` | – | Application Support and Documents excluded from backup at every launch | – |
| UserDefaults | `Packages/VettIDData/Sources/VettIDData/Prefs/ThemeSetting.swift:28` | the theme only (`settings.theme`) | in backups, as §6.9 allows | – |

The erase (`App/Composition/AppWipeTargets.swift`, `Packages/VettIDKeys/Sources/VettIDKeys/Keychain.swift:96-145`)
deletes every keychain class the app can reach, synchronizable or not, then checks that nothing is left; it also clears
Caches, tmp, Documents, cookies, the preferences domain and the notifications. Every `URLSession` is ephemeral
(`App/Composition/AppComposition.swift:50`, `Packages/VettIDData/Sources/VettIDData/Vault/ReleaseLog.swift:207-214`).

### Blockers

None. Both candidates were read twice. The app switcher and capture are covered by the privacy shield on a window above
everything (`Packages/VettIDUI/Sources/VettIDUI/Secure/PrivacyShield.swift:36-108`), shown on `willDeactivate`, before
the snapshot. Secret item values are typed in fields that turn autocorrection, spell checking, inline predictions and
AutoFill off (`Packages/VettIDItems/Sources/VettIDItemsUI/Screens/ItemFieldEditors.swift:158-172`,
`Packages/VettIDUI/Sources/VettIDUI/Secure/SecretField.swift:17-31`). Whether the platform behaves as the code expects is
on the checklist in [Needs a real iPhone](#needs-a-real-iphone-areas-5-7-8).

### Public

### S1. A copied secret item value is not cleared at the vault lock

- **Severity:** Public. **Status:** V. **Size:** S.
- **Where:** `Packages/VettIDUI/Sources/VettIDUI/Secure/SecurePasteboard.swift:9-14`;
  `Packages/VettIDItems/Sources/VettIDItemsUI/Screens/ItemDetailScreen.swift:28`. Nothing reads `UIPasteboard.changeCount`
  or clears the pasteboard anywhere in `Packages/*/Sources` or `App/`.
- **What happens:** a copied value is local-only and expires after 60 seconds, as §6.5 asks. If the vault locks (the
  member's "Lock", the idle lock, the owner check's hold, a wipe) within those 60 seconds, the value stays on the
  pasteboard until its expiry.
- **Why it matters:** IOS-PLAN §6.9 (0.1.44, the "A copied secret item value" row) and §6.5 require it to be cleared at
  the vault lock, only if the pasteboard still holds the app's item. A lock is the moment the member expects nothing of
  the vault to be readable.
- **Suggested fix:** keep the `changeCount` after each `SecurePasteboard.copy`; on the phase leaving `.unlocked`
  (`VaultManager.swift:40` already calls `forgetOpenLists` there) clear the pasteboard if `changeCount` is unchanged.
  The copy happens in VettIDUI and the lock in VettIDData, so the hook belongs in the app's composition or the root.
  A unit test with a named pasteboard, as `Packages/VettIDUI/Tests/VettIDUITests/SecureInputTests.swift:105` does.

### S2. The setup Universal Link is handled but not entitled

- **Severity:** Public. **Status:** V. **Size:** S here, plus vettid.org work.
- **Where:** `project.yml:102-110` and `Config/VettID-production.entitlements` list only `applinks:relay.vettid.org`;
  the handler exists: `App/OpenedLinks.swift:18-24`, `Packages/VettIDAltChan/Sources/VettIDAltChan/SetupCodes.swift:56-73`,
  `Packages/VettIDOnboarding/Sources/VettIDOnboarding/OnboardingViewModel.swift:261-273`.
- **What happens:** IOS-PLAN §6.8 names `https://account.vettid.org/vault/enroll/…` (staging:
  `account.staging.vettid.org`) as a Universal Link. Without the associated domain, the portal's "open on this phone"
  link opens in Safari; a member enrolling on the same iPhone must type the setup code.
- **Why it matters:** the same-device path the portal offers does not work on iOS; the typed code still does, so nobody
  is stuck. When it is added, Android's S11 applies as written: `receiveLink` redeems at once on the welcome screen
  (`OnboardingViewModel.swift:262-273`), so a web page could start a setup with its own secret; the masked-email confirm
  is the only barrier.
- **Suggested fix:** `applinks:account.vettid.org` (Release) and `applinks:account.staging.vettid.org` (Staging, Debug)
  per configuration, the `apple-app-site-association` on the account sites (IOS-PLAN §9.2), and a "Use this setup
  link?" step before the redeem. The release check should assert each configuration's domains (S9).

### S3. The app-lock timeout uses the wall clock

- **Severity:** Public. **Status:** V. **Size:** S.
- **Where:** `Packages/VettIDData/Sources/VettIDData/Lock/AppLock.swift:156` (`now = { Date() }`), used at `:340-350`.
- **What happens:** the time spent in the background is `Date()` on return minus `Date()` on leaving. Setting the clock
  back while VettID is in the background keeps the app unlocked past the timeout.
- **Why it matters:** the same as Android S6: it needs the unlocked iPhone in hand, which is what the app lock is for.
  The screenshot allowance already uses a clock that runs during sleep (`Lock/ScreenshotAllowance.swift:64-69`).
- **Suggested fix:** `ContinuousClock` (or `clock_gettime_nsec_np(CLOCK_MONOTONIC)`, as `VaultDevice.monotonicNow`
  does), injected as now, so the existing `AppLockTests` keep their fake clock.

### Polish

### S4. The system's Copy goes around `SecurePasteboard`

- **Severity:** Polish. **Status:** V/S. **Size:** S.
- **Where:** single-line secret fields are plain `UITextField`s with no `canPerformAction` override
  (`Packages/VettIDUI/Sources/VettIDUI/Secure/SecretField.swift:186-215`), unlike the multi-line editor
  (`SecretTextEditor.swift:162-181`, copy and cut removed). The invitation link is `.textSelection(.enabled)`
  (`Packages/VettIDConnections/Sources/VettIDConnectionsUI/Screens/InviteScreen.swift:174-182`).
- **What happens:** with the password shown, or in a visible secret field (an item's secret value, a setup or transfer
  code), the edit menu offers Copy and Cut. That copy goes to the general pasteboard with no expiry and onto Universal
  Clipboard (the member's other Apple devices), which IOS-PLAN §6.5 rules out ("local-only and expiring").
- **Suggested fix:** a `UITextField` subclass that removes `copy:` and `cut:` (keep paste), as the editor does; drop
  `.textSelection` on the invite link (its Copy button already uses `SecurePasteboard`).

### S5. The app lock is turned off without a prompt

- **Severity:** Polish. **Status:** V. **Size:** S.
- **Where:** `Packages/VettIDSettings/Sources/VettIDSettings/SettingsViewModel.swift:135-143` ("off needs no prompt").
- **What happens:** as Android S12. The lock is a UI gate only by design (IOS-PLAN §6.9, ID17), so this only matters
  for someone who has the open app in hand; asking for Face ID or the passcode to turn it off costs one prompt.
- **Suggested fix:** one `UserPresence` prompt before `disable()`.

### S6. "Reveal" is ungated on an iPhone with no passcode

- **Severity:** Polish. **Status:** V. **Size:** S.
- **Where:** `Packages/VettIDUI/Sources/VettIDUI/Secure/UserPresence.swift:20` returns true when
  `deviceOwnerAuthentication` cannot be evaluated.
- **What happens:** as Android S13. A one-time hint ("Set a passcode to protect revealed items") would explain it.

### S7. Shared-with-you shows `password` and `otp` values unmasked

- **Severity:** Polish. **Status:** V. **Size:** S.
- **Where:** `Packages/VettIDItems/Sources/VettIDItemsUI/Screens/SharedWithYouScreen.swift:218-246` (plain `Text` for every
  kind); the block sits in a `SecureContainer` (`:185`), so captures are covered, but anyone looking is not.
- **Suggested fix:** mask by `FieldKinds.masked`, with the eye, as the item screen does
  (`ItemDetailParts.swift:65-84`).

### S8. VettID is offered for every JSON file

- **Severity:** Polish. **Status:** V. **Size:** S.
- **Where:** `project.yml:83-91` (`public.json`, rank Alternate, every configuration); `App/CanaryManifestFiles.swift`.
- **What happens:** as Android S10. The handling is careful (bounded read, the Inbox copy removed, nothing installed
  without a confirm, a launch sweep), but every member sees VettID under "Open with" for JSON. Only canary phones need it.
- **Suggested fix:** keep it, or a custom UTI the release tooling exports (`org.vettid.release-manifest`, extension
  `.vettidmanifest`) so ordinary JSON files are not offered to VettID.

### S9. The release check does not assert the shipping Info.plist and entitlements

- **Severity:** Polish. **Status:** V. **Size:** S.
- **Where:** `scripts/release-check.sh:103-128` (strings, bundle id), `:219-233` (App Attest environment only).
- **What happens:** the check is far stronger than Android's (TEST markers in every object, linked products, schemes,
  simulator-only targets, a self-test of each rule). It does not assert: no `NSAppTransportSecurity` key in the
  shipping app, the exact `CFBundleURLTypes` and associated domains per configuration (S2), the usage-description keys,
  `ITSAppUsesNonExemptEncryption`, the app icon and the privacy manifest (G1, G2). Today's wiring is right; a regression
  would pass CI.
- **Suggested fix:** read the archived app's `Info.plist` with `plutil` and compare the security-relevant keys to an
  expected set per configuration; add a self-test plant for each.

### Noted, no recommendation

- No certificate pinning: trust comes from the Nitro attestation, the pinned manifest keys and App Attest (IOS-PLAN
  §6.2), as on Android (S21). No jailbreak or debugger detection (not useful against the threat model).
- PINs and passwords become `String`s at the vault manager's API (`PinBuffer.take()`,
  `Packages/VettIDUI/Sources/VettIDUI/Secure/PinKeypad.swift:50-55`); the keypad buffer itself is zeroed. The owner check
  keeps the unlock's PIN only for a password-only retry and drops it on leaving the front
  (`Packages/VettIDData/Sources/VettIDData/Vault/OwnerCheckManager+UnlockPin.swift:13-28`), per VAULT-MESSAGING §3.6.5.

### Secret fields and the keyboard

| Field | Component | Keyboard | AutoFill content type | Autocorrect, spelling, predictions | Copy out |
|---|---|---|---|---|---|
| Vault PIN | `PinKeypad` (`Secure/PinKeypad.swift`) | none (in-app keypad) | – | – | – |
| Credential password (every screen) | `SecretField` | ASCII, secure, show/hide | empty type | off | **when shown (S4)** |
| Typed recovery code, transfer code | `SecretTextEditor`, paste only | ASCII | empty type | off | removed |
| Setup code, item secret values (`otp`, secret and critical items) | `VisibleSecretField` | ASCII or digit pads | empty type | off | **yes (S4)** |
| Secret and critical items' notes, multi-line values | `SecretTextEditor` | ASCII | empty type | off | removed |
| Ordinary item text, names, messages | SwiftUI `TextField` | default | empty type on item fields | on (not secret) | yes |

Third-party keyboards are refused app-wide (`App/AppDelegate.swift:15-20`). While the app lock shows, the content is
hidden, takes no touches and loses the keyboard (`App/AppLockGate.swift:25-31,53-58`).

### What stays on the phone

| Event | Vault content in memory | Files and keychain | Pasteboard | Notifications |
|---|---|---|---|---|
| Vault lock, hold | Cleared (`VaultManager.swift:40-41`, `VaultManager+Activity.swift:68-75`) | Transport state only | **Kept up to 60 s (S1)** | None posted before phase P |
| "Delete vault" | Through the wipe once the vault confirms (`VaultManager+Delete.swift:123-128`) | Erased | as above | Removed |
| Wipe, erase this phone | Cleared (`VaultManager+Wipe.swift:65-104`) | Every keychain item and key, the data directory, Caches, tmp, Documents, cookies, the preferences domain; crash-safe marker | as above | Removed |
| Uninstall | – | Files go; keychain items survive and are deleted by the first-run cleanup (`Packages/VettIDKeys/Sources/VettIDKeys/FirstRunCleanup.swift`) | – | – |

### Checked and sound

- **Logging:** no `Logger`, `os_log`, `print` or `NSLog` in `App/` or `Packages/*/Sources`. Precondition messages carry
  no data.
- **Debug-only code:** `App/Debug/*` is wholly inside `#if DEBUG`; `AppDevStack/DevStackWiring.swift` refuses to compile
  outside the dev-stack app; the `*Testing` products are linked only by test targets and `VettIDDevStack`; the release
  check proves all three on the Release and Staging archives.
- **ATS:** the shipping target declares no exception; only the simulator-only dev-stack app allows local networking
  (`project.yml:175-177`).
- **Links:** opened URLs are length-bounded and routed to an invitation, a setup link or a file
  (`App/OpenedLinks.swift`); nothing is sent before a confirm. Message links are `https://` only, after "Open link to
  <host>?" with the host in ASCII form (`Packages/VettIDData/Sources/VettIDData/Social/MessageLinks.swift`). No WebView.
- **No state restoration, `@SceneStorage`, `@AppStorage`, `NSUserActivity`, Spotlight or widgets** that could carry content.
- **History export** writes only where the member chooses (`fileExporter`), from memory
  (`Packages/VettIDHistory/Sources/VettIDHistoryUI/Screens/HistoryExportScreen.swift:257-300`); a saved photo uses the
  add-only permission after the warning.
- **"Allow screenshots"** is memory-only, ends at the lock and after an hour on a clock that runs during sleep, and is
  off by default in Staging and Release (`App/AppEnvironment.swift:16`).

### Android A6 area 5 against the iPhone app

| Android finding | iOS | Note |
|---|---|---|
| S1 Recents, screenshots, recordings | not here | Privacy shield on `willDeactivate`, capture hiding on `sceneCaptureState` (`Secure/PrivacyShield.swift:56-108`); `SecureContainer` on secret screens. Phone check 1–3. |
| S2 Autocorrect on secret items | not here | `ItemFieldEditors.swift:158-172`; notes `ItemEditSections.swift:252-280`. Phone check 5. |
| S3 Copy copies the TOTP seed | not here | Copy gives the current code; the seed only when shown (`ItemDetailParts.swift:85-97,133`). |
| S4 Clipboard hygiene | partly | Every copy is local-only and expiring, the transfer and invite links too; not cleared at the lock (S1); system Copy (S4). |
| S5 "Delete vault" not a wipe | not here | `VaultManager+Delete.swift:123-128` runs the wipe. |
| S6 Wall-clock app-lock timeout | same | S3. |
| S7 Prompt skips the timeout | not here | Only the unlock (already locked) and the method change (a cancelled prompt turns the lock off, `AppLock.swift:241-247`) set `authenticating`; other prompts do not. |
| S8 Tapjacking | n/a | iOS has no overlays from other apps. |
| S9 Release checks leave gaps | partly | S9; the iOS check covers objects, products, schemes and entitlements. |
| S10 Canary share target for every member | same | S8. |
| S11 Setup link redeemed on arrival | not reachable today | Same code shape; becomes live with S2. |
| S12 App lock off without auth | same | S5. |
| S13 Reveal ungated without screen lock | same | S6. |
| S14 Shared-with-you unmasked | same | S7. |
| S15 Visible secret field allows copy | same, wider | S4 (Universal Clipboard). |
| S16 Log line with relay text | not here | No logging at all. |
| S17 Wipe leftovers | not here | Notifications, caches, tmp, Documents, cookies and the preferences domain are cleared; only the in-memory theme choice outlives a wipe until restart. |
| S18 Profile and History after lock | not here | `VaultManager.swift:40-41`. |
| S19 Invitation link as route argument | n/a | No saved navigation state. |
| S20 External links unguarded | not here | SwiftUI `openURL` does not throw; message links confirmed. |
| S21 No pinning, root check | same | Noted above. |

---

---

## 6. Performance and battery

**What the code does.** Vault, relay and crypto work runs in `nonisolated` async code off the main actor (Swift 6
language mode, `SWIFT_STRICT_CONCURRENCY = complete`, `Config/Base.xcconfig:9-10`; no
`NonisolatedNonsendingByDefault`). Sessions are made off the main actor (`VaultManager.swift:387-415`). Photos for
sending and received photos are prepared and decoded in detached tasks (`Attachments.swift:87-91`,
`PhotoParts.swift:124-150`). The photo caches are bounded (`Attachments.swift:23-28`). Nothing runs in the background
beyond the 25 s task at departure: no `BGTaskScheduler` and no background push yet (push is phase P). The findings are
the collection mode, the device's state writes, a few main-thread reads and decodes, and the per-connection reads of
Messages.

| ID | Sev. | Finding | Evidence | Effect | Fix | Status |
|---|---|---|---|---|---|---|
| P1 | Polish | While the app is open, the relay is polled every ≤ 25 s instead of the WebSocket that IOS-PLAN §6.6 names. | `collectMode: .longPoll` by default (`VaultManagerConfig.swift:204`; `DeviceConfig` `VaultDevice.swift:69`). The WebSocket path exists (`RelayStream.swift:14-77`) and nothing selects it. Each collected message is acked with its own `DELETE` (`RelayStream.swift:195-198`). | About 144 signed HTTPS requests an hour in the foreground, each answer delayed by a round trip, and one more request per message. Small, because collection stops in the background (`VaultManager+Events.swift:121-124`). | M: `.webSocket` (acks over the socket, long-poll fallback built in). | V; cost S |
| P2 | Polish | The device's whole state is encrypted and written with two `fsync`s two or three times per request, not coalesced, and it grows with 16 days of seen ids. | `save()` encodes all of `DeviceState` (`VaultDevice.swift:336-350`), including `seen` and `seenInner`, each kept 16 days (`DeviceState.swift:14-17`, `VaultDevice+Receive.swift:13-16,87-91`). Saves happen in `sendLocked` (`VaultDevice+Send.swift:78`), after the deposit (`:90`), and per incoming message (`VaultDevice+Receive.swift:33`). Each save is a keychain read with no cache (`Keychain.swift:158-180`), AES-GCM, a directory check and `setResourceValues`, a write, and `fsync` of the file and of the directory (`EncryptedFileStore.swift:65-70,167-197`). VAULT-MESSAGING §8.3: "Flushes SHOULD be coalesced over a window of about 100 ms. Devices apply the same rule to their local storage." | Computed, for 300 vault messages a day: about 2 × 4,800 entries ≈ 0.4 MB of JSON, rewritten about 3 times per request. An unlock that reads 20–40 lists writes tens of MB and makes over a hundred `fsync`s, under the device lock (N2). | M: coalesce saves over about 100 ms (the ack still after the save); cache the file key in memory; keep the seen-id sets in a compact or separate file. | V; sizes C; cost S |
| P3 | Polish | Messages reads one page per connection and marks read one message per request, one after the other. | `refreshConversations` and `refreshConversationsQuietly` loop over the active connections (`MessagesManager.swift:108-131`). `markRead` sends one `message.read` per unread message (`:204-221`). The unlock's list reads are sequential (`VaultManager+Features.swift:115-131`). Older pages can be read (`loadOlder`, `:149-166`), unlike vettid-android P5. | 30 connections are 30 sequential round trips through the relay before the list is complete. A conversation with 50 unread messages makes 50 requests. | M, needs the spec: a summary call, or a batch `message.read{up_to}`. Meanwhile, two or three requests in flight. | V |
| P4 | Polish | Profile photos are decoded on the main thread inside list rows, uncached, each time the row is drawn. | `ProfilePhotos.decode(c.photo)` in row bodies: `ConnectionsScreen.swift:135`, `MessagesScreen.swift:118`, `NewMessageScreen.swift:62`, `FeedRows.swift:182`, `ConnectionDetailScreen.swift:187`. Each call is a base64 decode plus an ImageIO thumbnail with `ShouldCacheImmediately` (`ProfilePhotos.swift:25-60`). A `decoded` async variant exists and is used only by the shell and the profile (`AppShell.swift:270`, `SharedProfileScreen.swift:331`). The open app is wrapped in a 15 s `TimelineView` whose date is passed down into `AppShell` (`App/VettIDApp.swift:332-336`), which may re-draw the visible rows every 15 s. | Scroll hitches with many photos; repeated decoding. | S: decode once per distinct photo off the main actor (a small memo keyed by the base64's hash) and pass the image down. Read the 15 s tick only where the gate needs it. | V; frame cost S |
| P5 | Public | The device keeps the last 500 vault events in memory for the life of the process, also after the vault is locked. | `publish` appends every event to `inbox` (`VaultDevice+Send.swift:248-257`). Only `awaitEvent` ever removes one (`:232`), with the cap at `VaultDevice.swift:115`. Nothing clears it at the lock, the hold or `halt()` (`VaultDevice.swift:487-502`). It includes `message.new` with the text, feed events and approval details. | Memory (up to 500 messages of up to 16 KiB). Message text stays in process memory after the lock, against IOS-PLAN §6.9 "cleared at the vault lock" and `MessagesManager`'s own rule. Also relevant to area 5. | S: keep in the inbox only the types some wait asks for (`vault.enrolled`, `device.paired`, `device.pair.rejected`, `device.transfer.pending`, …), or clear it at the lock and the hold. | V |
| P6 | Polish | Start-up reads several encrypted files and keychain items on the main thread. | `AppComposition` and `VaultManager` are `@MainActor`. `refresh()` → `prepared()` calls `record.load()`, `ownerChecks.loadIfNeeded()`, `canary.loadIfNeeded()` and `lockGuard.keeper.resume()` (`VaultManager.swift:295-310`), then `phoneSecrets.inUse` (`:542`). Each is a `SecItemCopyMatching`, a read and an AES-GCM open, with no key cache (`Keychain.swift:158-180`). Failures are thrown and shown as "the phone's stored state", so there is no crash path (unlike vettid-android P3). | Some tens of ms on the first frame after launch. | S: cache the file key in memory after first use; load the records in a detached task. | V; cost S |
| P7 | Polish | Non-lazy lists inside scroll views. | `ConnectionSharingScreen.swift`, `SharedWithYouScreen.swift`, `ApprovalFacts.swift`, `ItemDetailScreen.swift` (`ForEach` without a lazy stack). Bounded by the vault's limits. | – | Leave for now. | V |

### Android A6 area 6 on the iPhone

| Android finding | iOS | Note |
|---|---|---|
| P1 25 s long poll all day | not here (all day); see **P1** | The collection stops 25 s after leaving the foreground (`VaultManager+Events.swift:95-124`). In the foreground it is still the long poll. |
| P2 `startForeground` crash | n/a | iOS has no foreground service. |
| P3 keystore and file read on the main thread at start | same, **P6** | Smaller: no crash path. |
| P4 corrupt preferences leave "Starting…" for good | not here | A lock settings file that fails gives way to the root screen (`AppComposition.swift:131-143`). A corrupt record is "stored state" with the erase (`VaultManager.swift:516-519`). |
| P5 one round trip per connection; no older messages | same in part, **P3** | Older pages can be read (`MessagesManager.swift:149-166`). |
| P6 photos decoded on the main thread in rows | same, **P4** | |
| P7 app-lock key operations on the main thread | not here | The Secure Enclave open is `async` (`AppLock.swift:242,281`). |
| P8 baseline profile | n/a | Android-only. |
| P9 size trimmings | not measured | No archive was built for this audit. |
| P10 non-lazy lists | same, **P7** | |

### Checked and sound

- No blocking waits on the main actor. Every `while` loop in the UI and data layers sleeps or awaits, and stops with its task or owner (`Following.swift`, `LockKeeper.swift:487-500`, `VaultDeletion.swift:137-150`, `UnlockViewModel.swift:67-80`).
- The 1 s `TimelineView`s live only on screens with a visible countdown (TOTP, approvals, invite, export, password).
- The background task has a hard budget and is always ended.
- Photo caches are bounded and wiped. Photos are decoded off the main actor with a size cap and downsampled to the display edge (`PhotoParts.swift:124-150`, `ProfilePhotos.swift:52-58`).
- Attachment fetches are limited to 2 at once (`Attachments.swift:31,43`).
- Lists use `LazyVStack` with stable ids on Connections, Messages, the conversation, Items, Tags, History and Approvals.

### Polling loops (iPhone)

| Where | Interval | Stops in the background |
|---|---|---|
| Mailbox collector | 25 s long poll | Yes, 25 s after leaving the foreground |
| Pending lock retries | 1, 2, 5, 10 s, then 30 s × 4, then 60 s | Suspended with the app; resumed at the next start |
| Unresolved change recheck | 30 s, doubling to 300 s | Suspended with the app |
| Vault-being-deleted reads | 5, 15, 45 s, then every 60 s | Suspended with the app |
| Owner-check gate / release banner | 15 s / 60 s `TimelineView` | Yes |
| Unlock screen recheck | 15 s | Leaves with the screen |
| Countdown tickers (transfer in and out, backoffs) | 1 s | End at their deadline |
| Member-API slot poll | 0.6 s | No deadline but the slot's TTL (N3) |

---

## Needs a real iPhone (areas 2 and 6)

1. **Clone alarm (N1). Use a test vault.**
   1. With airplane mode on, open a critical item with the password. Expect the error.
   2. Turn Wi-Fi on from Settings without switching back to VettID, or walk back into coverage.
   3. Return to VettID and open the item again. It works.
   4. Within 10 minutes, send VettID to the background and bring it back.
   5. A `credential.alarm` or "frozen" confirms N1. Repeat with a relay 5xx if a staging switch exists.
2. **Duplicate message (N1).** Airplane mode on, send "test 1", wait for the error. Airplane mode off, send "test 1" again, then background and foreground the app. Count the copies on the peer.
3. **Stalled link (N2).** Use a Network Link Conditioner profile with 100 % loss and no reset. Send a message, and meanwhile have the peer send one. Time the spinner and note whether incoming messages wait for it.
4. **Cold vault (N3).** Unlock first thing after the vault was idle overnight. Time the keypad's busy state and note any text.
5. **Wrong clock (N4).** Turn automatic time off. For +2 min, −10 min and +1 day: unlock, open Messages, send, scan a transfer code. Write down each text.
6. **Wake and switch (N5).** Lock the phone for 10 minutes, unlock it and tap Lock vault or unlock at once. Then do the same while switching from Wi-Fi to cellular. Note any "could not reach" on the first try.
7. **Start offline (N5).** Start the app with airplane mode on. Turn it off from Control Center and return. Note whether "cannot connect" stays until Try again.
8. **Auto-lock (N9).** With a 30 s auto-lock, start a transfer on the new phone and let the screen lock during the comparison. Note what is shown after unlocking.
9. **Performance (P2, P4, P6).** Instruments:
   - Time Profiler at launch: the main thread before the first frame.
   - File Activity during an unlock: writes and `fsync`s of the device file.
   - Core Animation while scrolling Connections and Messages, with 20 photo connections.
10. **Memory after lock (P5).** Receive a few messages, lock the vault, then take a memory graph and search for a message's text.

---

## 7. App Store and TestFlight readiness

Policy statements are from Apple's published rules as known at the audited commit. **Verify each in App Store Connect**
(an Organizer "Validate App" of a Staging archive answers G1, G2 and G8 at once).

**Build facts:** iPhone only (`TARGETED_DEVICE_FAMILY = 1`), portrait, iOS 17.0 minimum, Swift 6 with warnings as errors.
Staging is `com.vettid.app.staging`, display name "VettID Staging", archived by the `VettIDStagingUITests` scheme
(`project.yml`, archive config Staging). Entitlements in every configuration: App Attest `production`,
`applinks:relay.vettid.org`. No push entitlement, no keychain access group, no background mode. Third-party code:
swift-sodium with libsodium as a binary xcframework, PhoneNumberKit, swift-certificates, swift-asn1, swift-crypto (each
with its own privacy manifest except swift-sodium), vendored mlkem-native. No analytics, crash reporting or advertising
SDK.

### Blockers

These two do not fit the harm-based definition (no data loss or leak). They are marked Blocker because without them
App Store Connect refuses the upload, so no TestFlight build can reach the owner or the testers, which is IOS-PLAN
§8 I4's exit.

### G1. The app has no icon

- **Severity:** Blocker (TestFlight gate). **Status:** V (absence); the refusal is S until a Validate run. **Size:** S
  (plus the artwork).
- **Where:** `VettID.xcodeproj/project.pbxproj:1008` sets `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, but there is
  no asset catalog in `App/` at all; the only one is VettIDUI's `Brand.xcassets` (a package resource bundle, which iOS
  never reads an app icon from).
- **What happens:** the app shows a blank icon on the Home Screen; App Store Connect refuses an upload without an icon
  (a missing 1024-pixel marketing icon and `CFBundleIconName`).
- **Suggested fix:** `App/Assets.xcassets` with an `AppIcon` set (one 1024×1024 image, plus dark and tinted variants
  from the rook), added to `project.yml` sources; a distinct icon or badge for Staging and Debug helps testers tell them
  apart. The release check should require `CFBundleIconName` (S9).

### G2. No privacy manifest, while required-reason APIs are used

- **Severity:** Blocker (TestFlight gate). **Status:** V (absence and the API uses); the refusal is S until a Validate
  run. **Size:** S.
- **Where:** no `PrivacyInfo.xcprivacy` in the repository. Uses: `UserDefaults`
  (`Packages/VettIDData/Sources/VettIDData/Prefs/ThemeSetting.swift:37,46`, `App/Composition/AppWipeTargets.swift:34-37`);
  file timestamps and metadata (`fstat`, `Packages/VettIDKeys/Sources/VettIDKeys/EncryptedFileStore.swift:153-154`;
  `contentModificationDateKey`, `App/CanaryManifestFiles.swift:34-36`).
- **What happens:** since May 2024 App Store Connect refuses uploads whose code uses a required-reason API without a
  declared reason. `clock_gettime_nsec_np(CLOCK_MONOTONIC)` and `ContinuousClock` are not on Apple's list (it names
  `systemUptime` and `mach_absolute_time`); confirm with the Validate run.
- **Suggested fix:** `App/PrivacyInfo.xcprivacy` with `NSPrivacyTracking` false, no tracking domains,
  `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1`, `NSPrivacyAccessedAPICategoryFileTimestamp` reason
  `C617.1`, and the collected data types that match the App Privacy answers below.

### Public

### G3. `ITSAppUsesNonExemptEncryption = NO` is doubtful for this app

- **Severity:** Public. **Status:** V (the value); the right answer needs advice. **Size:** S.
- **Where:** `project.yml:119` (and `:193`).
- **What happens:** the key tells App Store Connect the app uses no non-exempt encryption, so no export question is
  asked per build. The app implements its own end-to-end encryption (libsodium, ML-KEM, HPKE, X-Wing in
  `Packages/VettIDCrypto`) for messages and vault content, beyond HTTPS and Apple's own frameworks.
- **Why it matters:** a wrong declaration is the developer's legal statement; it also decides whether the French
  encryption declaration applies. Android's audit reached the same point ("take advice on the export question").
- **Suggested fix:** take advice; most end-to-end messaging apps answer that they use encryption and qualify for the
  mass-market exemption, then set the key accordingly (and keep the classification on file).

### G4. User content without block or report for an established connection

- **Severity:** Public. **Status:** V. **Size:** S–M.
- **Where:** `ConnectionsManager.block(_:)` exists (`Packages/VettIDData/Sources/VettIDData/Social/ConnectionsManager.swift:254`)
  but no screen calls it; Block exists only for a connection request (`InviteViewModel.swift:182`,
  `ApprovalDetailViewModel.swift:292`). No "report" text exists.
- **Why it matters:** App Review guideline 1.2 asks apps with user-generated content (messages, names, photos) for a
  way to block abusive users and to report content, and published contact information. The same as Android G4.
- **Suggested fix:** Block on the connection screen (the vault already supports it); "Report" as a link to the contact
  page with the connection's fingerprint, and a sentence in the review notes on why there is no server-side moderation
  (end-to-end encryption).

### G5. Account deletion is not named in the app

- **Severity:** Public. **Status:** V. **Size:** S here, plus the web page.
- **Where:** "Delete vault" (`Packages/VettIDSettings/Sources/VettIDSettingsUI/Support/SecurityStrings.swift:111-173`)
  deletes the vault; the account (email, membership) lives on the account site, reached by "Open account portal"
  (`Packages/VettIDShell/Sources/VettIDShellUI/Support/ShellStrings.swift:141`).
- **Why it matters:** guideline 5.1.1(v) requires apps that support account creation to let members start account
  deletion in the app. Accounts are created on the portal, so this may not strictly apply, but reviewers regularly ask.
- **Suggested fix:** a "Delete your VettID account" row that explains vault versus account and opens the portal's
  deletion page; mention it in the review notes.

### G6. No privacy policy in the app and no third-party notices

- **Severity:** Public. **Status:** V. **Size:** S–M.
- **Where:** Help has About, Security, the iPhone's Privacy and Keyboards texts and Contact
  (`Packages/VettIDSettings/Sources/VettIDSettingsUI/Screens/HelpScreen.swift:26-35`); no privacy policy link. The font
  licences are bundled (`Packages/VettIDUI/Sources/VettIDUI/Resources/Fonts/*.txt`) but never shown; there is no
  notices screen for libsodium (ISC), PhoneNumberKit (MIT), swift-certificates, swift-asn1, swift-crypto (Apache-2.0)
  and mlkem-native.
- **Why it matters:** guideline 5.1.1(i) asks for a privacy policy link in App Store Connect and inside the app; the
  MIT, ISC and Apache licences ask for their notices in distributed copies. The app itself is AGPL-3.0 (`LICENSE`): take
  advice on App Store distribution of AGPL code that has contributors other than the owner.
- **Suggested fix:** a "Privacy policy" row in Help, and a static "Licences" screen generated from the resolved packages
  at build time.

### G7. Review access needs a plan

- **Severity:** Public. **Status:** V. **Size:** – (process).
- **Where:** before enrolment only Welcome, setup, recovery and transfer-in are reachable; a setup code is single use.
- **What happens:** TestFlight external testing goes through Beta App Review, and the App Store through App Review;
  both need sign-in information. Per spec, the vault accepts the App Attest attestation only for an App ID its release
  pins (IOS-PLAN §6.2, VA2 for `com.vettid.app.staging`); a reviewer's iPhone produces a real production attestation,
  so that works once the staging image pins the Staging App ID.
- **Suggested fix:** a reviewer membership on staging, a fresh setup code issued for each review (ENROLLMENT-CODES §3),
  written steps (code, PIN rules, the password), and a note that Staging shows "1 day = 1 hour" (STAGING-TIME-SCALE §5.2).

### G8. The build number is fixed at 1

- **Severity:** Public. **Status:** V. **Size:** S.
- **Where:** `project.yml:128` (`CURRENT_PROJECT_VERSION: 1`), the same for every configuration.
- **What happens:** App Store Connect refuses a second upload with the same version and build number, so the second
  TestFlight build fails until someone edits `project.yml`.
- **Suggested fix:** derive it at archive time (`agvtool` or `CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD)` on
  the `xcodebuild archive` line), and keep `MARKETING_VERSION` in `project.yml`.

### G9. Mac ("Designed for iPhone") and Vision Pro availability is on

- **Severity:** Public. **Status:** V/S. **Size:** S.
- **Where:** the shipping `VettID` target does not set `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD` or
  `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD` (`project.yml:68-130`); the dev-stack target sets both to NO (`:184-188`).
- **What happens:** by default an iPhone app is offered on Apple silicon Macs and Vision Pro. There App Attest is not
  available (`isSupported` false), so setup is refused (IOS-PLAN §6.2), and a TestFlight tester on a Mac gets an app
  that cannot enrol.
- **Suggested fix:** set both to NO for the VettID target (or opt out in App Store Connect for each app record).

### App Privacy answers implied by the code

| Data | Sent to | End to end (app and the member's enclave) |
|---|---|---|
| Email (typed with the setup code) | Member API | No (TLS) |
| Names, profile photo | The vault; shared with connections the member chooses | Yes |
| Messages, photos, vault items, tags, share rules | The vault, connections | Yes |
| PIN, credential password | The enclave, sealed to its attested key | Yes |
| Device model (`UIDevice.current.model`, "iPhone") | The vault's device list | Yes |
| App Attest attestation and assertions (no device identifier beyond the key id) | The enclave; Apple during attestation (IOS-PLAN ID18) | TLS |
| App key id, vault id, timestamp, nonce on member-API requests | Member API | No (TLS) |
| Mailbox id, request timing, IP address | Relay | – |
| Diagnostics, crash logs, analytics, advertising identifier, `identifierForVendor` | None | – |
| Camera frames, Face ID | On the phone only | – |

Other answers: no tracking; no ads; user-to-user messaging; the camera, photo add-only and Face ID usage strings are
present and accurate (`project.yml:123-126`); no notification permission is asked before phase P (none is requested
anywhere). Whether end-to-end encrypted data held in an enclave the developer operates counts as "collected" is the
owner's call; Apple's definitions turn on whether the developer can access it.

### TestFlight setup (not findings; a list for the owner)

1. An App Store Connect record for `com.vettid.app.staging` (name "VettID Staging" or similar, never submitted for
   sale), with the App Attest and Associated Domains capabilities on its App ID.
2. Test information: description, feedback email, contact, sign-in information (G7), privacy policy URL.
3. Each upload: Staging archive through the `VettIDStagingUITests` scheme, a new build number (G8), Validate first.

### Android A6 area 7 against the iPhone app

| Android finding | iOS | Note |
|---|---|---|
| G1 Scanner crash without a back camera | not here | `Packages/VettIDUI/Sources/VettIDUI/Components/QrScanner.swift:46-48` falls back to the front camera or any camera; the Mac case is G9. |
| G2 Camera permission without a settings link | not here | `Packages/VettIDOnboarding/Sources/VettIDOnboardingUI/Scanner/ScannerBox.swift:53-56` offers Settings and "type instead". |
| G3 `specialUse` foreground service | n/a | No background mode on iOS (IOS-PLAN §6.6). |
| G4 No block or report | same | G4. |
| G5 Account deletion not named | same | G5. |
| G6 Privacy policy, licences | same | G6. |
| G7 App access for review | same | G7. |
| G8, G9 F-Droid | n/a | |
| G10 Notification permission without a sentence | n/a | No notification permission is requested before phase P. |
| G11 Lint warnings | not here | `swiftlint lint --strict` in CI over every source directory; warnings are errors (`Config/Base.xcconfig:11-12`). |
| G12 Relay App Link unverified | same, per spec | The relay serves its `apple-app-site-association` (RELAY-PROTOCOL §6.11); until then invitations open the browser (`project.yml:102-106`). The account host is S2. |

---

## 8. Tests

About 3,160 test functions in 311 files (Swift Testing and XCTest; parameterized tests count once), plus 25 UI tests.
VettIDData alone has 1,424, with about 45 `VaultManager*Tests` files covering enrolment, unlock, lock, wipe, transfer,
recovery, deletion, the owner check and lost answers. Every crypto vector file of IOS-PLAN §7 is copied with a
`SOURCE.md` and checked. CI (`.github/workflows/ci.yml`) runs: the generated project matches `project.yml`, SwiftLint
strict, `swift test` on seven pure packages, `xcodebuild test` of the `VettID` scheme (the app tests and every
package's tests) on a simulator, the release check with its self-test, and gitleaks over the full history.

### Public

### T1. The UI test bundles and the dev-stack app are not built in CI

- **Severity:** Public. **Status:** V. **Size:** S.
- **Where:** `.github/workflows/ci.yml` builds only the `VettID` scheme; `VettIDAppUITests` (`AppUITests/`, the
  Staging end-to-end tests and the gallery), `VettIDDevStack` and `VettIDDevStackUITests` are in other schemes
  (`project.yml`, schemes `VettIDScreenshots`, `VettIDStagingUITests`, `VettIDDevStack`). The release check reads only
  their build settings (`scripts/release-check.sh:191-201`).
- **What happens:** a change that breaks the Staging UI tests or the dev-stack app compiles and passes CI; it is found
  the next time someone runs `scripts/staging-ui-test.sh` on the iPhone. The same as Android T1.
- **Suggested fix:** `xcodebuild build-for-testing` of the `VettIDScreenshots` and `VettIDDevStack` schemes on the
  simulator in CI (no run needed).

### T2. The hardware and end-to-end paths are tested only by hand, and skips are silent

- **Severity:** Public. **Status:** V. **Size:** S (reporting) to M (a scheduled run).
- **Where:** skipped on the CI simulator: `AppTests/SecureEnclaveDeviceTests.swift:21`, `AppAttestDeviceTests.swift:31`,
  `LockedPhoneDeviceTests.swift:27-28`, `KeychainTests.swift:103`; skipped without the dev stack:
  `Packages/VettIDVault/Tests/VettIDVaultTests/DevStackAcceptanceTests.swift:27`,
  `AppDevStackUITests/DevStackTests.swift:58`; skipped without inputs: `AppUITests/StagingTests.swift:442`.
- **What happens:** the Secure Enclave keys, App Attest, the keychain's behaviour with the iPhone locked, and every
  flow against a real vault run only when someone runs them on the phone or the Mac. CI prints no count of skipped
  tests, so a test that starts skipping for a wrong reason goes unnoticed. The same as Android T3.
- **Suggested fix:** print the skipped tests from the result bundle (`xcresulttool`) in the CI summary; record a
  per-release run of the `VettIDDevice` scheme and the Staging UI tests (date, build, result) in the release notes.

### Polish

### T3. Absence is asserted after fixed sleeps, and the wait helper is copied eight times

- **Severity:** Polish. **Status:** V. **Size:** M.
- **Where:** for example `Packages/VettIDData/Tests/VettIDDataTests/VaultManagerUnlockTests.swift:74,118,172,281`,
  `VaultManagerActivityTests.swift:141,211,264`, `FeedTests.swift:120,190`,
  `Packages/VettIDVault/Tests/VettIDVaultTests/AsyncLockTests.swift:77-156`; `eventually` or `until` is defined separately
  in eight test targets (`VettIDDataTests/VaultManagerUnlockTests.swift:14`, `VettIDSettingsTests/TestWaits.swift:6`, …),
  polling every 10 ms for up to 20 s.
- **What happens:** "nothing happened in 200 ms" passes when the unwanted event comes late, so a regression can pass on
  a fast machine; the polling is slow but not flaky. The same as Android T4.
- **Suggested fix:** where the code under test has a sleep hook (`config.lockTiming.sleep` exists), drive it; move one
  `eventually` into `VettIDTesting`.

### T4. The vector copies are not re-checked against vettid-vault

- **Severity:** Polish. **Status:** V. **Size:** S.
- **Where:** `Packages/VettIDCrypto/Tests/VettIDCryptoTests/Resources/vectors/recovery.json` lacks
  `cancel_named_signing_string`, which vettid-vault added in `6916bb5` (VAULT-MESSAGING 0.49.0, the named
  `recovery_cancel`); every other copied file has the same hash as vettid-vault's `main` at the time of this audit.
- **What happens:** nothing fails today (the app builds no recovery-request signing string), but a vector that changes
  upstream is only noticed when someone copies it again.
- **Suggested fix:** a script that compares each copied file's hash to the source repository's, run before each phase;
  copy the newer `recovery.json` with its `SOURCE.md` entry.

### T5. Two tests the plan names are missing

- **Severity:** Polish. **Status:** V. **Size:** S–M.
- **Where:** IOS-PLAN §6.4 asks for "a UI test asserting the cover exists while inactive";
  `AppTests/SecureInputTests.swift:23-37` checks only that the shield is installed and hidden while active. §6.5 asks
  for a device test that neither the AutoFill bar nor "Save Password?" appears on each secret screen;
  `AppUITests/VaultUITestCase.swift:47-70` catches the save prompt during the Staging tests, nothing checks the AutoFill
  bar, and `SecretField.swift:13` still says the technique was "not yet run on an iPhone".
- **Suggested fix:** an XCUITest that sends the app to the background (`XCUIDevice.shared.press(.home)`) and finds
  `privacy_cover`; record the AutoFill result in the component's comment after phone check 4.

### T6. No accessibility audit and no screenshot comparison in tests

- **Severity:** Polish. **Status:** V. **Size:** M.
- **Where:** no `performAccessibilityAudit()` (iOS 17) in any UI test; `AppUITests/GalleryScreenshots.swift` captures
  dark, light and the largest text size but compares nothing, and runs only by hand.
- **Suggested fix:** an audit per gallery entry in the `VettIDScreenshots` scheme; the same as Android T5.

### T7. Tests run only in Debug

- **Severity:** Polish. **Status:** V. **Size:** S.
- **Where:** every scheme's test action uses Debug (`project.yml`, schemes); Release and Staging are archived but not
  tested. Debug-only hooks change behaviour (`Packages/VettIDVault/Sources/VettIDVault/VaultDevice.swift:25`,
  `VaultDevice+Enroll.swift:64`, `Packages/VettIDCrypto/Sources/VettIDCrypto/HPKE/Hpke.swift:134`).
- **Suggested fix:** run the pure packages' `swift test -c release` in CI (the release check already builds them in
  release mode).

### Android A6 area 8 against the iPhone app

| Android finding | iOS | Note |
|---|---|---|
| T1 Instrumented tests not compiled in CI | same | T1. |
| T2 `VaultManager` has no unit test | not here | About 45 `VaultManager*Tests` files in `Packages/VettIDData/Tests/VettIDDataTests/`. |
| T3 Tests silently never run | same | T2. |
| T4 Real-time waits | same | T3. |
| T5 No screenshot or accessibility checks | same | T6. |
| T6 Contrast test covers the base scheme only | not checked here | `Packages/VettIDUI/Tests/VettIDUITests/ThemeTests.swift`; contrast belongs to area 1. |
| T7 Lint blind spots | not here | SwiftLint strict covers `App`, `AppTests`, `AppUITests`, `AppDevStack`, `AppDevStackUITests`, `Packages` (`.swiftlint.yml`). |
| T8 Dead test wiring | not here | Every package's test targets have sources; the `VettIDDevice` scheme runs the app-hosted tests on a phone. |

### Highest-value missing tests

1. The pasteboard is cleared at the vault lock only if it still holds the app's copy (S1).
2. The app-lock timeout with the wall clock moved back (S3, a fake monotonic clock).
3. The privacy cover while the scene is inactive (T5).
4. An archive check of the shipping `Info.plist` and entitlements per configuration (S9, G1, G2).
5. `build-for-testing` of the UI test and dev-stack schemes (T1).

---

## Needs a real iPhone (areas 5, 7, 8)

1. **App switcher (§6.4.1):** app lock on, "Immediately"; reveal a secret item with its password shown; swipe up to the
   app switcher. The card must show only the rook on navy. Repeat on a conversation and on the typed recovery code.
2. **Capture (§6.4.2):** start a screen recording from Control Center, then AirPlay mirroring; the app must show
   "Hidden while your screen is being recorded or shared".
3. **Screenshots (§6.4.3):** screenshot the revealed item, the item editor, the invitation QR and the typed recovery
   code; the protected parts must be blank. Turn "Allow screenshots" on and repeat; they must show. Lock the vault: the
   allowance must end.
4. **AutoFill and "Save Password?" (§6.5, T5):** with iCloud Keychain and a third-party password manager enabled, open
   each secret screen (unlock, change password, new credential, delete vault, recovery, transfer code, setup code). No
   key icon in the QuickType bar; no save prompt after submitting.
5. **Keyboard learning:** type a recovery phrase into a new "Recovery phrase" item and save; in Notes type its first
   word. Suggested following words would mean the visible secret fields still teach the keyboard.
6. **System copy (S4):** show the credential password, long-press it: is Copy offered? Paste on a Mac signed in to the
   same Apple ID.
7. **Pasteboard at the lock (S1):** copy an item's value, lock the vault within 60 s, paste in Notes.
8. **Wall clock (S3):** app lock on, 5 minutes; go to the Home Screen, set the clock back an hour, return.
9. **Third-party keyboards:** install another keyboard; in every VettID field only Apple's keyboards appear.
10. **Backup and restore (§6.1):** an encrypted Finder backup restored to another iPhone; the app must take the "this
    phone no longer holds the keys" path and keep only the theme.
11. **Upload validation (G1, G2, G8):** archive Staging, Organizer → Validate App.
12. **Mac (G9):** if not opted out, install the TestFlight build on an Apple silicon Mac and try to set up.
