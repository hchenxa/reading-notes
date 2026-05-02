# 单元测试与调试

## 单元测试

以`_test.go`结尾，不会被`go build`编译到最终的可执行程序中。

在`_test.go`中，有三种类型的函数：
- 测试函数. 函数名前缀为`Test`, 用来检查程序的一些逻辑
- 基准函数. 函数名前缀为`Benchmark`, 用来测试函数性能
- 示例函数. 函数名前缀为`Example`, 提供示例文档

`go test`执行的时候会遍历所有的`_test.go`文件，然后生成一个临时的main包来调用响应的测试函数。然后构建，运行并生成测试报告。

### 子测试

给测试组的结构体定义成一个map对象, map对象里面的每个case有个名字，测试的时候就可以通过使用`t.Run()`来按照名字执行

```go
tc := map[string]test{
	"case1": {input: "", output: ""},
	"case2": {input: "", output: ""},
	"case3": {input: "", output: ""}
}
for n, t := range tc {
	t.Run(name, func(t *testing.T)
    	{
          // assert
    	}
	) 
}
```

`go test -run="Test/case1"` 可以单独跑某一个case

### 测试覆盖率
- `go test -cover`
- `go test -cover -coverprofile=xxx.out`
- `go tool cover` 可以用来生成图形化报告

### Setup 和 TearDown
#### TestMain

通过在`*_test.go`文件中定义`TestMain`函数来可以在测试之前进行额外的设置或者测试之后进行拆解操作。

如果测试文件包含函数`func TestMain(m *testing.M)`， 那么生成的测试会先调用`TestMain(m)`，然后在运行测试。`TestMain`运行在主`goroutine`中，可以在调用`m.Run`前后做任何设置`setup`和拆解`teardown`.退出的时候使用`m.Run`的返回值作为参数调用`os.Exit`。

```go
func TestMain(m *testing.M) {
	fmt.Printf("write the setup code here...")
	// 如果 Test Main使用了flags, flag.Parse()并不会调用，所以要在这里显示的调用flag.Parse()

	retCode := m.Run() // 运行测试

	fmt.Print("write the teardown code here...")
	os.Exit(retCode)  // 退出测试
}
```

#### 子测试的setup和teardown

当我们需要为每个测试设置setup和teardown的时候
```go
func setupTestCase(t *testing.T) func(t *testing.T){
	t.log("这里开始写setup的东西")
	return func(t *testing.T) {
		t.log("最后这块写teardown的东西")
	}
}
```

例如
```go
func TestA(t *testing.T) {
	tc := map[string]struct{
		"case1": {input: "", output: ""},
		"case2": {input: "", output: ""},
	}

	for name, t := range tc {
		t.Run(name, func(t *testing.T)) {
			setupTest(t)
			// run func here
			defer teardownSetupTest(t)
		}
	}

}
```

## pprof调试工具

- `runtime/pprof`; 采集工具型应用运行数据进行分析
- `net/http/pprof`: 采集服务型应用运行时数据进行分析

pprof开启以后，每隔一段时间(10ms)会收集一下当前的堆栈信息，获取各个函数的CPU占用情况和内存资源；最后形成一个性能分析报告。pprof只在做性能测试的时候才能引入

### CPU性能分析

开启CPU性能分析
```go
pprof.StartCPUProfile(w io.Writer)
```

停止CPU性能分析
```go
pprof.StopCPUProfile()
```

应用技术后，会生成一个文件，保存我们的CPU profiling数据. 得到采样数据之后，使用`go tool pprof`工具进行性能分析。

### 内存性能分析

```go
pprof.WriteHeapProfile(w io.Writer)
```
