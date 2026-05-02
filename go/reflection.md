# 反射

反射是指在程序运行期间对程序本身进行访问和修改的能力。程序在编译时，变量被转换为内存地址，变量名不会被编译器写入到可执行部分。在运行程序时，程序无法获取自身的信息。

支持反射的语言可以在程序编译期间将变量的反射信息，如字段名称，类型信息，结构体信息等整合到可执行文件中，并给程序提供接口访问反射信息，这样就可以在程序运行期间获取类型的反射信息，并且有能力修改他们。

## `reflect`

在GO语言中，任何接口的值都可以理解为由`reflect.Type`和`reflect.Value`两部分组成，并且`reflect`包提供了`reflect.TypeOf`和`reflect.ValueOf`来获取任意对象的值和类型。

## `TypeOf`

`reflect.TypeOf`返回的是`reflect.Type`类型，其中包含的是原始值的类型信息。

`reflect.TypeOf.Name()`和`reflect.TypeOf.Kind()`
```go
type Sample struct {}

func reflectType(x interface{}) {
	v:=reflect.TypeOf(x)

	v.Name() // 返回的是类型的名称，这里返回的是Sample
	v.Kind() // 返回的是类型, 这里返回的是struct
}
func main() {
	var c = Sample{}
	reflectType(c)	
}
```

## `ValueOf`

`reflect.ValueOf()`返回的是`reflect.Value`类型，其中包含了原始值的值信息。

```go
type Sample struct {
	name string
	age int
}

func reflectValue(x interface{}) {
	v:=reflect.ValueOf(x)

	v.Kind() // 返回的是ValueOf的类型
}
func main() {
	var c = Sample{
		name: "test",
		age: 10,
	}
	reflectValue(c)	
}
```

## 通过反射设置变量的值

反射中可以通过专有的`Elem()`方法来获取指针对应的值。
```go
func reflectSetValue(x interface{}) {
	// x 这里传进来的是指针
	v:=reflect.ValueOf(x)
	if v.Elem().Kind() == reflect.Int64 {
  		v.Elem().SetInt(200)
	}
}
```

## `isNil()`和`isValid()`

- `isNil()` 报告v持有的值是否为nil
- `isValid()` 返回v是否持有值

## 结构体反射
任意值通过`reflect.TypeOf()`获取反射对象信息后，如果它的类型是结构体，可以通过反射值对象`reflect.Type`的`NumField()`和`Field()`方法获得结构成员的详细信息。
