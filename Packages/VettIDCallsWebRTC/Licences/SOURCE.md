# Licences of the media stack

The licence texts of the webrtc-sdk binary (`WebRTC.xcframework`, release 150.7871.04 of `webrtc-sdk/Specs`, libwebrtc commit
a545de45) and of the libraries built into it. They are listed in Help > Licences (`scripts/licences.sh`).

The xcframework ships one licence file (WebRTC's own, copied here as `WebRTC-LICENSE.txt`) and no NOTICE. The libraries below were
found in the binary's strings and symbols (BoringSSL, Opus, libsrtp, libyuv, abseil, libaom, dav1d, libvpx, zlib). Their texts are
the upstream files at the head of the named branch on the day they were copied (2026-11-14), not at the libwebrtc commit: when the
stack is updated, compare them with the DEPS of its libwebrtc commit.

| File | Source | sha256 |
| --- | --- | --- |
| `WebRTC-LICENSE.txt` | `LICENSE` inside `WebRTC.xcframework` of the release | `ab00a482b6a3902e40211b43c5d0441962ea99b6cc7c25c0f243fa270b78d482` |
| `boringssl-LICENSE.txt` | boringssl.googlesource.com/boringssl, `main`, `LICENSE` | `827c8d8fc207c2392794eef9e00fe246f9f61fdcc132556c275be3dd8c3cd97f` |
| `opus-LICENSE.txt` | chromium.googlesource.com/chromium/deps/opus, `main`, `COPYING` | `8338ce8d922bb4416ce3dd1e5680173332435e3f0755007ac7801ccd674fe682` |
| `libsrtp-LICENSE.txt` | chromium.googlesource.com/chromium/deps/libsrtp, `main`, `LICENSE` | `8e19d42a1eec9561f3f347253ddf2e385c55f392f025bb0fd41b88dbf38db5ae` |
| `libyuv-LICENSE.txt` | chromium.googlesource.com/libyuv/libyuv, `main`, `LICENSE` | `2b2cc1180c7e6988328ad2033b04b80117419db9c4c584918bbb3cfec7e9364f` |
| `abseil-LICENSE.txt` | github.com/abseil/abseil-cpp, `master`, `LICENSE` | `c79a7fea0e3cac04cd43f20e7b648e5a0ff8fa5344e644b0ee09ca1162b62747` |
| `libaom-LICENSE.txt` | aomedia.googlesource.com/aom, `main`, `LICENSE` | `4764a286d8b2faeaf42f4418e7d7a28d58fc8fd4d00a3d0a7f44b0a4099de7f2` |
| `dav1d-LICENSE.txt` | chromium.googlesource.com/external/github.com/videolan/dav1d, `master`, `COPYING` | `dd92c3c2247c5651606fc23a5e2d6a1ebc5ace9a3e49cbde0e12f05ad1cb1ee5` |
| `libvpx-LICENSE.txt` | chromium.googlesource.com/webm/libvpx, `main`, `LICENSE` | `8267348d5af1262c11d1a08de2f5afc77457755f1ac658627dd9acf71011d615` |
| `zlib-LICENSE.txt` | chromium.googlesource.com/chromium/src/third_party/zlib, `main`, `LICENSE` | `e32ff4e00d9d94930537635291da39e7e612703334bf6fde8c7f1686fe8a45a2` |
