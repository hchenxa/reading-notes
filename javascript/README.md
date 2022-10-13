# JavaScript

## 基础知识

### javascript加载方式

- 立即加载
    
    `<script src="script.js"></script>`
    
    会有javascript渲染阻止
    
    ![立即加载](./snapshot/%E7%AB%8B%E5%8D%B3%E5%8A%A0%E8%BD%BD.png)
- 异步加载

    `<script src="script.js" async></script>`

    只会在javascript执行是有渲染阻止

    ![异步加载](./snapshot/%E5%BC%82%E6%AD%A5%E5%8A%A0%E8%BD%BD.png)

- 延迟加载

    `<script src="script.js" defer></script>`
    
    ![延迟加载](./snapshot/%E5%BB%B6%E8%BF%9F%E5%8A%A0%E8%BD%BD.png)

### 编码规则

- 大小写区分
- 命名约定，驼峰命名（camel Case）
  - 变量小写开头
  - 对象和类用大写开头
  - 常量全部大写
  - 每条语句末尾加分号`；`
  - 充分使用注释

## 数据处理

### 变量

- var
- let

### 数据类型

- number
- string
- bool
- null
- undefined
- symbol

### 运算符

- `+` `-` `*` `/`


### 条件语句

- `if`

```javascript
if (condition) {

} else {

}

```

### 数组

```javascript
new Array()
```

一些常用方法:
- `.length()`
- `.reverse()`
- `.shift()`
- `.unshift()`
- `.pop()`
- `.push()`
- `.splice()`
- `.slice()`
- `.indexOf()`
- `.join()`

## 函数和对象

### 三种类型的函数
具名函数：调用函数名称时执行
匿名函数：特定事件触发后运行
立即调用的函数表达式：在浏览器访问时立即运行

```javascript
// 实名函数，通过函数名称显式调用
function multiply() {
    var result = 3 * 4;
    console.log("the result is: ", result);
}
multiply();
```

```javascript
// 匿名函数保存在变量中
// 将变量作为函数调用
var divided = function() {
    var result = 3 / 4;
    console.log("the result is: ", result);
}
divided();
```

```javascript
// 立即调用的函数表达式
// 浏览器加载后立即运行
(function() {
    var result = 12 / 0.75;
    console.log("the result is: ", result);
}())
```

参数和返回值

```javascript
// 参数和返回值
function sum(a, b){
    var result = a + b;
    console.log("the result is: ", result);
    return result;
}

var total = sum(3, 4)
console.log("the total is: ", total);

```

### 构建基本函数



## Javascript和DOM

## 事件

## 循环

