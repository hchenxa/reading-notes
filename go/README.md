# go 语言学习笔记

## 标识符和关键字

golang里面的标识符由字母，数字和`_`组成，并且只能字母和`_`开头.

25个关键字
```
    break        default      func         interface    select
    case         defer        go           map          struct
    chan         else         goto         package      switch
    const        fallthrough  if           range        type
    continue     for          import       return       var

```

保留字
```
    Constants:    true  false  iota  nil

        Types:    int  int8  int16  int32  int64  
                  uint  uint8  uint16  uint32  uint64  uintptr
                  float32  float64  complex128  complex64
                  bool  byte  rune  string  error

    Functions:   make  len  cap  new  append  copy  close  delete
                 complex  real  imag
                 panic  recover

```

## 变量，常量 

### 变量声明

- 标准声明
  ```go
    var 变量名 变量类型
  ```

- 批量声明

```go
    var (
        变量名 变量类型
        变量名 变量类型
    )
```

### 变量初始化

```go
var 变量名 类型 = 表达式
var name, age = "Q1mi", 20
```

- 类型推导, 不用指定变量类型
```go
var name = "Q1mi"
var age = 18
```
- 短变量声明, 使用`:=`
```go
m := 200
```
- 匿名变量，使用`_`
```go
x, _ := foo()
```
匿名变量不占用命名空间，不会分配内存，所以匿名变量之间不存在重复声明

### 常量

```go
const (
    a = 1
)
```

### `iota`
`iota`是go语言的常量计数器，只能在常量的表达式中使用.

`iota`在const关键字出现时将被重置为0。const中每新增一行常量声明将使`iota`计数一次(iota可理解为const语句块中的行索引)。 使用iota能简化定义，在定义枚举时很有用

```go
const (
		n1 = iota //0
		n2        //1
		_
		n4        //3
	)
```
```go
const (
		n1 = iota //0
		n2 = 100  //100
		n3 = iota //2
		n4        //3
	)
	const n5 = iota //0
```
```go
const (
		_  = iota
		KB = 1 << (10 * iota)
		MB = 1 << (10 * iota)
		GB = 1 << (10 * iota)
		TB = 1 << (10 * iota)
		PB = 1 << (10 * iota)
	)
```

## 基本数据类型

```go
package main
 
import "fmt"
 
func main(){
	// 十进制
	var a int = 10
	fmt.Printf("%d \n", a)  // 10
	fmt.Printf("%b \n", a)  // 1010  占位符%b表示二进制
 
	// 八进制  以0开头
	var b int = 077
	fmt.Printf("%o \n", b)  // 77
 
	// 十六进制  以0x开头
	var c int = 0xff
	fmt.Printf("%x \n", c)  // ff
	fmt.Printf("%X \n", c)  // FF
}
```
### 字符串
Go 语言里的字符串的内部实现使用UTF-8编码。 字符串的值为双引号(")中的内容，可以在Go语言的源码中直接添加非ASCII码字符.

单引号('')用来表示的字符

多行字符串可以使用``
```go
s1 := `第一行
第二行
第三行
`
```

字符串的常用操作

- len(str) 求长度
- +或fmt.Sprintf 拼接字符串
- strings.Split	分割
- strings.contains	判断是否包含
- strings.HasPrefix,strings.HasSuffix	前缀/后缀判断
- strings.Index(),strings.LastIndex()	子串出现的位置
- strings.Join(a[]string, sep string)	join操作

### `byte`和`rune`

Go 语言的字符有以下两种：

uint8类型，或者叫 byte 型，代表一个ASCII码字符。
rune类型，代表一个 UTF-8字符。

### 修改字符串
要修改字符串，需要先将其转换成[]rune或[]byte，完成后再转换为string。无论哪种转换，都会重新分配内存，并复制字节数组。

```go
func changeString() {
	s1 := "big"
	// 强制类型转换
	byteS1 := []byte(s1)
	byteS1[0] = 'p'
	fmt.Println(string(byteS1))

	s2 := "白萝卜"
	runeS2 := []rune(s2)
	runeS2[0] = '红'
	fmt.Println(string(runeS2))
}
```

## 运算符

- 算数运算符
- 关系运算符
- 位运算符
- 赋值运算符

## 流程控制

### `if` `else`

### `for`

```go
for 初始语句;条件表达式;结束语句{
    循环体语句
}
```
### `for range`

Go语言中可以使用for range遍历数组、切片、字符串、map 及通道（channel）。 通过for range遍历的返回值有以下规律：

- 数组、切片、字符串返回索引和值。
- map返回键和值。
- 通道（channel）只返回通道内的值。

### `switch` `case`

```go
func switchDemo1() {
	finger := 3
	switch finger {
	case 1:
		fmt.Println("大拇指")
	case 2:
		fmt.Println("食指")
	case 3:
		fmt.Println("中指")
	case 4:
		fmt.Println("无名指")
	case 5:
		fmt.Println("小拇指")
	default:
		fmt.Println("无效的输入！")
	}
}
```
`fallthrough`语法可以执行满足条件的case的下一个case，是为了兼容C语言中的case设计的，用的很少,现在不建议使用。例如
```go
func switchDemo1() {
	finger := 3
	switch finger {
	case 1:
		fmt.Println("大拇指")
	case 2:
		fmt.Println("食指")
	case 3:
		fmt.Println("中指")
		fallthrough
	case 4:
		fmt.Println("无名指")
	case 5:
		fmt.Println("小拇指")
	default:
		fmt.Println("无效的输入！")
	}
}
```
输出会打印case3和case4

### `goto`

`goto`语句通过标签进行代码间的无条件跳转。`goto`语句可以在快速跳出循环、避免重复退出上有一定的帮助。Go语言中使用`goto`语句能简化一些代码的实现过程。 例如双层嵌套的for循环要退出时：

```go
func gotoDemo() {
	for i := 0; i < 10; i++ {
		for j := 0; j < 10; j++ {
			if j == 2 {
				// 设置退出标签
				goto breakTag
			}
			fmt.Printf("%v-%v\n", i, j)
		}
	}
	return
	// 标签
breakTag:
	fmt.Println("结束for循环")
}
```

### `break`

```go
func breakDemo1() {
BREAKDEMO1:
	for i := 0; i < 10; i++ {
		for j := 0; j < 10; j++ {
			if j == 2 {
				break BREAKDEMO1
			}
			fmt.Printf("%v-%v\n", i, j)
		}
	}
	fmt.Println("...")
}
```

### `continue`

```go
func continueDemo() {
forloop1:
	for i := 0; i < 5; i++ {
		// forloop2:
		for j := 0; j < 5; j++ {
			if i == 2 && j == 2 {
				continue forloop1
			}
			fmt.Printf("%v-%v\n", i, j)
		}
	}
}
```