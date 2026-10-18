// The --real mode (IOS-PLAN §8 I1.4, VA1): an App Attest attestation and its assertions made by a real iPhone
// (AppTests' AppAttestDeviceTests with VETTID_TEST_APPATTEST_EXPORT=1) must pass vms/devattest.VerifyAttest and
// VerifyAssertion under a release policy, against Apple's App Attestation root as the vault pins it
// (pins.AppleAppAttestRoot), for the App ID "<team id>.<bundle id>" and the production environment: the team ID comes
// from the command line (run.sh reads it from Config/Signing.xcconfig), the bundle id from the file. The dev enclave's
// policy (VA3) is checked too. The objects themselves are never printed.
package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"github.com/vettid/vettid-vault/internal/cbor"
	"github.com/vettid/vettid-vault/vms/altchan"
	"github.com/vettid/vettid-vault/vms/devattest"
	"github.com/vettid/vettid-vault/vms/nitro"
	"github.com/vettid/vettid-vault/vms/pins"
)

// export is the device test's file.
type export struct {
	BundleID    string `json:"bundle_id"`
	AttestedAt  string `json:"attested_at"`
	KeyID       string `json:"key_id"`
	Attestation string `json:"attestation"`
	Challenge   string `json:"challenge"`
	Assertions  []struct {
		ClientDataHash string `json:"client_data_hash"`
		Assertion      string `json:"assertion"`
	} `json:"assertions"`
}

// realIOS is vettid-vault's vms/devattest/testdata/real/*.ios.json format (real_ios_test.go).
type realIOS struct {
	AppID       string             `json:"app_id"`
	AttestedAt  string             `json:"attested_at"`
	KeyID       string             `json:"key_id"`
	Attestation string             `json:"attestation"`
	Challenge   string             `json:"challenge"`
	Assertions  []realIOSAssertion `json:"assertions"`
}

type realIOSAssertion struct {
	ClientDataHash string `json:"client_data_hash"`
	Assertion      string `json:"assertion"`
}

var (
	teamPattern   = regexp.MustCompile(`^[A-Z0-9]{10}$`)
	bundlePattern = regexp.MustCompile(`^com\.vettid\.app(\.[a-z]+)?$`)
)

func b64(what, s string) []byte {
	b, err := base64.StdEncoding.Strict().DecodeString(s)
	if err != nil || len(b) == 0 {
		must(0, fmt.Errorf("%s: not standard base64", what))
	}
	return b
}

func hash32(what, s string) [32]byte {
	b := b64(what, s)
	if len(b) != 32 {
		must(0, fmt.Errorf("%s: %d bytes, want 32", what, len(b)))
	}
	return [32]byte(b)
}

// insideRepository reports whether path lies in a checkout of this repository (a directory holding VettID.xcodeproj
// above it): a real attestation object is never written or kept there, even when run.sh is bypassed.
func insideRepository(path string) bool {
	dir := filepath.Dir(must(filepath.EvalSymlinks(must(filepath.Abs(path)))))
	for {
		if _, err := os.Stat(filepath.Join(dir, "VettID.xcodeproj")); err == nil {
			return true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return false
		}
		dir = parent
	}
}

func realMain(path, team string) {
	if insideRepository(path) {
		must(0, errors.New("the export must stay outside the repository"))
	}
	if !teamPattern.MatchString(team) {
		must(0, errors.New("the team ID is not 10 uppercase letters or digits"))
	}
	var e export
	dec := json.NewDecoder(bytes.NewReader(must(os.ReadFile(path))))
	dec.DisallowUnknownFields()
	must(0, dec.Decode(&e))
	if !bundlePattern.MatchString(e.BundleID) {
		must(0, fmt.Errorf("bundle id %q is not a VettID bundle id", e.BundleID))
	}
	appID := team + "." + e.BundleID
	at := must(time.Parse(time.RFC3339, e.AttestedAt))
	ch := hash32("challenge", e.Challenge)
	d := &altchan.DeviceAttest{Platform: altchan.PlatformIOS, KeyID: b64("key_id", e.KeyID), Attestation: b64("attestation", e.Attestation)}
	check(len(e.Assertions) > 0, "the file holds %d assertion(s)", len(e.Assertions))

	notes("attestation", attestedAuthData(b64("attestation", e.Attestation)), true)
	for i, a := range e.Assertions {
		notes(fmt.Sprintf("assertion %d", i+1), must(must(cbor.Decode(b64("assertion", a.Assertion))).BytesAt("authenticatorData")), false)
	}

	// A release policy: Apple's root, this App ID, the production environment only (every configuration of the app is
	// signed for it, IOS-PLAN §6.2).
	release := &devattest.Policy{IOSRoots: nitro.Pool(pins.AppleAppAttestRoot()), IOSAppID: appID}
	b, err := devattest.VerifyAttest(release, d, ch, at, nil)
	check(err == nil, "devattest.VerifyAttest (release policy): chains to pins.AppleAppAttestRoot, App ID <team>.%s, production, the challenge as clientDataHash: %v", e.BundleID, err)
	if err != nil {
		os.Exit(1)
	}
	check(bytes.Equal(b.KeyID, d.KeyID) && b.Counter == 0, "binding: the key id, counter 0")
	// The dev enclave's iOS members (VA3) accept it too.
	dev := &devattest.Policy{IOSRoots: release.IOSRoots, IOSAppID: appID, IOSDevelopmentEnvironment: true}
	_, err = devattest.VerifyAttest(dev, d, ch, at, nil)
	check(err == nil, "devattest.VerifyAttest (dev enclave policy, VA3): %v", err)

	// What must be refused: another challenge, another App ID, the TEST policy's roots only.
	wrong := ch
	wrong[0] ^= 1
	_, err = devattest.VerifyAttest(release, d, wrong, at, nil)
	check(errors.Is(err, devattest.ErrChallenge), "another challenge is refused: %v", err)
	other := *release
	other.IOSAppID = team + ".com.vettid.app.other"
	_, err = devattest.VerifyAttest(&other, d, ch, at, nil)
	check(errors.Is(err, devattest.ErrApplication), "another App ID is refused: %v", err)

	for i, a := range e.Assertions {
		s := devattest.Signed{ClientDataHash: hash32("client_data_hash", a.ClientDataHash)}
		da := &altchan.DeviceAssertion{Platform: altchan.PlatformIOS, Assertion: b64("assertion", a.Assertion)}
		nb, err := devattest.VerifyAssertion(release, b, da, s, b.Counter, at, nil)
		check(err == nil, "assertion %d: devattest.VerifyAssertion: %v", i+1, err)
		if err != nil {
			continue
		}
		check(nb.Counter > b.Counter, "assertion %d: counter %d after %d", i+1, nb.Counter, b.Counter)
		_, err = devattest.VerifyAssertion(release, nb, da, s, nb.Counter, at, nil)
		check(errors.Is(err, devattest.ErrCounter), "assertion %d again is refused: %v", i+1, err)
		bad := s
		bad.ClientDataHash[0] ^= 1
		_, err = devattest.VerifyAssertion(release, b, da, bad, b.Counter, at, nil)
		check(errors.Is(err, devattest.ErrSignature), "assertion %d over another clientDataHash is refused: %v", i+1, err)
		b = nb
	}

	// The same objects in vettid-vault's testdata/real format, next to the export (never in a repository unless the
	// owner adds one on purpose: VA1).
	r := realIOS{AppID: appID, AttestedAt: e.AttestedAt, KeyID: e.KeyID, Attestation: e.Attestation, Challenge: e.Challenge}
	for _, a := range e.Assertions {
		r.Assertions = append(r.Assertions, realIOSAssertion(a))
	}
	out := filepath.Join(filepath.Dir(path), "real-"+e.BundleID+".ios.json")
	must(0, os.WriteFile(out, must(json.MarshalIndent(r, "", "  ")), 0o600))
	fmt.Println("wrote the testdata/real form next to the export")

	if failures > 0 {
		fmt.Printf("%d check(s) failed\n", failures)
		os.Exit(1)
	}
	fmt.Println("the iPhone's App Attest attestation and assertions pass vettid-vault devattest against Apple's root")
}

func errOrOK(err error, ok string) string {
	if err == nil {
		return ok
	}
	return err.Error()
}

func attestedAuthData(att []byte) []byte { return must(must(cbor.Decode(att)).BytesAt("authData")) }

// notes prints what the authenticator data carries beyond the key, the counter and the App ID: the flags and, when the
// extension data flag (ED, 0x80; WebAuthn §6.1) is set, the names of the extensions (never their values). iOS 27 sets
// ED in the attestation and in every assertion and appends a CBOR map of Apple's extensions; vms/devattest accepts it
// since vettid-vault #118 (exactly one definite-length map, nothing after it) without interpreting it, the nonce and
// the signature covering it.
func notes(what string, ad []byte, attested bool) {
	if len(ad) < 37 {
		fmt.Printf("note  %s: authenticator data of %d bytes\n", what, len(ad))
		return
	}
	rest := ad[37:]
	if attested && len(rest) >= 18 {
		n := int(rest[16])<<8 | int(rest[17])
		if len(rest) >= 18+n {
			// Exactly one item, the COSE key, then the extensions.
			if _, r, err := cbor.DecodePrefix(rest[18+n:]); err == nil {
				rest = r
			}
		}
	}
	fmt.Printf("note  %s: flags 0x%02x, %d byte(s) of extension data", what, ad[32], len(rest))
	if v, err := cbor.Decode(rest); len(rest) > 0 && err == nil && v.Kind == cbor.KindMap {
		var keys []string
		for _, p := range v.Map {
			keys = append(keys, p.Key.Text)
		}
		fmt.Printf(" (extensions %v)", keys)
	}
	fmt.Println()
}
