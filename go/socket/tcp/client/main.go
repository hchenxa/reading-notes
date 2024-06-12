package main

import (
	"fmt"
	"net"
)

func main() {
	conn, err := net.Dial("tcp", "127.0.0.1:30000")
	if err != nil {
		fmt.Printf("failed to create the connection due to %v", err)
	}
	defer conn.Close()

	conn.Write([]byte("hello world"))
}
