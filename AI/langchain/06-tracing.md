# Tracing（调用链路追踪）

## 三种方案

| 方案 | 需要安装 | 需要 API key | 适合场景 |
|---|---|---|---|
| `ConsoleCallbackHandler` | 内置 | 否 | 开发时临时看链路 |
| 自定义 `BaseCallbackHandler` | 内置 | 否 | 结构化记录、存日志、统计耗时 |
| LangSmith | `langsmith` | 是 | 生产环境可视化 trace |

## ConsoleCallbackHandler

```python
from langchain_core.tracers import ConsoleCallbackHandler

chain.invoke({"topic": "programmers"}, config={"callbacks": [ConsoleCallbackHandler()]})
```

输出完整的调用树：Chain → Prompt → LLM → Parser，每步的输入输出。

## 自定义 TraceHandler

可自定义 `BaseCallbackHandler` 子类记录以下数据：

| 字段 | 说明 |
|---|---|
| 耗时 (Latency) | 每步执行时间，毫秒级 |
| Token 用量 | ↑输入 / ↓输出 token 数 |
| Reasoning tokens | 推理模型的思考 token |
| Cost | 按模型价格估算 USD |

支持 LangChain chain 和 LangGraph graph 两种场景。

## LangSmith

设置环境变量后自动启用，无需改代码：

```bash
export LANGCHAIN_TRACING_V2=true
export LANGCHAIN_API_KEY=ls_xxx
export LANGCHAIN_PROJECT=study-langchain
```

然后访问 https://smith.langchain.com 查看可视化 trace（调用树 + 耗时火焰图 + token 用量 + 成本估算）。
