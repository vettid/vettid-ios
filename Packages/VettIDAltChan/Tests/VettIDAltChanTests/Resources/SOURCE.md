# Test vectors (copied, do not edit)

`vectors/recovery-qr.json` is copied verbatim from vettid-android
`core/altchan/src/test/resources/vectors/recovery-qr.json` (IOS-PLAN §7), at
vettid-android commit b54685fbf8c523f94662cb596d521602ce7d41c0. It was generated with vettid-vault's own code
(`vms/altchan.RecoveryQR` / `ParseRecoveryQR`, `vms/invite.QR`, vettid-vault
commit ca10a728427f84ad8ba34466877c3b6a90a51cb0); vettid-android's `SOURCE.md`
next to it holds the generator. Copied: 2026-10-17.

`vectors/appkey.json` (VAULT-MESSAGING 0.15.0 §11.12, the app key and signed member API requests) is copied
verbatim from vettid-vault `testdata/vectors/` at commit 1ef2dd9ec68627a80e18d665032fcd58e3a61a1d (last commit touching it
8ff877023daa525235119fbfa0b0b44c46e4a2bd). vettid-android has no copy of it. Copied: 2026-10-17, for I0.6.

A vector that no longer matches is a stop-and-report item, never a skip.

`sha256sum` (`recovery-qr.json`'s is the one vettid-android's `SOURCE.md` lists):

```
d5e9da4df2747431ce6432d51214264cf5f189900214f2a9315cc5b82c6c0af1  appkey.json
99829e63d3f80962b21413771de2c6de301c4633fcd8c976ee2614afffbd4189  recovery-qr.json
```
