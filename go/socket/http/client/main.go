package main

import (
	"crypto/tls"
	"fmt"
	"net/http"
	"time"
)

// http client

func main() {

	// option1:
	resp, err := http.Get("https://www.baidu.com")
	if err != nil {
		fmt.Printf("failed to get http request due to %v", err)
		return
	}
	defer resp.Body.Close()

	// option2:
	httpClient := http.Client{
		Timeout: time.Second * 10,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify: true,
			},
		},
	}
	req, err := http.NewRequest("GET", "https://www.baidu.com", nil)
	if err != nil {
		fmt.Printf("failed to init http request due to %v", err)
		return
	}
	resp, err = httpClient.Do(req)
	if err != nil {
		fmt.Printf("failed to get http request due to %v", err)
		return
	}
	defer resp.Body.Close()
}
