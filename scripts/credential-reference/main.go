// Command credential-reference writes the Go reference's outputs that
// VettIDCrypto's CredentialReferenceTests check (IOS-PLAN §8 I0.8:
// credential round trips against the Go reference where VAULT-MESSAGING §16
// has no vector). Keys come from fixed, public, TEST-ONLY seeds; HPKE
// encapsulation is random in the reference, so each run seals afresh and the
// Swift side must open what it is given. Ed25519 is deterministic, so the
// rotation statements are fixed.
//
//	go run . > ../../Packages/VettIDCrypto/Tests/VettIDCryptoTests/Resources/reference/credential.json
//	go run . open <payload hex> <value hex> <grant hex>   # opens what the Swift code sealed
package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	"github.com/vettid/vettid-vault/features/credential"
	"github.com/vettid/vettid-vault/vms/credwire"
	"github.com/vettid/vettid-vault/vms/sharewire"
	"github.com/vettid/vettid-vault/vms/suite"
)

const (
	vaultID   = "test-vault-0001"
	utkID     = "0123456789abcdef"
	reqType   = "credential.unlock"
	requestID = "01JB2Z6V9K3M4N5P6Q7R8S9T30"
	grantID   = "01JB2Z6V9K3M4N5P6Q7R8S9T40"
	fetchID   = "01JB2Z6V9K3M4N5P6Q7R8S9T41"
	payload   = `{"password":"correct horse"}`
	value     = `{"fields":[{"field_id":"f1","value":"abandon abandon"}],"notes":"n"}`
	grant     = `{"item_id":"01J","version":2,"name":"Allergies","category":"medical","fields":[]}`
)

func rep(b byte) []byte { return bytes.Repeat([]byte{b}, 32) }

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

func unhex(s string) []byte { return must(hex.DecodeString(s)) }

func main() {
	ltk := must(suite.NewPrivateKey(rep(0x61)))
	reply := must(suite.NewPrivateKey(rep(0x62)))
	grantKey := must(suite.NewPrivateKey(rep(0x63)))
	if len(os.Args) == 5 && os.Args[1] == "open" {
		fmt.Printf("payload %s\n", must(credwire.OpenPayload(ltk, vaultID, utkID, reqType, requestID, unhex(os.Args[2]))))
		fmt.Printf("value %s\n", must(credwire.OpenValue(reply, vaultID, requestID, unhex(os.Args[3]))))
		fmt.Printf("grant %s\n", must(sharewire.OpenValue(grantKey, grantID, fetchID, unhex(os.Args[4]))))
		return
	}
	k1, k2, k3 := ed25519.NewKeyFromSeed(rep(0x64)), ed25519.NewKeyFromSeed(rep(0x65)), ed25519.NewKeyFromSeed(rep(0x66))
	cek := must(suite.NewPrivateKey(rep(0x67)))
	out := map[string]any{
		"description": "Outputs of vettid-vault's credwire, sharewire and features/credential (VAULT-MESSAGING §3.5.2, §3.5.4, " +
			"§3.5.5, §10.12) from fixed seeds, written by scripts/credential-reference. TEST ONLY.",
		"vault_id": vaultID, "utk_id": utkID, "type": reqType, "request_id": requestID,
		"ltk_seed_hex": hex.EncodeToString(rep(0x61)),
		"payload": payload,
		"payload_sealed_hex": hex.EncodeToString(must(credwire.SealPayload(ltk.Public(), vaultID, utkID, reqType, requestID, []byte(payload)))),
		"reply_seed_hex": hex.EncodeToString(rep(0x62)),
		"value": value,
		"value_sealed_hex": hex.EncodeToString(must(credwire.SealValue(reply.Public(), vaultID, requestID, []byte(value)))),
		"grant_seed_hex": hex.EncodeToString(rep(0x63)),
		"grant_id": grantID, "fetch_id": fetchID,
		"grant": grant,
		"grant_sealed_hex": hex.EncodeToString(must(sharewire.SealValue(grantKey.Public(), grantID, fetchID, []byte(grant)))),
		"rotation_seeds_hex": []string{hex.EncodeToString(rep(0x64)), hex.EncodeToString(rep(0x65)), hex.EncodeToString(rep(0x66))},
		"rotations": []string{
			string(must(credwire.NewKeyRotation(k1, k2)).Marshal()),
			string(must(credwire.NewKeyRotation(k2, k3)).Marshal()),
		},
		"cek_seed_hex": hex.EncodeToString(rep(0x67)),
		"cek_kid": cek.Public().Kid().String(),
		"blob_version": 3,
		"credential_blob_hex": hex.EncodeToString(must(credential.Seal(cek.Public(), vaultID, 3, []byte("correct horse"), credential.MinKDF, []byte(`{}`)))),
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(out); err != nil {
		panic(err)
	}
}
