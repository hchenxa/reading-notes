// Client verifies a message signature using the public key.
package main

import (
	"flag"
	"fmt"
	"log"

	"github.com/hchenxa/signer-sample/sign"
)

func main() {
	pubHex := flag.String("pub", "", "public key (hex)")
	sigHex := flag.String("sig", "", "signature (hex)")
	msg := flag.String("msg", "", "message to verify")
	flag.Parse()

	if *pubHex == "" || *sigHex == "" || *msg == "" {
		log.Fatal("usage: client -pub <hex> -sig <hex> -msg <message>")
	}

	ok, err := sign.Verify(*pubHex, []byte(*msg), *sigHex)
	if err != nil {
		log.Fatalf("verify error: %v", err)
	}

	if ok {
		fmt.Println("✅ Signature VALID — message is authentic and untampered.")
	} else {
		fmt.Println("❌ Signature INVALID — message or public key does not match.")
	}
}
