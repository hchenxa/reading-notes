// Package sign provides Ed25519 signing and verification.
package sign

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"fmt"
)

// GenerateKey creates a new Ed25519 key pair.
// Returns the private key (seed+suffix) and public key as hex strings.
func GenerateKey() (privHex, pubHex string, err error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", "", fmt.Errorf("generate key: %w", err)
	}
	return hex.EncodeToString(priv), hex.EncodeToString(pub), nil
}

// Sign signs the message with the hex-encoded Ed25519 private key.
// Returns the hex-encoded signature.
func Sign(privHex string, msg []byte) (string, error) {
	priv, err := hex.DecodeString(privHex)
	if err != nil {
		return "", fmt.Errorf("decode private key: %w", err)
	}
	if len(priv) != ed25519.PrivateKeySize {
		return "", fmt.Errorf("private key length %d, expected %d", len(priv), ed25519.PrivateKeySize)
	}
	sig := ed25519.Sign(ed25519.PrivateKey(priv), msg)
	return hex.EncodeToString(sig), nil
}

// Verify checks the signature against the message and hex-encoded public key.
func Verify(pubHex string, msg []byte, sigHex string) (bool, error) {
	pub, err := hex.DecodeString(pubHex)
	if err != nil {
		return false, fmt.Errorf("decode public key: %w", err)
	}
	if len(pub) != ed25519.PublicKeySize {
		return false, fmt.Errorf("public key length %d, expected %d", len(pub), ed25519.PublicKeySize)
	}
	sig, err := hex.DecodeString(sigHex)
	if err != nil {
		return false, fmt.Errorf("decode signature: %w", err)
	}
	return ed25519.Verify(ed25519.PublicKey(pub), msg, sig), nil
}
