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
- let 块级别本地变量，比var的变量作用域更小

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

- 具名函数：调用函数名称时执行
- 匿名函数：特定事件触发后运行
- 立即调用的函数表达式：在浏览器访问时立即运行

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

```javascript
function findBiggestFraction() {
    console.log("xxx");
}

findBiggestFraction();
```
### 参数传递
```javascript
function findBiggestFraction(a, b) {
    a > b ? console.log("the biggest fraction is: ", a):console.log("the biggest fraction is: ", b)
}

var firstFraction = 'a';
var secondFraction = 'b';
findBiggestFraction(firstFraction, secondFraction);
```
### 函数返回值
```javascript
function findBiggestFraction(a, b) {
    var result
    a > b ? result = a : result = b;
    return result
}

var firstFraction = 'a';
var secondFraction = 'b';
var result = findBiggestFraction(firstFraction, secondFraction);
console.log('The result is:', result)
```
### 匿名函数

```javascript
var theBiggest = function(a,b) {
    var result;
    a > b ? result = a : result = b;
    return result;
}

console.log(theBiggest(number1, number2));
```

### 立即调用的函数表达式
```javascript
var theBiggest = function(a,b) {
    var result;
    a > b ? result = a : result = b;
    return result;
}

console.log(theBiggest);
```
上面这个匿名函数在console中的输出会是function这个函数，不会执行。

如果想立即执行函数，可以使用()，例如：
```javascript
var theBiggest = (function(a,b)) {
    var result;
    a > b ? result = a : result = b;
    return result;
}(number1, number2)

console.log(theBiggest);
```
按照上面的方式，theBiggest就会得到函数的返回值。

### 变量作用域

- 全局作用域
- 局部作用域

### let和const

### 对象
```javascript
var test = new Object();
test.title = 'test';
test.name = 'hchen';

console.log('The object of test is:', test);

```
或者
```javascript
var test = {
    title: 'test',
    name: 'hchen'
}

console.log('The object of test is:', test);
```

### 对象构造函数

函数首字母大写来表示对象

```javascript
function Course(title, instructor, level, published, views) {
    this.title = title
    this.instructor = instructor
    this.level = level
    this.published = published
    this.views = views
    this.updateViews = function() {
        return ++this.views
    }
}

var course01 = new Course("test1", "hchenxa", 1, true, 0)
console.log(course01)

var course02 = new Course("test2", "hchenxa", 1, true, 5)
console.log(course02)

var courses= [
    new new Course("test1", "hchenxa", 1, true, 0),
    new Course("test2", "hchenxa", 1, true, 5)
]

console.log(courses)
console.log(courses[1].title)
courses[1].updateViews()
console.log(courses[1].views)
```

### 点和括号的表示法

括号可以用来处理特殊字符，比如`course["test:var"]`, 这种是句点处理不了的。


### 闭包

内部函数依赖于外部函数的变量来工作。

```javascript
function giveMeEms(pixels) {
    var baseValue = 16;
    function doTheMath() {
        return pixels/baseValue;
    }
    return doTheMath;
}

var s = giveMeEms(12);
var m = giveMeEms(18);
var l = giveMeEms(24);
var xl = giveMeems(32);

console.log("s: ", s());
console.log("m: ", m());
console.log("l: ", l());
console.log("xl: ", xl());

```

## Javascript和DOM

### DOM: 文档对象模型

- BOM 浏览器对象模型
- DOM 文档对象模型

![节点树](./snapshot/tree.png)

### 使用querySelector方法定位DOM中的目标元素

```javascript
// 获取匹配选择器的第一个元素
document.querySelector(".main-nav a")

// 获取匹配选择器的所有元素的数组
document.querySelectorAll(".post-content p")
```
### 访问和修改元素


### 访问和修改类

### 访问和修改属性

### 添加DOM元素

### 将内联CSS应用到元素


## 事件

## 循环

