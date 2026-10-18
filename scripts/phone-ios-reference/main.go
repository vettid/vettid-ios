// Command phone-ios-reference writes the Go reference values of the
// iPhone's unlock secret (VAULT-MESSAGING §11.14.1 "On an iPhone",
// IOS-PLAN §6.3 and §7) that VettIDData's PhoneSecrets tests check, until
// vettid-vault's unlock.json carries its phone_ios object.
//
// The derivation uses Go's standard library only (crypto/ecdh, crypto/hkdf,
// crypto/hmac), exactly as the specification states it; the end-to-end
// values go through vettid-vault's own vms/recovery functions (unlock key,
// secret_check, dek_wrap), so that one file shows the iPhone secret
// working with the vault's unchanged formulas. Every key is fixed, public
// and TEST-ONLY.
//
// vettid-vault comes from the clone that go.mod's replace directive names; the
// command refuses to run unless that clone is checked out at vaultCommit (the
// commit SOURCE.md records), and writes the commit into its output.
//
//	go run . > ../../Packages/VettIDData/Tests/VettIDDataTests/Resources/reference/phone_ios.json
package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"runtime/debug"
	"strings"

	"github.com/vettid/vettid-vault/vms/recovery"
	"github.com/vettid/vettid-vault/vms/suite"
)

const (
	label      = "vettid/vms/2/unlock-secret-ios"
	checkLabel = "vettid/vms/2/unlock-secret-ios-check"
	keyVault   = "test-vault-0001"
	// The vettid-vault commit the fixture is generated from.
	vaultCommit = "057236379992e48e7f356b4994fc2d11c174d365"
)

// checkVaultCommit refuses a vettid-vault clone at another commit, or with
// local changes.
func checkVaultCommit() {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		panic("no build info")
	}
	for _, d := range info.Deps {
		if d.Path != "github.com/vettid/vettid-vault" || d.Replace == nil {
			continue
		}
		head := strings.TrimSpace(string(must(exec.Command("git", "-C", d.Replace.Path, "rev-parse", "HEAD").Output())))
		dirty := strings.TrimSpace(string(must(exec.Command("git", "-C", d.Replace.Path, "status", "--porcelain").Output())))
		if head != vaultCommit || dirty != "" {
			fmt.Fprintf(os.Stderr, "vettid-vault at %s (local changes: %t), want %s\n", head, dirty != "", vaultCommit)
			os.Exit(1)
		}
		return
	}
	panic("vettid-vault is not replaced by a local clone")
}

func rep(b byte, n int) []byte { return bytes.Repeat([]byte{b}, n) }

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

func h(b []byte) string { return hex.EncodeToString(b) }

// info_e = label || 0x00 || key_vault || 0x00 || epoch (8, BE) || pub(P) (65) || pub(E_e) (65)
func info(kv string, epoch uint64, pubP, pubE []byte) []byte {
	if epoch < 1 || bytes.IndexByte([]byte(kv), 0) >= 0 || len(pubP) != 65 || len(pubE) != 65 {
		panic("info input")
	}
	var e [8]byte
	binary.BigEndian.PutUint64(e[:], epoch)
	out := append([]byte(label), 0)
	out = append(out, kv...)
	out = append(out, 0)
	out = append(out, e[:]...)
	out = append(out, pubP...)
	return append(out, pubE...)
}

type epochVector struct {
	KeyVault     string `json:"key_vault"`
	Epoch        uint64 `json:"epoch"`
	PrivEHex     string `json:"priv_e_hex"`
	PubEHex      string `json:"pub_e_hex"`
	ZHex         string `json:"z_hex"`
	InfoHex      string `json:"info_hex"`
	UnlockSecret string `json:"unlock_secret_hex"`
	CheckHex     string `json:"check_hex"`
	AndroidForm  string `json:"android_form_hex"`
	UnlockKeyHex string `json:"unlock_key_hex"`
	SecretCheck  string `json:"secret_check_hex"`
	DEKWrapHex   string `json:"dek_wrap_hex"`
}

type refusal struct {
	What   string `json:"what"`
	PubHex string `json:"pub_e_hex"`
}

type doc struct {
	Description string        `json:"description"`
	VaultCommit string        `json:"vettid_vault_commit"`
	PrivPHex    string        `json:"priv_p_hex"`
	PubPHex     string        `json:"pub_p_hex"`
	VaultID     string        `json:"vault_id"`
	XHex        string        `json:"x_hex"`
	PepperHex   string        `json:"pepper_hex"`
	DEKHex      string        `json:"dek_hex"`
	DEKVersion  uint64        `json:"dek_version"`
	NonceHex    string        `json:"nonce_hex"`
	Epochs      []epochVector `json:"epochs"`
	Refusals    []refusal     `json:"refusals"`
}

func main() {
	checkVaultCommit()
	curve := ecdh.P256()
	p := must(curve.NewPrivateKey(rep(0x46, 32)))
	pubP := p.PublicKey().Bytes()
	x, pepper, dek, nonce := rep(0x41, 32), rep(0x32, 32), rep(0x35, 32), rep(0x43, 24)
	const dekVersion = 1

	vec := func(kv string, epoch uint64, privE byte) epochVector {
		e := must(curve.NewPrivateKey(rep(privE, 32)))
		pubE := e.PublicKey().Bytes()
		z := must(e.ECDH(p.PublicKey()))
		if !bytes.Equal(z, must(p.ECDH(e.PublicKey()))) {
			panic("ECDH directions differ")
		}
		in := info(kv, epoch, pubP, pubE)
		secret := must(hkdf.Key(sha256.New, z, nil, string(in), 32))
		m := hmac.New(sha256.New, secret)
		m.Write([]byte(checkLabel))
		check := m.Sum(nil)[:16]
		android := recovery.PhoneUnlockSecret(rep(0x46, 32), kv, epoch)
		if bytes.Equal(android, secret) {
			panic("iPhone form equals the Android form")
		}
		uk := must(recovery.UnlockKey(x, secret, pepper, keyVault))
		sc := must(recovery.SecretCheck(pepper, keyVault, secret))
		var v [8]byte
		binary.BigEndian.PutUint64(v[:], dekVersion)
		aad := append(append(append(append([]byte(recovery.LabelDEKWrap), 0), keyVault...), 0), v[:]...)
		wrap := append(append([]byte(nil), nonce...), must(suite.SealX(uk, nonce, aad, dek))...)
		if got := must(recovery.OpenDEK(uk, wrap, keyVault, dekVersion)); !bytes.Equal(got, dek) {
			panic("dek_wrap does not open with the vault's OpenDEK")
		}
		return epochVector{
			KeyVault: kv, Epoch: epoch, PrivEHex: h(rep(privE, 32)), PubEHex: h(pubE), ZHex: h(z), InfoHex: h(in),
			UnlockSecret: h(secret), CheckHex: h(check), AndroidForm: h(android), UnlockKeyHex: h(uk),
			SecretCheck: h(sc), DEKWrapHex: h(wrap),
		}
	}

	e1 := must(curve.NewPrivateKey(rep(0x47, 32))).PublicKey().Bytes()
	offCurve := append([]byte(nil), e1...)
	y := new(big.Int).SetBytes(offCurve[33:])
	y.Add(y, big.NewInt(1)).FillBytes(offCurve[33:])
	compressed := append([]byte{0x02 + e1[64]&1}, e1[1:33]...)
	refusals := []refusal{
		{"off the curve (x valid, y + 1)", h(offCurve)},
		{"the point at infinity", "00"},
		{"the point at infinity, 65 bytes", h(append([]byte{0x04}, rep(0, 64)...))},
		{"compressed", h(compressed)},
		{"truncated", h(e1[:64])},
		{"one byte too long", h(append(append([]byte(nil), e1...), 0))},
		{"hybrid prefix 0x06", h(append([]byte{0x06}, e1[1:]...))},
	}
	for _, r := range refusals {
		if _, err := curve.NewPublicKey(must(hex.DecodeString(r.PubHex))); err == nil {
			panic("Go accepts the refusal " + r.What)
		}
	}

	out := doc{
		Description: "VAULT-MESSAGING §11.14.1 \"On an iPhone\" (0.35.0), IOS-PLAN §6.3 and §7: the iPhone's unlock " +
			"secret from Go's crypto/ecdh, crypto/hkdf and crypto/hmac, and the same secrets through vettid-vault's " +
			"vms/recovery unlock key, secret_check and dek_wrap (x stands in for the Argon2id output). " +
			"android_form_hex is the Android form 1 for the same key bytes, which the iPhone form must differ from. " +
			"Refusals: encodings of pub(E) that Go's crypto/ecdh refuses and the app must refuse too. TEST ONLY.",
		VaultCommit: vaultCommit,
		PrivPHex:    h(rep(0x46, 32)), PubPHex: h(pubP), VaultID: keyVault,
		XHex: h(x), PepperHex: h(pepper), DEKHex: h(dek), DEKVersion: dekVersion, NonceHex: h(nonce),
		Epochs: []epochVector{
			vec(keyVault, 1, 0x47),
			vec(keyVault, 2, 0x48),
			vec("", 1, 0x47),
		},
		Refusals: refusals,
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(out); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
