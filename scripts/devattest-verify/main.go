// Command devattest-verify checks the iPhone TEST attester's output (VettIDAltChanTesting's TestIOSAttester, IOS-PLAN
// §8 I1.3) with vettid-vault's own code: the fixture that the Swift tests write and reproduce
// (Packages/VettIDAltChan/Tests/VettIDAltChanTests/Resources/appattest/test-app-attest.json) must pass
// vms/devattest.VerifyAttest and VerifyAssertion under the dev enclave's TEST policy (internal/enclavetest.Policy),
// and everything in it that is not an ECDSA signature must equal what internal/enclavetest builds for the same key and
// challenge: the TEST Apple CA's root and intermediate tbsCertificate, the credential certificate's tbsCertificate
// (serial 1001, the first in a process), the authenticator data, the receipt and each assertion's authenticator data.
// It also checks that the verifier refuses the fixture with another challenge, a replayed counter and another App ID.
// With --real it checks a real iPhone's App Attest objects against Apple's root instead (real.go).
//
// The file is compiled inside the vettid-vault module (it imports internal/enclavetest), through `go run -overlay`, so
// the clone is never modified: run.sh does it.
package main

import (
	"bytes"
	"crypto/elliptic"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/vettid/vettid-vault/internal/cbor"
	"github.com/vettid/vettid-vault/internal/enclavetest"
	"github.com/vettid/vettid-vault/vms/altchan"
	"github.com/vettid/vettid-vault/vms/devattest"
)

type fixture struct {
	AppID        string          `json:"app_id"`
	KeySeed      int             `json:"key_seed"`
	PublicKeyHex string          `json:"public_key_hex"`
	KeyIDHex     string          `json:"key_id_hex"`
	Serial       int64           `json:"serial"`
	ChallengeHex string          `json:"challenge_hex"`
	DeviceAttest json.RawMessage `json:"device_attest"`
	TestCA       struct {
		Root         string `json:"root"`
		Intermediate string `json:"intermediate"`
	} `json:"test_ca"`
	Assertions []struct {
		ClientData      string          `json:"client_data"`
		ChallengeHex    string          `json:"challenge_hex"`
		Message         string          `json:"message"`
		Counter         uint32          `json:"counter"`
		DeviceAssertion json.RawMessage `json:"device_assertion"`
	} `json:"assertions"`
}

var failures int

func check(ok bool, format string, a ...any) {
	if ok {
		fmt.Printf("ok    "+format+"\n", a...)
		return
	}
	failures++
	fmt.Printf("FAIL  "+format+"\n", a...)
}

func must[T any](v T, err error) T {
	if err != nil {
		fmt.Fprintln(os.Stderr, "devattest-verify:", err)
		os.Exit(2)
	}
	return v
}

func unhex(s string) []byte { return must(hex.DecodeString(s)) }

func challenge32(s string) (c [32]byte) {
	b := unhex(s)
	if len(b) != 32 {
		must(0, errors.New("a challenge is not 32 bytes"))
	}
	copy(c[:], b)
	return c
}

// attestation is the decoded attestation object.
type attestation struct {
	fmt      string
	x5c      [][]byte
	receipt  []byte
	authData []byte
}

func decodeAttestation(b []byte) attestation {
	v := must(cbor.Decode(b))
	st, ok := v.Lookup("attStmt")
	if !ok {
		must(0, errors.New("no attStmt"))
	}
	x, _ := st.Lookup("x5c")
	var a attestation
	a.fmt = must(v.TextAt("fmt"))
	a.authData = must(v.BytesAt("authData"))
	a.receipt = must(st.BytesAt("receipt"))
	for _, c := range x.Array {
		a.x5c = append(a.x5c, c.Bytes)
	}
	return a
}

func tbs(der []byte) []byte { return must(x509.ParseCertificate(der)).RawTBSCertificate }

func main() {
	if len(os.Args) == 4 && os.Args[1] == "--real" {
		realMain(os.Args[2], os.Args[3])
		return
	}
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: devattest-verify FIXTURE | --real EXPORT TEAM_ID")
		os.Exit(2)
	}
	var f fixture
	must(0, json.Unmarshal(must(os.ReadFile(os.Args[1])), &f))
	now := time.Now()
	policy := enclavetest.Policy()
	ch := challenge32(f.ChallengeHex)

	// What enclavetest builds for the same key and challenge (its first credential serial in this process is 1001).
	goKey := enclavetest.TestKey(elliptic.P256(), byte(f.KeySeed))
	goAttester := enclavetest.NewIOSAttester(byte(f.KeySeed), enclavetest.IOSOptions{})
	goAttest := must(goAttester.Attest(ch))
	goAtt := decodeAttestation(goAttest.Attestation)

	d := must(altchan.ParseDeviceAttest(f.DeviceAttest))
	check(d.Platform == altchan.PlatformIOS, "device_attest platform %q", d.Platform)
	check(f.AppID == enclavetest.IOSAppID, "app_id %s is enclavetest.IOSAppID", f.AppID)
	check(bytes.Equal(d.KeyID, goAttest.KeyID) && bytes.Equal(d.KeyID, unhex(f.KeyIDHex)), "key id equals enclavetest.IOSKeyID")
	sw := decodeAttestation(d.Attestation)
	check(sw.fmt == goAtt.fmt, "fmt %q", sw.fmt)
	check(bytes.Equal(sw.authData, goAtt.authData), "authData byte for byte (%d bytes)", len(sw.authData))
	check(bytes.Equal(sw.receipt, goAtt.receipt), "receipt byte for byte")
	check(len(sw.x5c) == 2 && len(goAtt.x5c) == 2, "x5c holds the credential and the intermediate")
	check(f.Serial == 1001, "credential serial %d is enclavetest's first", f.Serial)
	if len(sw.x5c) == 2 {
		check(bytes.Equal(tbs(sw.x5c[0]), tbs(goAtt.x5c[0])), "credential tbsCertificate byte for byte")
		inter := enclavetest.TestAppleCA().Inter.Cert.RawTBSCertificate
		check(bytes.Equal(tbs(sw.x5c[1]), inter), "intermediate tbsCertificate byte for byte")
	}
	root := must(base64.StdEncoding.DecodeString(f.TestCA.Root))
	check(bytes.Equal(tbs(root), enclavetest.TestAppleCA().Root.Cert.RawTBSCertificate), "root tbsCertificate byte for byte")
	check(len(sw.x5c) > 1 && bytes.Equal(must(base64.StdEncoding.DecodeString(f.TestCA.Intermediate)), sw.x5c[1]),
		"test_ca.intermediate is x5c[1]")

	// The vault's verifier under the TEST policy.
	b, err := devattest.VerifyAttest(policy, d, ch, now, nil)
	check(err == nil, "devattest.VerifyAttest under enclavetest.Policy: %v", err)
	if err != nil {
		os.Exit(1)
	}
	check(bytes.Equal(b.PublicKey, unhex(f.PublicKeyHex)) && b.Counter == 0, "binding: the attested key, counter 0")
	wrong := ch
	wrong[0] ^= 1
	_, err = devattest.VerifyAttest(policy, d, wrong, now, nil)
	check(errors.Is(err, devattest.ErrChallenge), "another challenge is refused: %v", err)
	other := *policy
	other.IOSAppID = "OTHERTEAM0.com.vettid.app"
	_, err = devattest.VerifyAttest(&other, d, ch, now, nil)
	check(errors.Is(err, devattest.ErrApplication), "another App ID is refused: %v", err)

	for i, a := range f.Assertions {
		da := must(altchan.ParseDeviceAssertion(a.DeviceAssertion))
		var s devattest.Signed
		switch a.ClientData {
		case "approval":
			s = devattest.ForString(a.Message)
		default:
			s = devattest.ForChallenge(challenge32(a.ChallengeHex))
		}
		goAssert := decodeAssertionAD(enclavetest.IOSAssert(goKey, f.AppID, a.Counter, s.ClientDataHash))
		check(bytes.Equal(decodeAssertionAD(da.Assertion), goAssert), "assertion %d (%s): authenticatorData byte for byte", i+1, a.ClientData)
		nb, err := devattest.VerifyAssertion(policy, b, da, s, b.Counter, now, nil)
		check(err == nil, "assertion %d (%s, counter %d): devattest.VerifyAssertion: %v", i+1, a.ClientData, a.Counter, err)
		if err != nil {
			continue
		}
		check(nb.Counter == a.Counter, "binding counter now %d", nb.Counter)
		_, err = devattest.VerifyAssertion(policy, nb, da, s, nb.Counter, now, nil)
		check(errors.Is(err, devattest.ErrCounter), "the same assertion again is refused: %v", err)
		b = nb
	}
	if failures > 0 {
		fmt.Printf("%d check(s) failed\n", failures)
		os.Exit(1)
	}
	fmt.Println("the TEST iOS attester's fixture passes vettid-vault devattest")
}

func decodeAssertionAD(b []byte) []byte {
	return must(must(cbor.Decode(b)).BytesAt("authenticatorData"))
}
