package main

import (
	"fmt"
	"net"
	"os"
)

func main() {
	// 1. 创建listener
	listen, err := net.Listen("tcp", "127.0.0.1:30000")
	if err != nil {
		fmt.Printf("failed to create the listen due to err: %v", err)
		os.Exit(1)
	}
	defer listen.Close()

	// 2.等待链接
	for {
		conn, err := listen.Accept()
		if err != nil {
			fmt.Printf("failed to accept the listen due to err: %v", err)
			os.Exit(1)
		}

		// 3.通信
		var tmp [128]byte
		n, err := conn.Read(tmp[:])
		if err != nil {
			fmt.Printf("failed to read the connection due to err: %v", err)
			os.Exit(1)
		}
		fmt.Printf(string(tmp[:n]))
	}
}
