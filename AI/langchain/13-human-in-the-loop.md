# Human-in-the-loop

LangGraph 的 Human-in-the-loop（人机协同）机制让 graph 在执行过程中暂停，等待人工输入或审批后再继续。这是实现安全可控的 AI 工作流的关键能力。

## 核心 API

| API | 作用 | 使用位置 |
|---|---|---|
| `interrupt(value)` | 暂停 graph 执行，向调用方暴露 value | 节点内部 |
| `Command(resume=val)` | 提供 resume 值让 interrupt 恢复，作为其返回值 | 调用方 |
| `Command(update=dict)` | 恢复执行的同时更新 graph state | 调用方 |
| `Command(goto=node)` | 恢复时跳转到指定节点（跳过后续节点） | 调用方 |
| `interrupt_before=[nodes]` | `compile()` 时指定在哪些节点前自动暂停 | compile 配置 |
| `app.get_state(config)` | 获取当前线程的 StateSnapshot（含中断信息） | 调用方 |
| `app.update_state(config, values)` | 在外部修改当前线程的 state | 调用方 |
| `app.get_state_history(config)` | 查看当前线程的所有 checkpoint 历史 | 调用方 |

> **前提条件：** 所有 human-in-the-loop 功能**必须**配合 checkpointer 使用。

## 终端交互式模式

在终端中实现 human-in-the-loop 的核心模式是：

1. 用 `app.stream()` 替代 `app.invoke()` 以便捕获中断事件
2. 检测 chunk 中的 `__interrupt__` 字段
3. 用 `input()` 在终端提示用户输入
4. 用 `Command(resume=user_input)` 恢复执行

```python
from langgraph.types import Command, interrupt

def my_node(state):
    result = interrupt({"question": "是否继续?", "options": ["yes", "no"]})
    return {"user_input": result}

# 运行部分
for chunk in app.stream(input_data, config):
    if "__interrupt__" in chunk:
        interrupts = chunk["__interrupt__"]
        for it in interrupts:
            print(it.value)                     # 显示中断信息
            user_input = input("> 你的决定: ")  # 终端输入

        # 恢复执行
        for chunk in app.stream(Command(resume=user_input), config):
            # 处理后续输出
            pass
```

## 使用模式

### 1. 终端确认/拒绝

节点内调用 `interrupt()`，终端捕获后提示用户输入 yes/no：

```python
def review_node(state):
    result = interrupt({"question": "请确认是否继续", "options": ["yes", "no"]})
    return {"confirmed": result == "yes"}
```

流程：
```
用户请求 → Graph 执行 → interrupt暂停 → 终端显示"是否确认？"
  → 用户输入 yes → Command(resume="yes") → Graph 继续执行
```

### 2. 终端审批工具调用

通过 `interrupt_before=["tools"]` 让 graph 在执行工具前自动暂停，人工审批后再放行：

```python
app = workflow.compile(
    checkpointer=MemorySaver(),
    interrupt_before=["tools"],  # 在 tools 节点前停下
)

# 捕获 tool call 信息，让用户决定
# 允许 → app.stream(None, config) 继续执行
# 拒绝 → app.invoke(Command(update=...), config) 返回拒绝消息
```

流程：
```
用户请求转账 → Agent 生成 tool call → 显示参数 → 终端询问"是否允许？"
  → 输入 yes → 执行转账
  → 输入 no  → 返回"操作已拒绝"
```

### 3. get_state / update_state — 外部检查和修改

在 graph 暂停时，调用方可以检查和修改 state：

```python
# 查看当前状态
snapshot = app.get_state(config)
snapshot.values      # 当前 state 数据
snapshot.next        # 即将执行的节点名
snapshot.tasks       # 当前 pending 的任务
snapshot.interrupts  # 中断信息

# 修改当前状态（在外部插入人工消息）
app.update_state(config, {"messages": [HumanMessage(content="人工修正")]})

# 查看所有历史 checkpoint
for state in app.get_state_history(config):
    print(state.metadata.get("step"))
```

### 4. 多步确认流

多个节点各自包含 `interrupt()`，终端依次确认每一步：

```python
def step_a(state):
    interrupt({"question": "执行步骤 A？"})
    return {"messages": [("ai", "步骤 A 完成")]}

def step_b(state):
    interrupt({"question": "执行步骤 B？"})
    return {"messages": [("ai", "步骤 B 完成")]}
```

### 5. Command + update 组合

恢复中断的同时更新 state：

```python
output = app.invoke(
    Command(
        resume="approve",
        update={"messages": [("ai", "审批通过，已记录日志")]},
    ),
    config,
)
```

## 注意事项

1. **必须启用 checkpointer** — interrupt 依赖 checkpoint 来保存中断点
2. **节点会重新执行** — 用 `Command(resume=...)` 恢复时，包含 `interrupt()` 的节点会从头重新执行
3. **多个 interrupt** — 一个节点内可以调用多次 `interrupt()`，LangGraph 按调用顺序匹配 resume 值
4. **流式 vs 同步** — 生产环境推荐用 `app.stream()` 而非 `app.invoke()` 实现异步中断处理
5. **interrupt_before 恢复** — `interrupt_before` 暂停后直接传 `None` 恢复：`app.invoke(None, config)`，不需要 `Command(resume=None)`
