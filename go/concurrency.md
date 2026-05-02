# 并发编程

## 并发
Go语言的并发通过`goroutine`实现，`goroutine`类似于线程，属于用户态的线程，我们可以根据需要创建成千上万的`goroutine`并发工作。`goroutine`是由Go语言的运行时`runtime`调度完成的，而线程是由操作系统调度完成的。

Go语言还提供了`channel`在多个`goroutine`间进行通信。

### `sync.WaitGroup`

- `sync.WaitGroup.Add()`
- `sync.WaitGroup.Done()`
- `sync.WaitGroup.Wait()`

### `goroutine`和线程

`goroutine`是可增长的栈，操作系统线程一般都有固定的栈内存（通常是2MB），一个`goroutine`的栈在其生命周期开始的时候只有很小的栈（典型情况是**2KB**），`goroutine`的栈可以按需增大和缩小。

### `goroutine`调度

`GMP`是GO语言`runtime`层面实现的，是GO语言自己实现的一套调度系统。

- G:就是个`goroutine`,除了存放本`goroutine`的信息外，还有与所在P的绑定信息
- M:是Go运行时候对操作系统的虚拟，和内核线程是映射关系，一个`goroutine`最终是要放在M上执行
- P:管理着一组`goroutine`队列，存放了当前`goroutine`运行的上下文环境(函数指针，堆栈地址，地址边界),P会对自己管理的`goroutine`队列做一些调度(比如把占有CPU时间长的`goroutine`暂停来运行后续的`goroutine`等)，当自己的队列消费完了，就去全局的队列里取，如果全局的队列里也消费完了，会去其他的P的队列里面抢占任务。

P管理着一组G挂在M上运行，当一个G长久阻塞在一个M上，`runtime`会新建一个M，阻塞G所在的P会把其他的G挂载在新的M上，当旧的G阻塞完成后会这认为其死亡的时候，回收旧的M。

P的个数是通过`runtime.GOMAXPROCS`设定.

m:n调度技术: 把m个`goroutine`调度到n个OS线程。特点是`goroutine`的调度是在用户态下完成的，不涉及内核态与用户态之前的切换，包括内存的分配和释放，都是在用户态维护着一块大的内存池，不直接调用系统的`malloc`函数，成本比调度OS线程低很多。另外充分利用了多核的硬件资源，近似的把若干`goroutine`均分在物理线程上，在加上本身`goroutine`的超轻量，保证了go调度方面的性能。

- 一个操作系统线程对应用户态多个`goroutine`.
- go程序可以同时使用多个操作系统线程.
- `goroutine`和OS线程使多对多的关系, 即`m:n`.

### `channel`

GO语言的并发模型是CSP（Communication Sequential Processes）,提倡通过**通信共享内存**而不是通过共享内存而实现通信。

GO语言的channel使一个特殊的类型，按照FIFO的规则，保证收发数据的顺序。每一个通道都是一个具体类型的导管，也就是声明channel的时候需要为其制定元素类型。

```go
var 变量名 chan 类型
```
`channel`是引用类型，声明后需要使用`make`函数初始化后才能使用.
```go
make(chan 类型, [缓冲大小])
```

`channel`的三个方法
- 发送
```go
ch <- 10 // 把10发送到ch中
```
- 接收
```go
x := <- ch // 从ch中接收值并赋值给变量x
<- ch // 从ch中接收值，忽略
```
- 关闭
```go
close(ch) // 关闭channel
```

### 单向通道

适用于不同任务函数中使用通道对其发送或者接收的限制，比如只能发送或者接收。

其中,`chan <- 类型`是一个只能发送的通道，可以发送但不能接受; `<- chan 类型`是一个只能接受的通道，可以接受但不能发送。

### `select`多路复用

在某些场景下我们需要同时从多个通道接受数据。通道在接受数据的时候，如果没有数据可以接受将发生阻塞。 Go语言内置了`select`来同时相应多个通道的操作。
```go
select {
	case <- ch1:
		...
	case data := <- ch2:
		...
	case ch3 <- data:
		...
	default:
		...
}
```

## 互斥锁

是一种常用的控制共享资源访问的方法，能够保证同时只有一个`goroutine`可以访问共享资源. GO语言使用`Mutex`类型来实现互斥锁。
```go
var lock sync.Mutex

func add() {
	lock.Lock() // 加锁
	lock.Unlock() // 解锁
}
```
使用互斥锁能够保证同一时间有并且只有一个`goroutine`进入临界区，其他的`goroutine`则在等待锁；当互斥锁释放了以后，等待的`goroutine`才可以获取锁进去临界区，多个`goroutine`同时等待一个锁的时候，唤醒锁是随机的。

## 读写互斥锁

互斥锁是完全互斥的，但有些场景下是读多写少，当并发的去读取一个资源不涉及资源修改的时候是没有必要加锁的，这种场景下用读写锁是更好的一种选择。

读写锁有两种：读锁和写锁。当一个`goroutine`获取读锁后，其他的`goroutine`如果是获取读锁会继续获得锁，如果获得写锁就会等待；当一个`goroutine`获取写锁之后，其他的`goroutine`无论事获取读锁还是写锁都会等待。

读写锁示例:
```go
var rwlock sync.RWMutex

func add() {
	rwlock.RLock()
	rwlock.RUnlock()
	rwlock.Lock()
	rwlock.Unlock()
}
```

### `sync.Once`

在某些场景下，有些操作只需要做一次，比如加载配置文件，关闭一次通道之类的.

多个`goroutine`并发调用函数的时候并不是并发安全的，现代的编译器和CPU可能会在保证每个`goroutine`都满足串行一致的基础上自由的重排访问内存的顺序。

Go语言中`sync`包中提供了一个针对只执行一次场景的解决方案- `sync.Once`.

`sync.Once`只有一个`Do`方法，签名如下:
```go
func (o *Once) Do (f func()) {}
```

### `sync.Map`

Go语言内置的`map`不是并发安全的。

多数用来处理多个`goroutine`并发执行的时候报错`fatal error: concurrent map writes` 

Go语言内置了`sync.Map`, 同时`sync.Map`内置了`Store`, `Load`, `LoadOrStore`, `Delete`, `Range`等操作方法。

比如不用单独的实现map的key的操作函数，可以使用上面这些内置函数来对map进行操作

### `atomic`包

当有多个goroutine操作某个全局变量的时候，会发生某些goroutine在操作的时候，其他的goroutine可能还没有完成对全局变量的修改，一般来说，可以通过添加读写锁的操作还避免这种问题，但也可以使用内置的原子操作。

例如：
```go
var (
  x int64
  wg sync.WaitGroup
)

func main() {
	wg.Add(100)
	for i:0; i<=100; i++ {
		go func() {
			x++
			wg.Done()
		}
	}
	wg.Wait()
}
```
上面的代码可能出现x在还没累加的时候就被其他的goroutine调用了，所以可能得到的结果不是5050

options1: 通过读写锁的处理
```go
var (
  x int64
  wg sync.WaitGroup
  lock sync.Mutex
)

func main() {
	wg.Add(100)
	for i:0; i<=100; i++ {
		go func() {
			lock.Lock()
			x++
			lock.Unlock()
			wg.Done()
		}
	}
	wg.Wait()
}
```
option2: 通过原子操作
```go
var (
  x int64
  wg sync.WaitGroup
)

func main() {
	wg.Add(100)
	for i:0; i<=100; i++ {
		go func() {
			atomic.AddInt64(&x, 1)
			wg.Done()
		}
	}
	wg.Wait()
}
```
