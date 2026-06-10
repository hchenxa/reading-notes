# Runnable Interface: invoke / stream / batch / with_fallbacks

## 概述

Runnable 是 LangChain 所有组件（LLM、Prompt Template、Output Parser、Retriever、Chain 等）实现的**统一接口**。无论多复杂的链，都支持以下调用方式。

```python
# 任意链都自动支持这些调用
chain = prompt | llm | StrOutputParser()
chain.invoke(...)               # 同步单次
chain.stream(...)               # 同步流式
chain.batch(...)                # 同步批量
chain.with_fallbacks(...)       # 降级 / 容灾
chain.ainvoke(...)              # 异步版本（astream, abatch, afallbacks 同理）
```

---

## 调用方式详解

### 1. invoke — 单次同步调用

```python
result = chain.invoke({"topic": "AI"})
# → 阻塞等待，返回完整字符串
```

| 特性 | 说明 |
|------|------|
| 输入 | 单个 dict / string / Message |
| 输出 | 单个完整结果（str / dict / Message） |
| 阻塞 | 是 — 等待 LLM 全部生成 |
| 适用 | API 端点、单次问答、简单的推理流程 |

**何时使用**：最简单的调用方式，不需要流式效果或批量处理时首选。

---

### 2. stream — 流式逐块输出

```python
for chunk in chain.stream({"topic": "AI"}):
    print(chunk, end="")
# → 逐 token 输出，无需等待全部生成
```

| 特性 | 说明 |
|------|------|
| 输入 | 单个 dict / string / Message |
| 输出 | 迭代器，每次 yield 一个 chunk（token / 文本片段） |
| 阻塞 | 否 — 首 token 到后即可处理 |
| 适用 | 聊天 UI、打字机效果、需要低延迟展示中间结果 |

**关键概念**：
- **`stream` vs `invoke` 内部一致**：`invoke` 本质上是 `stream` 的「收集全部后返回」。所以任何支持 `invoke` 的 Runnable 都自动支持 `stream`。
- **Chunk 粒度**：取决于组件。LLM 的 stream 通常是逐 token，Parser 的 stream 是解析后的文本片段，Retriever 的 stream 是一次性返回全部文档。

---

### 3. batch — 批量并行调用

```python
results = chain.batch([
    {"topic": "AI"},
    {"topic": "ML"},
    {"topic": "DL"},
])
# → 返回 ["结果1", "结果2", "结果3"]
```

| 特性 | 说明 |
|------|------|
| 输入 | list[单个输入] |
| 输出 | list[完整结果] |
| 并发 | 默认线程池自动并行 |
| 适用 | 批量处理、离线任务、测试、FAQ 批量回答 |

**性能对比**：
```
串行 4 次 invoke: 4.2s
batch 并行 4 次:   1.1s
加速比:            3.8x
```

**控制并发**：
```python
chain.batch(inputs, config={"max_concurrency": 2})  # 最多 2 个并发
```

**何时使用**：需要处理多个独立输入时。注意：batch 适合**无状态**的链（不共享上下文），有状态的对话需要自行管理 session。

---

### 4. with_fallbacks — 自动容灾降级

```python
primary_llm = ChatOpenAI(model="gpt-4", api_key="...")
fallback_llm = ChatOpenAI(model="gpt-3.5-turbo", api_key="...")

llm = primary_llm.with_fallbacks(
    fallbacks=[fallback_llm],
    exceptions_to_handle=(Exception,),     # 默认全部异常都触发
)

chain = prompt | llm | StrOutputParser()
chain.invoke(...)  # GPT-4 失败 → 自动重试 GPT-3.5
```

| 特性 | 说明 |
|------|------|
| 输入 | 同原 Runnable |
| 输出 | 同原 Runnable（失败时从备用取） |
| 触发条件 | 默认全部 Exception，可精确指定 |
| 适用 | 高可用、多模型容灾、成本控制 |

**关键点**：

- **LLM 级别 vs 链级别**：fallback 可以挂在单个 LLM 上，也可以挂在整条链（`prompt | llm | parser`）上
- **精确控制异常**：通过 `exceptions_to_handle` 指定哪些异常才触发 fallback
- **链级 fallback**：整条链失败时切换到完全不同的逻辑
- **stream + fallback**：fallback 在流开始前触发，流开始后的中间错误不会触发 fallback

---

### 5. 异步版本 — ainvoke / astream / abatch

```python
import asyncio

# ainvoke
result = await chain.ainvoke({"topic": "AI"})

# astream
async for chunk in chain.astream({"topic": "AI"}):
    print(chunk, end="")

# abatch — 返回列表
results = await chain.abatch([{"topic": "AI"}, {"topic": "ML"}])

# abatch_as_completed — 按完成顺序逐个处理
async for idx, result in chain.abatch_as_completed(inputs):
    print(f"[{idx}] {result}")

# awith_fallbacks — 异步 fallback（用法与同步一致）
primary_llm.afallbacks(fallbacks=[...])
```

| 方法 | 同步 | 异步 |
|------|------|------|
| 单次 | `invoke` | `ainvoke` |
| 流式 | `stream` | `astream` |
| 批量 | `batch` | `abatch` / `abatch_as_completed` |
| 降级 | `with_fallbacks` | `afallbacks` |

---

## 快速参考

| 方法 | 输入 | 输出 | 阻塞 | 典型延迟 | 适用场景 |
|------|------|------|------|----------|---------|
| `invoke` | 单个 | 单个完整结果 | 是 | LLM 生成时间 | API 响应、单次问答 |
| `stream` | 单个 | 逐块迭代器 | 否（逐块） | 首 token 极短 | 聊天 UI、打字机效果 |
| `batch` | 列表 | 完整结果列表 | 是（批量） | 接近单次时间 | 批量测试、离线处理 |
| `with_fallbacks` | 同上 | 同上（自动降级）| 同上 | 同上（失败时+1次重试）| 高可用、多模型容灾 |
| `ainvoke` | 单个 | 单个完整结果 | 异步非阻塞 | LLM 生成时间 | FastAPI、asyncio 环境 |
| `astream` | 单个 | 异步逐块迭代器 | 异步非阻塞 | 首 token 极短 | 异步聊天 |
| `abatch` | 列表 | 完整结果列表 | 异步非阻塞 | 接近单次时间 | 异步批量处理 |

## 核心原理

所有 Runnable 都遵循同一个接口：

```
invoke(input) → output
        ↑ 内部等价于
stream(input) → Iterator[chunk]   # 收集全部 = invoke
```

- `invoke` 在内部通过 `stream` 实现：调用 `stream`，收集所有 chunk，合并后返回
- 因此任何自定义 Runnable 只需要实现 `stream` 或 `invoke` 其中之一，另一个就自动可用
- `batch` 通过 `invoke` 加线程池实现，`abatch` 同理
- `with_fallbacks` 包装原 Runnable，捕获异常后依次尝试备用链，**对调用方透明**

## 参考

- [LangChain Docs: Runnable Interface](https://python.langchain.com/docs/concepts/runnable_interface/)
- [LangChain API: Runnable](https://api.python.langchain.com/en/latest/core_api_reference.html#module-langchain_core.runnables)
