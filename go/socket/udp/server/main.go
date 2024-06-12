package main

import (
	"fmt"
	"net"
	"strings"
)

func main() {
	listen, err := net.ListenUDP("udp",
		&net.UDPAddr{
			IP:   net.IPv4(127, 0, 0, 1),
			Port: 30000,
		})
	if err != nil {
		fmt.Printf("failed due to %v\n", err)
	}
	defer listen.Close()

	// 不需要建立链接，直接收发数据
	for {
		// 读数据
		var data [1024]byte
		n, addr, err := listen.ReadFromUDP(data[:])
		if err != nil {
			fmt.Printf("failed to read data due to %v", err)
		}
		fmt.Printf("data: %v, addr: %v, count: %v\n", string(data[:n]), addr, n)

		// 回复数据
		reply := strings.ToUpper(string(data[:n]))

		_, err = listen.WriteToUDP([]byte(reply), addr)
		if err != nil {
			fmt.Printf("failed to write to UDP due to %v\n", err)
		}
	}
}
