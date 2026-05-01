---
title: 泛型
nav_exclude: true
permalink: /go/generics/
---

# 泛型
Go 1.18增加了对泛型的支持，允许程序员在强类型程序设计语言中便携代码时使用一些以后才需要指定的类型。

泛型为go语言添加了三个新的重要特性：
1. 函数和类型的类型参数
2. 将接口类型定义为类型集，包括没有方法的类型
3. 类型推断，允许在调用函数时在许多情况下省略类型参数

Example
```go
func min[T int | float64](a, b T) T {
	if a <= b {
		return a
	}
	return b
}
```
上main的min函数接受a,b两个形参，可以是int类型，也可以是float64类型，返回的也是int或者float64类型

调用的时候可以
```go
m1 := min[int](1, 2)
```
也可以
```go
m2 := min[float64](-0.1, -0.2)
```
类型的实例化分为两个部分
1. 编译器在整个泛型函数或类型中将所有类型形参（type parameters）替换为它们各自的类型实参（type arguments）。
2. 编译器验证每个类型参数是否满足相应的约束。

## 类型参数的使用

```go
type Slice[T int | string] []T

type Map[K int | string, V float32 | float64] map[K]V

type Tree[T interface{}] struct {
	left, right *Tree[T]
	value       T
}
```

在上述泛型类型中，T、K、V都属于类型形参，类型形参后面是类型约束，类型实参需要满足对应的类型约束。

## 类型约束

对接口类型的类型约束
```go
// 类型约束字面量，通常外层interface{}可省略
func min[T interface{int | float64}](a, b T) T {
	if a <=b {
		return a
	}
	return b
}
```
作为类型约束使用的接口类型可以事先定义并支持复用。

```go
// 事先定义好的类型约束类型
type Value interface {
	int | float64
}
func min[T Value](a, b T) T {
	if a <= b {
		return a
	}
	return b
}
```
在使用类型约束时，如果省略了外层的interface{}会引起歧义，那么就不能省略。例如：
```go
type IntPtrSlice [T *int] []T  // T*int ?
type IntPtrSlice[T *int,] []T  // 只有一个类型约束时可以添加`,`
type IntPtrSlice[T interface{ *int }] []T // 使用interface{}包裹
```

## 类型集
go 1.18开始对接口定义的类型也发生了变化，由过去的接口类型定义方法集变成了接口类型定义类型集，也就是说接口类型现在可以用作值类型，也可以用作类型约束。

从go 1.18开始，一个接口可以嵌入其他接口，也可以嵌入任何类型、类型的联合或共享相同底层类型的无限类型集合。

当用作类型约束的时候，由接口定义的类型集精确地指定允许作为相应类型参数的类型。
- `|`符号：
```go
type a interface{
	Signed | Unsigned
}
```
表示约束为类型Singed或者Unsigned类型

- `~`符号：
`~T` 表示所有底层类型是T的类型。例如`~string`表示所有底层类型是`string`的类型集合。`~`后面只能是基本类型

## 类型推断
### 函数参数类型推断
显式类型实参调用
```go
m = min[float64](a,b) //这里显示指定了类型为float64
```
在许多情况下，编译器可以从普通参数推断`T`的类型实参。
```go
var a, b, m float64
m = min(a, b) //无需指定类型实参
```
这种从实参的类型推断出函数的类型实参称为函数实参类型推断。函数实参类型推断只适用于函数参数重使用的类型参数，而不适用于仅在函数结果中或仅在函数体中使用的类型参数。

https://pkg.go.dev/golang.org/x/exp/constraints 包提供了一些常用类型

### 约束类型推断

写一个泛形函数适用于任何整数类型的测试函数
```go
func Scale[E constraints.Integer](s []E, c E) []E {
	r := make([]E, len(s))
	for i, v := range s {
		r[i] = v*c
	}
	return r
}
```
写一个调用的函数
```go
type Point []int32 // Point是个int32的切片

// 有一个Point的方法，可以吧Point转化成string
func (p Point) String() string{
	b, _ := json.Marshal(p)
	return string(b)
}

func ScaleAndPrint(p Point) {
	r := Scale(p, 2) // 这块的r是[]E类型的值
	fmt.Println(r.String()) // 这块会编译失败，输出r.String undefined (type []int32 has no field or method String的错误
}
```
上面代码的问题是，Scale返回类型为[]E的值，其中E是参数切片的元素类型.当我们使用Point类型的值调用Scale（其基础类型为[]int32）我们返回的是[]int32类型的值，不是Point类型，所以使用不了Point类型的方法.

所以Scale函数可以改为
```go
func Scale[S ~[]E, E constraints.Integer](s S, c E) S {
	r := make(S, len(s))
	for i, v := range s{
		r[i] = v * c
	}
	return r
}
```
我们需要引入一个新的类型参数`S`，它是切片参数的类型。我们对他进行了约束，使得基础类型是`S`而不是`[]E`，函数的返回类型现在是`S`。由于E约束为整数，因此效果和之前的相同。对于函数体的唯一修改是，我们在调用`make`时传递`S`，而不是`[]E`。

约束类型推断从类型参数约束推导类型参数。当一个类型参数具有根据另一个类型参数定义的约束时使用。当其中一个类型参数的类型参数已知时，约束用于推断另一个类型参数的类型参数。
