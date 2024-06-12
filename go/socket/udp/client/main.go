package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
)

func main() {
	udpConn, err := net.DialUDP("udp", nil, &net.UDPAddr{
		IP:   net.IPv4(127, 0, 0, 1),
		Port: 30000,
	})

	if err != nil {
		fmt.Printf("failed to dial the UDP due to %v\n", err)
	}

	defer udpConn.Close()

	var data [1024]byte
	reader := bufio.NewReader(os.Stdin)
	for {
		fmt.Print("please input the data you want to sent:")
		msg, _ := reader.ReadString('\n')
		n, err := udpConn.Write([]byte(msg))
		if err != nil {
			fmt.Printf("failed to write the data due to %v\n", err)
		}
		// 读数据
		n, _, err = udpConn.ReadFromUDP(data[:])
		if err != nil {
			fmt.Printf("failed to read the data due to %v\n", err)
			return
		}
		fmt.Printf("the data is %v\n", string(data[:n]))
	}

}
