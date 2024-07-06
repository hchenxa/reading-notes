package main

import (
	"fmt"
	"net/http"
	"text/template"
	"time"

	"github.com/gin-gonic/gin"
)

// Example 1: AsciiJSON
// func main() {
// 	r := gin.Default()
// 	r.GET("/example1", func(c *gin.Context) {
// 		data := map[string]interface{}{
// 			"message": "哈哈",
// 		}
// 		// 输出{"message":"\u54c8\u54c8"}
// 		c.AsciiJSON(http.StatusOK, data)
// 	})
// r.Run() // 默认监听的是8080端口
// }

// Example 2: HTML 渲染
func main() {
	// 使用 LoadHTMLGlob() 或者 LoadHTMLFiles()
	// r := gin.Default()
	// r.LoadHTMLGlob("templates/*")
	// r.GET("/ping", func(c *gin.Context) {
	// 	c.HTML(http.StatusOK, "index.tmpl", gin.H{
	// 		"title": "haha",
	// 	})
	// })
	// r.Run()

	// 不同目录下名称相同的模版
	// r := gin.Default()
	// r.LoadHTMLGlob("templates/example2/**/*")
	// r.GET("/example2/a1", func(c *gin.Context) {
	// 	c.HTML(http.StatusOK, "a1/index.tmpl", gin.H{
	// 		"title": "a1",
	// 	})
	// })
	// r.GET("/example2/a2", func(c *gin.Context) {
	// 	c.HTML(http.StatusOK, "a2/index.tmpl", gin.H{
	// 		"title": "a2",
	// 	})
	// })
	// r.Run(":8888")

	// 自定义模版渲染器
	r := gin.Default()
	r.Delims("{[{", "}]}")
	r.SetFuncMap(template.FuncMap{
		"formatAsDate": formatAsDate,
	})

	// r.LoadHTMLFiles("templates/example2/raw.tmpl")
	r.LoadHTMLGlob("templates/example2/*.tmpl")
	r.GET("/raw", func(c *gin.Context) {
		c.HTML(http.StatusOK, "raw.tmpl", map[string]interface{}{
			"now": time.Date(2017, 07, 01, 0, 0, 0, 0, time.UTC),
		})
	})
	r.Run()
}

func formatAsDate(t time.Time) string {
	year, month, day := t.Date()
	return fmt.Sprintf("%d/%02d/%02d", year, month, day)
}
