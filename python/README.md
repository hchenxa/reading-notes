# python


## 数据类型
### 变量
```python
msg = "hello world"
```
命名规则: 
- 只能包括字母，数字和`_`
- 不能包括空格
- 不用使用关键字

### 格式化小技巧
f字符串。f是format的简写

```python
name = "Michael"

msg = f"{name.title()}"
msg = f"hello, {name.title()}"
```
变量在格式化的时候需要使用{}

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
    print() ----------> 这是个死循环
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

func_name() ------> 函数调用
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
    print(toppings)_
```
行参`*toppings`中的星号让python创建一个名为toppings的元祖

可变关键字参数传递:
```python
def make_pizze(**toppings):
    print(toppings)_
```
行参`**toppings`中的星号让python创建一个名为toppings的字典

