# Background Delivery (Push) — Implementation Plan

> **Status: DEFERRED — post technical preview.**
> The technical preview validates the security primitives (enrollment,
> attestation, PIN unlock, credential creation, vault warming, E2E
> crypto). Background push delivery is a reachability/UX feature, not a
> security primitive, and is intentionally out of scope for the preview.
> See "Is this a preview blocker?" at the bottom.

## Why this exists

iOS cannot replicate Android's `VaultProtectionService` (a persistent
foreground service that holds a NATS connection open in the background
and shows a "Vault protection active" notification). iOS suspends apps
seconds after backgrounding — there is no always-on socket and no
foreground-service concept. The iOS-correct equivalent is **push-driven
wake**: the server sends a push when an event occurs and the app isn't
connected, which wakes the app (or rings via CallKit).

## Verified current state (2026-05-28)

- **iOS entitlements:** no `aps-environment` key — the app is not
  provisioned for push at all (hard prerequisite).
- **iOS AppDelegate:** registers BGTasks only; no
  `registerForRemoteNotifications`, no device-token delegate, no
  `didReceiveRemoteNotification`.
- **PushKit:** `PushKitManager` captures the VoIP token and is wired to
  CallKit on the *receive* side, but `onTokenReceived` is never consumed
  — the token is never uploaded anywhere.
- **Server (vettid-dev):** no APNs/PushKit sender, no device-token
  storage table or endpoint.
- **Info.plist:** background modes `voip, remote-notification, fetch,
  location` are already declared.
- **Foreground works today:** while the app is running with a live NATS
  connection, `VaultSecurityService` surfaces vault events as local
  notifications via `LocalNotificationManager` (requires notification
  permission, which the enrollment Permissions screen now requests).

**Conclusion:** background delivery is net-new plumbing on both client
and server. Nothing reaches a backgrounded/suspended app today.

## Goal & non-goals

- **Goal:** when the app is backgrounded/suspended, the user still gets
  calls, messages, and security alerts.
- **Non-goal:** a persistent always-on NATS connection or a
  foreground-service equivalent. Delivery is push-driven wake.

## Architecture

Three push channels, by event type:

1. **PushKit / VoIP push** → incoming calls → CallKit (client receive
   side already exists).
2. **APNs alert push** → messages, connection requests,
   credential/security events the user should see on the lock screen.
3. **APNs silent/background push** (`content-available`) → wake the app
   briefly to drain queued items over NATS (e.g. feed sync), no
   user-visible alert.

At event time the vault/supervisor decides: *is a live NATS session
attached?* If not → enqueue a push to the device's stored token.

## Workstreams

### A. Apple account + project setup (prerequisite — hard gate)
- Enable the Push Notifications capability on the App ID.
- Add `aps-environment` to `VettID.entitlements` (development +
  production).
- Create an **APNs Auth Key (.p8)** (one key signs both alert + VoIP);
  store it in the server secret store (Secrets Manager).
- Record bundle id + team id + key id for the sender.

### B. iOS client — token registration & upload
- Post-auth (or after warmVault): `UNUserNotificationCenter
  .requestAuthorization` + `registerForRemoteNotifications()`.
- Implement `didRegisterForRemoteNotificationsWithDeviceToken` → hex
  token.
- Consume `PushKitManager.onTokenReceived` (already emits the VoIP
  token).
- Upload both tokens (APNs + VoIP) to the vault, keyed to the
  owner-space/user. Transport TBD (see Decisions).

### C. Server — token storage + sender
- New DynamoDB table `DeviceTokens` (user_guid → [{apnsToken,
  voipToken, platform, env, updatedAt}]), multi-device.
- New endpoint/handler to receive token registration.
- APNs sender module (HTTP/2 to `api.push.apple.com`, JWT signed with
  the .p8): `sendAlert(userGuid, payload)` + `sendVoIP(userGuid,
  payload)`.

### D. Event → push wiring (the actual "background" behavior)
- Identify vault/supervisor events that must reach a backgrounded user:
  incoming call, new message, connection request, security/credential
  alert.
- At emit time, if no live app NATS session: call the APNs sender (VoIP
  for calls, alert for the rest, silent for sync-only). This is where
  Android's foreground-service responsibilities live on iOS — server
  driven, not client driven.

### E. iOS receive & routing
- VoIP push → CallKit `reportNewIncomingCall` (path exists; verify
  end-to-end once tokens flow).
- Alert push → tap routes to the right screen (message thread,
  connection request, security view).
- Silent push → `didReceiveRemoteNotification(fetchCompletionHandler:)`
  → brief NATS connect, drain, call completion within the background
  budget.

### F. Token lifecycle
- Re-upload on token rotation (`didUpdate` / `didInvalidate`).
- Delete tokens on logout / `fullSignOut` / unenroll.
- Handle APNs feedback (410 Gone) → prune stale tokens server-side.

## Phasing

- **Phase 1 (calls):** A + B(VoIP only) + C(sender, VoIP) + D(call
  event) + E(VoIP→CallKit). Smallest vertical slice; the client receive
  side already exists, so this proves the whole pipeline fastest.
- **Phase 2 (alerts):** APNs alert path for messages/connections/security
  events.
- **Phase 3 (silent sync):** background `content-available` wake + NATS
  drain.

## Decisions needed before coding

1. **Token upload transport:** NATS subject vs authenticated HTTP
   endpoint. (NATS matches the post-enrollment flow; HTTP is simpler to
   authorize via Cognito.)
2. **APNs environment strategy:** side-loaded debug builds use the
   **development** APNs environment; TestFlight/release use
   **production**. Store `env` with each token and target the right host.
3. **Who owns the "is the app connected?" decision** — supervisor vs a
   Lambda — since that gates whether a push is sent.

## Testing

- Phase 1: background the app, place a call from a second account →
  CallKit rings.
- Verify dev-vs-prod APNs env with a side-loaded build (dev) and a
  TestFlight build (prod).
- Confirm 410-Gone pruning by uninstalling and re-pushing.

## Is this a preview blocker?

**No** — not for validating security primitives. Those flows are all
exercised with the app in the foreground/running, where notifications
already work over the live NATS connection. The only gap is that an
unsolicited event (incoming call/message) won't reach a user whose app
is fully backgrounded/suspended; preview test scenarios can keep both
parties' apps open to exercise those paths.
