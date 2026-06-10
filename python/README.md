# Python

## 目录索引

| 主题 | 说明 |
|------|------|
| [数据类型](#数据类型) | 变量、列表、切片、元祖、字典、循环 |
| [函数](#函数) | 函数定义、参数传递、可变参数 |

---

## 数据类型
### 变量
```python
msg = "hello world"
```
命名规则: 
- 只能包括字母，数字和`_`
- 不能包括空格
- 不用使用关键字

浅拷贝和深拷贝。

普通的赋值是数据完全共享，修改变量也会修改原变量数据

浅拷贝是数据半共享，修改变量数据不会影响原来的数据, 调用`copy.copy()`来进行浅拷贝.

```python
copy.copy()
```

深拷贝不仅拷贝内部元素，好包括对象在内，调用`copy.deepcopy()`来进行深拷贝.

```python
copy.deepcopy()
```

举个例子：
```python

>>> li = [1,2,3,[4,5,6]]
>>> li1 = li
>>> li2 = copy.copy(li)
>>> li3 = copy.deepcopy(li)
>>> id(li)
4335077696
>>> id(li1)
4335077696      #可以看到这块的内存地址和原变量li是一样的
>>> id(li2)
4337386112     #内存地址发生了变化
>>> id(li3)
4337161088       #内存地址发生了变化
>>> li.append(7)
>>> print(li)
[1, 2, 3, [4, 5, 6], 7]
>>> print(li1)
[1, 2, 3, [4, 5, 6], 7]
>>> print(li2)
[1, 2, 3, [4, 5, 6]]
>>> print(li3)
[1, 2, 3, [4, 5, 6]]

>>> print(li2[3])
[4, 5, 6]
>>> print(li3[3])
[4, 5, 6]

>>> li.append(7)
>>> print(li2[3])
[4, 5, 6]
>>> print(li3[3])
[4, 5, 6]
>>> li[3].append(8)
>>> print(li2[3])      #浅拷贝里面的值发生了变化
[4, 5, 6, 8]
>>> print(li3[3])      #深拷贝的值没有变化
[4, 5, 6]
```

### 格式化小技巧
f字符串。f是format的简写

```python
name = "Michael"

msg = f"{name.title()}"
msg = f"hello, {name.title()}"
```
变量在格式化的时候需要使用{}

格式化输出的时候还可以尝试使用`sep`，比如：

```python
>>> print("今天", "明天", "后天")
今天 明天 后天
```
我们可以看到默认的输出中间的间隔用的是空格，可以使用`sep`来修改输出，比如:

```python
>>> print("今天", "明天", "后天", sep=",")
今天,明天,后天
```

print后面还可以加上`end`来作为结束，比如:

```python
>>> print("今天", "明天", "后天", end="###\n")
今天 明天 后天###
```

### 列表
#### append, insert
- insert: 列表中插入元素
- append: 列表中追加元素
#### del, pop, remove
- del: 从列表里面删除数据
- pop: 从列表里面删除数据并且吧数据赋值给其他变量（有返回值，返回值为被删除的元素）
- remove: 按照数据删除，在不知道index的情况下使用
#### sort, sorted, reverse
- sort: 永久排序， sort的时候可以使用sort(reverse=True)进行排序后的反响排序
- sorted: 临时排序
- reverse: 反向排序

### 列表遍历

```python
a = ["b", "c", "d"]
for k in a:
    print(k)
```

#### range
```python
for value in range(1, 5):
    print(value)
```

#### 列表推导式
```python
squares = [value**2 for value in range(1, 11)]
print squares
```

上面的列表推导式就等同于
```python
squares=[]
for value in range(1, 11):
    square=value**2
    squares.append(square)
```

### 切片，元祖，条件控制，字典，

元祖是不能修改的列表,用()表示
```python
squares=(one, two)
```

```python
if <>:
    print()
```
```python
if <>:
    print()
else:
    print()
```

字典的由key, value组成
```python
user = {
    'user_name': 'haha',
    'first': 'lala',
}
```
字典的遍历
```python
for key,value in user.items():
    print(key)
    print(value)
```
字典遍历所有的key
```python
for key in user.keys():
    print(key)
```
字典遍历所有的value
```python
for value in user.values():
    print(value)
```

### 循环
for 循环
```python
for <>:
    print()
```

while 循环:
```python
while True:
    print() #----------> 这是个死循环
```

break/continue:
```python
while num < 5:
    num++
    if num == 4:
        break
    print(num)
```

```python
num = input("give the num here: ")
while num < 5:
    num++
    if num % 2 == 0: ----->偶数判断
        continue
    print(num)
```

## 函数
定义
```python
def func_name():
    # func block

func_name() #------> 函数调用
```
python定义函数和调用的时候可以指定参数名(关键字实参),比如
```python
def describe_pet(animal_type, pet_name):
    print(f"n\I have a {animal_type}")
    print(f"n\My {animal_type} name is {pet_name}")

# 在调用的时候，可以这样写
describe_pet('cat', 'haha')
# 会输出I have a cat, My cat name is haha

# 为了避免参数传错了位置，我们也可以这样写
describe_pet(animal_type='cat', pet_name='haha')
```

定义函数的时候,行参也可以设置默认值。

**NOTE**: 禁止函数修改函数参数列表.比如:
```python
def print_models(unprint_designs, completed_models):
	while unprint_designs:
		current_design = unprint_designs.pop()
		completed_models.append(current_design)

unprint_designs=['a','b','c']
completed_models=[]
print_models(unprint_designs, completed_models)
```

上面的例子在调用的时候,就会修改unprint_designs的值,所以一种比较推荐的做法是
```python
unprint_designs=['a','b','c']
completed_models=[]
print_models(unprinted_designs[:], completed_models):
```
用切片来代替变量，传进去的是变量的副本。

可变参数传递:
```python
def make_pizze(*toppings):
    print(toppings)
```
行参`*toppings`中的星号让python创建一个名为toppings的元祖

可变关键字参数传递:
```python
def make_pizze(**toppings):
    print(toppings)
```
行参`**toppings`中的星号让python创建一个名为`toppings`的字典

## 查看内置函数

```python
>>> import builtins
>>> dir(builtins)
['ArithmeticError', 'AssertionError', 'AttributeError', 'BaseException', 'BaseExceptionGroup', 'BlockingIOError', 'BrokenPipeError', 'BufferError', 'BytesWarning', 'ChildProcessError', 'ConnectionAbortedError', 'ConnectionError', 'ConnectionRefusedError', 'ConnectionResetError', 'DeprecationWarning', 'EOFError', 'Ellipsis', 'EncodingWarning', 'EnvironmentError', 'Exception', 'ExceptionGroup', 'False', 'FileExistsError', 'FileNotFoundError', 'FloatingPointError', 'FutureWarning', 'GeneratorExit', 'IOError', 'ImportError', 'ImportWarning', 'IndentationError', 'IndexError', 'InterruptedError', 'IsADirectoryError', 'KeyError', 'KeyboardInterrupt', 'LookupError', 'MemoryError', 'ModuleNotFoundError', 'NameError', 'None', 'NotADirectoryError', 'NotImplemented', 'NotImplementedError', 'OSError', 'OverflowError', 'PendingDeprecationWarning', 'PermissionError', 'ProcessLookupError', 'RecursionError', 'ReferenceError', 'ResourceWarning', 'RuntimeError', 'RuntimeWarning', 'StopAsyncIteration', 'StopIteration', 'SyntaxError', 'SyntaxWarning', 'SystemError', 'SystemExit', 'TabError', 'TimeoutError', 'True', 'TypeError', 'UnboundLocalError', 'UnicodeDecodeError', 'UnicodeEncodeError', 'UnicodeError', 'UnicodeTranslateError', 'UnicodeWarning', 'UserWarning', 'ValueError', 'Warning', 'ZeroDivisionError', '__build_class__', '__debug__', '__doc__', '__import__', '__loader__', '__name__', '__package__', '__spec__', 'abs', 'aiter', 'all', 'anext', 'any', 'ascii', 'bin', 'bool', 'breakpoint', 'bytearray', 'bytes', 'callable', 'chr', 'classmethod', 'compile', 'complex', 'copyright', 'credits', 'delattr', 'dict', 'dir', 'divmod', 'enumerate', 'eval', 'exec', 'exit', 'filter', 'float', 'format', 'frozenset', 'getattr', 'globals', 'hasattr', 'hash', 'help', 'hex', 'id', 'input', 'int', 'isinstance', 'issubclass', 'iter', 'len', 'license', 'list', 'locals', 'map', 'max', 'memoryview', 'min', 'next', 'object', 'oct', 'open', 'ord', 'pow', 'print', 'property', 'quit', 'range', 'repr', 'reversed', 'round', 'set', 'setattr', 'slice', 'sorted', 'staticmethod', 'str', 'sum', 'super', 'tuple', 'type', 'vars', 'zip']
>>> 
```