// Server generates a key pair and signs a message.
package main

import (
	"flag"
	"fmt"
	"log"

	"github.com/hchenxa/signer-sample/sign"
)

func main() {
	msg := flag.String("msg", "hello, this is a signed message", "message to sign")
	flag.Parse()

	privHex, pubHex, err := sign.GenerateKey()
	if err != nil {
		log.Fatalf("generate key: %v", err)
	}

	sigHex, err := sign.Sign(privHex, []byte(*msg))
	if err != nil {
		log.Fatalf("sign: %v", err)
	}

	fmt.Printf("Public key:  %s\n", pubHex)
	fmt.Printf("Signature:   %s\n", sigHex)
	fmt.Printf("Message:     %s\n", *msg)
	fmt.Println()
	fmt.Println("Run the client to verify:")
	fmt.Printf("  go run ./cmd/client -pub %s -sig %s -msg %q\n", pubHex, sigHex, *msg)
}
