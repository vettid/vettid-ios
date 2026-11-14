# Licences of the media stack

The licence texts of the webrtc-sdk binary (`WebRTC.xcframework`, release 150.7871.04 of `webrtc-sdk/Specs`) and of the
libraries built into it. They are listed in Help > Licences (`scripts/licences.sh`).

The binary is built from libwebrtc commit `a545de45259b47dfac5f3635863e47cb601f1bb2` of `github.com/webrtc-sdk/webrtc`. Each text
below is taken at the revision that commit pins: the revisions of its `DEPS` (BoringSSL, libsrtp, libyuv, libvpx, libaom, dav1d,
crc32c), the files of the libwebrtc tree itself (WebRTC, ooura, fft, spl_sqrt_floor, g711, g722), and, for the libraries chromium
carries in its own tree (abseil, Opus, zlib, pffft, rnnoise), chromium at the `chromium_revision` of that `DEPS`
(`36ff404216656d0a28613012d6a6920c575e9832`). The xcframework itself ships only WebRTC's LICENSE (identical to the first file) and
no NOTICE. BoringSSL's file at that revision is the Apache License 2.0.

| File | Source | sha256 |
| --- | --- | --- |
| `WebRTC-LICENSE.txt` | github.com/webrtc-sdk/webrtc@a545de45259b47dfac5f3635863e47cb601f1bb2 `LICENSE` | `ab00a482b6a3902e40211b43c5d0441962ea99b6cc7c25c0f243fa270b78d482` |
| `boringssl-LICENSE.txt` | boringssl.googlesource.com/boringssl @ `f91f1447397c6719f9774dfb8e67329378e1f3d3` (DEPS `src/third_party/boringssl/src`), `LICENSE` | `827c8d8fc207c2392794eef9e00fe246f9f61fdcc132556c275be3dd8c3cd97f` |
| `libsrtp-LICENSE.txt` | chromium.googlesource.com/chromium/deps/libsrtp @ `cd5d177bf1fde755ddb4c7f0d9ff7693f8b49e5e`, `LICENSE` | `8e19d42a1eec9561f3f347253ddf2e385c55f392f025bb0fd41b88dbf38db5ae` |
| `libyuv-LICENSE.txt` | chromium.googlesource.com/libyuv/libyuv @ `de63bd90f4396313f864ad58b65279e7894451a9`, `LICENSE` | `2b2cc1180c7e6988328ad2033b04b80117419db9c4c584918bbb3cfec7e9364f` |
| `libvpx-LICENSE.txt` | chromium.googlesource.com/webm/libvpx @ `31af37b1bd2774d11a932c1cd9a3849328375f64`, `LICENSE` | `8267348d5af1262c11d1a08de2f5afc77457755f1ac658627dd9acf71011d615` |
| `libaom-LICENSE.txt` | aomedia.googlesource.com/aom @ `c213343c8d32bcae729fe09fcba16e1f371cb23b`, `LICENSE` | `4764a286d8b2faeaf42f4418e7d7a28d58fc8fd4d00a3d0a7f44b0a4099de7f2` |
| `dav1d-LICENSE.txt` | chromium.googlesource.com/external/github.com/videolan/dav1d @ `1718ff9aded99f0a89f5c7940d6afb8948301e33`, `COPYING` | `dd92c3c2247c5651606fc23a5e2d6a1ebc5ace9a3e49cbde0e12f05ad1cb1ee5` |
| `crc32c-LICENSE.txt` | chromium.googlesource.com/external/github.com/google/crc32c @ `d3d60ac6e0f16780bcfcc825385e1d338801a558`, `LICENSE` | `a1f30b77c01e0995fa32a00119e00749e8731ee8a3c4c3549bce74083c72b0b6` |
| `abseil-LICENSE.txt` | chromium/chromium @ `36ff404216656d0a28613012d6a6920c575e9832` (DEPS `chromium_revision`), `third_party/abseil-cpp/LICENSE` | `c79a7fea0e3cac04cd43f20e7b648e5a0ff8fa5344e644b0ee09ca1162b62747` |
| `opus-LICENSE.txt` | chromium/chromium @ `36ff404216656d0a28613012d6a6920c575e9832`, `third_party/opus/src/COPYING` | `01e1167d54a096d123cf6dfbbeb19587278845c6481d2d66d545669846079551` |
| `zlib-LICENSE.txt` | chromium/chromium @ `36ff404216656d0a28613012d6a6920c575e9832`, `third_party/zlib/LICENSE` | `e32ff4e00d9d94930537635291da39e7e612703334bf6fde8c7f1686fe8a45a2` |
| `pffft-LICENSE.txt` | chromium/chromium @ `36ff404216656d0a28613012d6a6920c575e9832`, `third_party/pffft/LICENSE` | `a46200592eb193853527250da098e6bb0c75424e7a2c7db8da526c4f301c3d88` |
| `rnnoise-LICENSE.txt` | chromium/chromium @ `36ff404216656d0a28613012d6a6920c575e9832`, `third_party/rnnoise/COPYING` | `e2f59ff41d9d03adc3dcf3deff170f8c8cf4a6eb4a9b174762a7656d23200ffa` |
| `ooura-LICENSE.txt` | webrtc-sdk/webrtc@a545de45259b47dfac5f3635863e47cb601f1bb2 `common_audio/third_party/ooura/LICENSE` | `25b7731b70c77ecd5f3bb19303fbaa99be18860f81d44f71da670fdcd04829db` |
| `fft-LICENSE.txt` | webrtc-sdk/webrtc@a545de45259b47dfac5f3635863e47cb601f1bb2 `modules/third_party/fft/LICENSE` | `6fdbabd2c95c5efc6f1e46175278239afb9343120a3022ed0e0cb04267a6aeb3` |
| `spl_sqrt_floor-LICENSE.txt` | webrtc-sdk/webrtc@a545de45259b47dfac5f3635863e47cb601f1bb2 `common_audio/third_party/spl_sqrt_floor/LICENSE` | `41d791701e3e1c1073470403de7e342442d1e6a2af72681023b13a2f45f2125c` |
| `g711-LICENSE.txt` | webrtc-sdk/webrtc@a545de45259b47dfac5f3635863e47cb601f1bb2 `modules/third_party/g711/LICENSE` | `b29c8f13f91feb2dab7d6655444369fa9f29c0d7121a52dab90ff97e40343a85` |
| `g722-LICENSE.txt` | webrtc-sdk/webrtc@a545de45259b47dfac5f3635863e47cb601f1bb2 `modules/third_party/g722/LICENSE` | `61862327fd00d6a4deb2c1276577782c2500f4fe103e072018fc369d8e37e876` |

## What is and is not verified

- Verified: every file above was fetched at the revision named; the library list is libwebrtc's own: the DEPS entries and the
  `third_party` directories of the tree. BoringSSL, Opus, libsrtp, libyuv, abseil, libaom, dav1d and libvpx were also seen in the
  binary's strings and symbols.
- Not verified: `tools_webrtc/libs/generate_licenses.py` was not run (it needs the gn build of the iOS target), so the list is not
  its output. pffft, rnnoise, crc32c, ooura, fft and spl_sqrt_floor leave no readable name in the stripped binary; they are listed
  because libwebrtc's audio processing and dcsctp use them. `rtc_base/third_party/sigslot` and `base64` are absent from this commit's
  tree. Whether Opus and zlib are the chromium tree's copies at that revision (as opposed to a later roll) is not proved.
- libc++ and libc++abi are not in the binary's own licence list: they are LLVM's, under the Apache 2.0 licence with LLVM
  exceptions (the runtime exception makes no attribution necessary for the binary form). Their `DEPS` revisions are
  `5abc7f839700f0f17338434e1c1c6a8c87c00c11` and `8f11bb1d4438d0239d0dfc1bd9456a9f31629dda`.
