---
title: 文件操作与标准库
nav_exclude: true
permalink: /go/file-io/
---

# 文件操作与标准库

## 文件操作

### 文件的读取
#### 用`os`包里面的`Read`来读取文件
```go
import os

func main() {
	// os.Open用来打开文件
	file, err := os.Open("./file")
	if err != nil {
		os.Exit(1)
	}
	
	defer file.Close()

	var (
		text make([]byte, 128)
		content []byte
	)

    // 循环读取文件
	for {
        n, err := file.Read(text)
    	if err != nil {
            if err == io.EOF {
        		return
        	}
    		fmt.Printf("failed to open the file due to %v\n", err)
    		os.Exit(1)
    	}
		content.append(content,tmp[:]...)
	}
}
```
#### 使用`bufio`读取文件
```go
import os

func main() {
	// os.Open用来打开文件
	file, err := os.Open("./file")
	if err != nil {
		os.Exit(1)
	}
	
	defer file.Close()

	reader := bufio.NewReader(file)

    // 循环读取文件
	for {
        line, err := reader.ReadString('\n')
		if err == io.EOG {
			return
		}
		if err != nil {
			os.Exit(1)
		}
		fmt.Printf("%v", line)
	}
}
```
#### 使用`ioutils.Readfile`读取文件
```go
import "io/ioutil"

func main() {
	context, err := ioutil.ReadFile("./file")
	if err != nil {
		return
	}
	fmt.Print(string(context))
}
```

### 文件的写入

#### `os.OpenFile()`函数可以以指定的模式打开文件

```go
func OpenFile(name string, flag int, perm FileMode) (*File, error) {

}
```
- name:文件名
- flag:以下这些类型

| 模式        | 含义 |
| ----------- | ---- |
| os.O_WRONLY | 只写 |
| os.O_CREATE | 创建 |
| os.O_RDONLY | 只读 |
| os.O_RDWR   | 读写 |
| os.O_TRUNC  | 清空 |
| os.O_APPEND | 追加 |
- perm:文件权限,r(04),w(02),x(01)

#### `Write`和`WriteString`
```go
func main() {
	file, err := os.OpenFile("./file.txt", os.O_CREATE|os.O_WRONLY, 0666)
	if err != nil {
		return
	}
	defer file.Close()
	str := "test"
	file.Write([]byte(str))
	file.WriteString(str)
}
```
#### `bufio.NewWrite`
```go
func main() {
	file, err := os.OpenFile("./file.txt", os.O_CREATE|os.O_WRONLY, 0666)
	if err != nil {
		return
	}
	defer file.Close()

	writer := bufio.NewWrite(file)
	writer.WriteString("text\n") // 将数据显写入缓存
	writer.Flush // 将缓存内容写入文件
}
```
#### `ioutil.WriteFile`
```go
func main() {
	str := "test"
	if err := ioutil.WriteFile("./file.txt", []byte(str), 0666); err != nil {
		return
	}
}
```

## `time`标准库

### 时间格式化
时间类型有一个自带方法Format进行时间格式化，使用的是Go语言诞生的时间`2006年1月2日15点04分`(20061234)

### `runtime.Caller`
```go
func Caller(skip int) (pc uintptr, file string, line int, ok bool)
```
- `skip`: 上溯的栈帧数，0表示Caller的调用者（0表示当前函数，-1表示上一层函数）
- `pc`: 调用栈的标识符
- `file`: 文件路径
- `line`: 文件中的行号
- `ok`: 如果无法获得信息，ok会设置成false
