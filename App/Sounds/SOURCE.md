# Notification sounds

VettID's own notification sounds (IOS-PLAN §6.7 "Sounds"), licensed AGPL-3.0 like this repository. They are exported from
the masters and the deterministic generator in vettid-android `tools/sounds/` (`synth_family.py`) at commit `f50ea02a`:
every note ends with a release and the ringtone's ends meet at silence, so none of them clicks, across the ringtone's loop
point included. Exported with `afconvert -f caff -d ima4` (IMA4 ADPCM, 44.1 kHz, mono).

| File | Duration | SHA-256 |
|---|---|---|
| `vettid_general.caf` | 1.36 s | `72a4c1bc9284794c69ecc7496928148639554f11dbcabc1badb133a8e5d5cfcc` |
| `vettid_message.caf` | 1.66 s | `d748557bea8ab654afb611d8f5a64127166727485d2c501b99e35463356b8202` |
| `vettid_urgent.caf` | 2.16 s | `a34e4dfd806963d88ec851679233b6ec2cf49d2674f1dfc51eb9f58d5cb72e27` |
| `vettid_ringtone.caf` | 8.00 s | `fa6e8c987fa722a0bd3e4e85737fbc3c2946ce54d1d61527660adf0889a05b09` |

Use (IOS-PLAN §6.7): a new message and a missed call → `vettid_message`; approvals, security alarms and the daily check →
`vettid_urgent`; release and vault notices → `vettid_general`; vault activity is silent; `vettid_ringtone` is CallKit's
`ringtoneSound`. They are bundled in the app now and go into the notification service extension's target too when phase P
adds it. Never edit a file here: re-export it from the masters.
