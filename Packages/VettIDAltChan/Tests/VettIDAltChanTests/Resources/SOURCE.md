# Test vectors (copied, do not edit)

`vectors/recovery-qr.json` is copied verbatim from vettid-android
`core/altchan/src/test/resources/vectors/recovery-qr.json` (IOS-PLAN §7), at
vettid-android commit b54685fbf8c523f94662cb596d521602ce7d41c0. It was generated with vettid-vault's own code
(`vms/altchan.RecoveryQR` / `ParseRecoveryQR`, `vms/invite.QR`, vettid-vault
commit ca10a728427f84ad8ba34466877c3b6a90a51cb0); vettid-android's `SOURCE.md`
next to it holds the generator. Copied: 2026-10-17.

A vector that no longer matches is a stop-and-report item, never a skip.

`sha256sum` (the same as vettid-android's `SOURCE.md` lists):

```
99829e63d3f80962b21413771de2c6de301c4633fcd8c976ee2614afffbd4189  recovery-qr.json
```
