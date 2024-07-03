package main

import (
	"fmt"
	"net/http"
)

func f1(w http.ResponseWriter, r *http.Request) {
	str := "hello world"
	_, err := w.Write([]byte(str))
	if err != nil {
		fmt.Printf("failed to write due to %v", err)
	}

}

// http server
func main() {
	http.HandleFunc("/path1", f1)

	err := http.ListenAndServe("127.0.0.1:9090", nil)
	if err != nil {
		fmt.Printf("failed to start the http server due to %v", err)
		return
	}
}
