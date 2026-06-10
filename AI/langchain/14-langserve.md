# LangServe — 部署 LangChain/LangGraph 为 REST API

## 概述

[LangServe](https://python.langchain.com/docs/langserve) 是 LangChain 官方的部署框架，可以把任何 `Runnable`（含 `CompiledStateGraph`）一键包装成 REST API。

## 核心功能

| 端点 | 方法 | 说明 |
|---|---|---|
| `/invoke` | POST | 同步调用 |
| `/stream` | POST | SSE 流式调用 |
| `/batch` | POST | 批量调用 |
| `/stream_log` | POST | 带日志的流式调用 |
| `/playground` | GET | 交互式 Playground UI |
| `/docs` | GET | OpenAPI / Swagger 文档 |

## 快速开始

```bash
# 安装
pip install langserve fastapi uvicorn sse-starlette httpx

# 启动服务器
python langserve/01-server.py

# 另一个终端：运行客户端
python langserve/01-client.py
```

## 服务器代码结构

```python
from langserve import add_routes
from fastapi import FastAPI

# 1. 构建 LangGraph
graph = builder.compile(checkpointer=MemorySaver())

# 2. 创建 FastAPI 应用
app = FastAPI()

# 3. 添加 LangServe 路由
add_routes(
    app,
    graph,
    path="/approval",
)
```

## Human-in-the-loop 的 API 设计

### 问题

标准的 `/invoke` 端点在 graph 被 `interrupt()` 中断时会返回带 `__interrupt__` 键的响应。但继续执行时需要传入 `Command(resume=...)` 对象，而 `Command` 不是标准 JSON 可序列化类型。

### 解决方案

使用两个自定义端点：

**`POST /approval/start?query=...`** — 发起审批

- 内部调用 `graph.invoke()`
- 检测返回值的 `__interrupt__` 键
- 返回 `{thread_id, status, interrupt}` 给客户端

**`POST /approval/resume`** — 恢复审批

- 接受 `{thread_id, resume_value}`
- 内部构造 `Command(resume=resume_value)` 恢复 graph
- 返回最终结果

### 客户端交互流程

```
用户: "给张三转1000元"
  ↓ POST /approval/start
服务器: {status: "interrupted", thread_id: "xxx", interrupt: {...}}
  ↓ 终端显示工具参数，等待用户输入
用户: "yes"
  ↓ POST /approval/resume {thread_id, resume_value: "yes"}
服务器: {messages: [...], approved: true}
  ↓ 终端显示执行结果
```

## Graph 架构

```
agent (LLM) → (有 tool_calls?) → approve (interrupt 审批) → (已批准?) → tools
                 │                                      │
                 └ 无 → end                              └ 拒绝 → end
```

- `agent` 节点只调 LLM，不打断
- `approve` 节点显示参数并 `interrupt()` 等待用户输入
- 条件边根据 `state.approved` 判断流向

## 与标准 LangServe 的关系

自定义的 `/start` 和 `/resume` 端点是对 LangServe 标准 `/invoke` 的补充。LangServe 的标准端点仍然可用：

```python
# 使用 RemoteRunnable 调用标准端点
from langserve import RemoteRunnable
runnable = RemoteRunnable("http://localhost:8000/approval")
result = runnable.invoke(
    {"messages": [HumanMessage("转账1000")], "approved": False},
    config={"configurable": {"thread_id": "xxx"}},
)
```

但 `Command` 对象的序列化在不同 LangServe 版本中表现不同，自定义端点更可靠。
