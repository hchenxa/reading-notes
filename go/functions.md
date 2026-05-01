---
title: 函数
nav_exclude: true
permalink: /go/functions/
---

# 函数

```go
func 函数名(参数)(返回值类型) {
	函数体
}
```

`defer`语句会将其后面的跟随语句进行延迟处理，在`defer`归属的函数即将返回时，将延迟处理语句按照`defer`定义的**逆序**进行执行。多用于函数结束前释放资源(文件句柄，链接之类的)

![defer]({{ site.baseurl }}/go/images/defer.png)

## 高阶函数
函数本身也是一种类型，可以作为其他函数的变量，也可以作为其他函数的返回值。

## 匿名函数
没有名字的函数

## 闭包
指一个函数和与其相关的引用环境组合而成的实体。 简单的说就是`闭包=函数+引用环境`

## `panic`和`recover`

- recover()必须搭配defer使用
- defer一定要在可能引发panic的语句之前定义

## 递归
递归要有一个明确的退出条件
