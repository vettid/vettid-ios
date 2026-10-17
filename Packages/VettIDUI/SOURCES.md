# Bundled resources

Copied from vettid-android `master` at `b54685fb`, unmodified unless said.

## Fonts (`Sources/VettIDUI/Resources/Fonts`)

Both are licensed under the SIL Open Font License 1.1 (licence texts beside
them). Headings in Plus Jakarta Sans, body text in Inter, as on the website and
in the Android app. The upright variable fonts, one file per family.

| File | vettid-android source | Upstream | SHA-256 |
|---|---|---|---|
| `InterVariable.ttf` | `core/ui/src/main/res/font/inter_variable.ttf` | `InterVariable.ttf` from rsms/inter v4.1 | 4989b125924991b90d05b2d16e0e388c48f7d5bb8b30539bbf9c755278d0ccaf |
| `PlusJakartaSans-Variable.ttf` | `core/ui/src/main/res/font/plus_jakarta_sans_variable.ttf` | `variable/PlusJakartaSans[wght].ttf` from tokotype/PlusJakartaSans 2.7.1 | 3c9102733d96af218ea12aab89fd2c04a6d3c2bee9acf37057fc9b29139b451b |

The hashes match vettid-android `core/ui/fonts/SOURCES.md`.

## Brand artwork (`Sources/VettIDUI/Resources/Brand.xcassets`)

The Android vector drawables converted to SVG, path for path (same path data,
fills, fill rules and group transforms; nothing redrawn):

| Image set | vettid-android source |
|---|---|
| `Rook` | `core/ui/src/main/res/drawable/ic_rook.xml` |
| `LogoHorizontal` | `core/ui/src/main/res/drawable/ic_logo_horizontal.xml` (dark surfaces) |
| `LogoHorizontalOnLight` | `core/ui/src/main/res/drawable/ic_logo_horizontal_on_light.xml` (light surfaces) |
