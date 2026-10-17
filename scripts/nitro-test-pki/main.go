// Command nitro-test-pki writes the TEST-ONLY certificate chain that
// VettIDAttestation's tests sign fake NSM documents with: root, intermediate
// and leaf, all P-384 and signed with ECDSA-SHA384, shaped like AWS Nitro's
// (basic constraints and key usage critical), valid from 2026-01-01 for ten
// years. The private keys are the fixed, public scalars 48 × 0x31, 0x32 and
// 0x33, so the tests can sign with the leaf key; these certificates anchor
// nothing outside the tests.
//
//	go run . > ../../Packages/VettIDAttestation/Tests/VettIDAttestationTests/Resources/nitro/test-pki.json
package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"os"
	"time"
)

func key(b byte) *ecdsa.PrivateKey {
	k, err := ecdsa.ParseRawPrivateKey(elliptic.P384(), bytes.Repeat([]byte{b}, 48))
	if err != nil {
		panic(err)
	}
	return k
}

func cert(serial int64, subject string, pub *ecdsa.PublicKey, ca bool, parent *x509.Certificate, signer *ecdsa.PrivateKey) *x509.Certificate {
	notBefore := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	t := &x509.Certificate{
		SerialNumber:          big.NewInt(serial),
		Subject:               pkix.Name{CommonName: subject},
		NotBefore:             notBefore,
		NotAfter:              notBefore.AddDate(10, 0, 0),
		BasicConstraintsValid: true,
		IsCA:                  ca,
		SignatureAlgorithm:    x509.ECDSAWithSHA384,
	}
	if ca {
		t.KeyUsage = x509.KeyUsageCertSign | x509.KeyUsageCRLSign
	} else {
		t.KeyUsage = x509.KeyUsageDigitalSignature
	}
	if parent == nil {
		parent = t
	}
	der, err := x509.CreateCertificate(rand.Reader, t, parent, pub, signer)
	if err != nil {
		panic(err)
	}
	c, err := x509.ParseCertificate(der)
	if err != nil {
		panic(err)
	}
	return c
}

func main() {
	rootKey, interKey, leafKey := key(0x31), key(0x32), key(0x33)
	root := cert(1, "test.nitro-root", &rootKey.PublicKey, true, nil, rootKey)
	inter := cert(2, "test.nitro-inter", &interKey.PublicKey, true, root, rootKey)
	leaf := cert(3, "test.nitro-leaf", &leafKey.PublicKey, false, inter, interKey)
	b64 := base64.StdEncoding.EncodeToString
	out := map[string]any{
		"description":     "TEST-ONLY P-384 chain for fake NSM documents (scripts/nitro-test-pki); keys are the public scalars 48 x 0x31, 0x32, 0x33.",
		"root_der_b64":    b64(root.Raw),
		"inter_der_b64":   b64(inter.Raw),
		"leaf_der_b64":    b64(leaf.Raw),
		"leaf_scalar_hex": "33" + string(bytes.Repeat([]byte("33"), 47)),
		"not_before":      "2026-01-01T00:00:00Z",
		"not_after":       "2036-01-01T00:00:00Z",
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(out); err != nil {
		panic(err)
	}
}
