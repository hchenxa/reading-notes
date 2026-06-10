# Agent 三种记忆：Episodic / Semantic / Procedural

## 概述

Agent 的记忆系统借鉴了认知科学的分类，分为三个层次：

```
                    ┌───────────────────────┐
                    │   Procedural Memory    │  "怎么做" — 技能/规则/流程
                    │  System Prompt + Tool  │
                    │  + Graph 结构          │
                    ├───────────────────────┤
                    │   Semantic Memory      │  "是什么" — 事实/知识/偏好
                    │  InMemoryStore         │
                    │  + langmem             │
                    ├───────────────────────┤
                    │   Episodic Memory      │  "发生了什么" — 对话历史
                    │  MemorySaver           │
                    │  (checkpointer)        │
                    └───────────────────────┘
```

越往下越具体、越自动；越往上越抽象、需要手动管理。

---

## 一、Episodic Memory（情景记忆）

**定义**：Agent 经历过什么——具体的对话过程、每轮的消息。

**实现**：`MemorySaver`（`langgraph.checkpoint.memory`）

**特点**：
- 自动保存（注入 `checkpointer` 即可，无需手动调用）
- 按 `thread_id` 隔离（不同对话互不可见）
- 存的是**原始消息**，不做提炼

```python
from langgraph.checkpoint.memory import MemorySaver

agent = workflow.compile(checkpointer=MemorySaver())

# 同一个 thread_id → Agent 自动恢复上下文
config = {"configurable": {"thread_id": "alice-session"}}

agent.invoke({"messages": [("human", "Hi, my name is Alice")]}, config)
# → MemorySaver 自动存档

agent.invoke({"messages": [("human", "What's my name?")]}, config)
# → 自动带上历史消息，Agent 知道名字
```

| 维度 | 说明 |
|------|------|
| 自动/手动 | 自动 |
| 隔离粒度 | `thread_id` |
| 存储内容 | `list[Message]`（原始对话） |
| 生命周期 | 对话结束即完结 |

**类比**：人的"我记得刚才我们说了什么"。

---

## 二、Semantic Memory（语义记忆）

**定义**：Agent 知道的**事实和知识**——用户偏好、关键信息、跨 session 的积累。

**实现**：`InMemoryStore`（`langgraph.store.memory`）+ `langmem` 工具

**特点**：
- 手动管理（显式 `put/get/search`）
- 跨 `thread_id`、跨 session（agent 所有对话共享）
- 存的是**提炼后的知识点**

```python
from langgraph.store.memory import InMemoryStore

store = InMemoryStore()

# 手动写入语义记忆
store.put(("users", "alice"), "preferences", {
    "language": "Python",
    "interest": "data science",
})

# 跨 thread 读取
store.get(("users", "alice"), "preferences")
store.search(("users", "alice"))
```

### LangMem 工具：LLM 自主管理语义记忆

```python
from langmem import create_manage_memory_tool, create_search_memory_tool
from langchain.agents import create_agent

agent = create_agent(
    model,
    tools=[
        create_manage_memory_tool(namespace=("memories", "{langgraph_user_id}")),
        create_search_memory_tool(namespace=("memories", "{langgraph_user_id}")),
    ],
    store=store,
)
```

**效果**：LLM 收到"记住我喜欢 Python"时，自动调 `manage_memory` → 写入 store。下次任何 session 里询问，LLM 调 `search_memory` → 从 store 查到。

| 维度 | 说明 |
|------|------|
| 自动/手动 | 手动（或 langmem 工具让 LLM 代劳） |
| 隔离粒度 | `namespace`（可跨 thread） |
| 存储内容 | `dict`（提炼后的知识） |
| 生命周期 | 跨会话，可长期保存 |

**类比**：人的"我知道 Alice 喜欢 Python"。

---

## 三、Procedural Memory（程序记忆）

**定义**：Agent **该怎么做**——行为规则、工具能力、决策流程。

**实现**：`System Prompt` + `Tool 定义` + `StateGraph 结构`

**特点**：
- 开发者定义，Agent 和 LLM 无法（不应该）自行修改
- 全局一致，所有线程/会话都遵守
- 不随对话改变

```python
# 1. System Prompt — 行为准则
system_prompt = SystemMessage("""
- Always respond in Chinese
- Be concise — answer within 3 sentences
- Use search_docs before guessing
""")

# 2. Tool 定义 — 能力边界
@tool
def search_docs(query: str) -> str:
    """搜索内部文档库。"""
    ...

# 3. Graph 结构 — 决策流程
builder = StateGraph(AgentState)
builder.add_node("analyze", analyze_node)
builder.add_node("act", act_node)
builder.add_edge("analyze", "act")
```

三种方式对应三种不同的"程序记忆"来源：

| 来源 | 作用 | 类比 |
|------|------|------|
| `System Prompt` | 行为风格、回答准则 | 人的"社会规则" |
| `bind_tools` / tools | Agent 能用什么工具 | 人的"技能" |
| `StateGraph` | 先做什么后做什么 | 人的"流程/习惯" |

**类比**：人的"骑自行车不需要想先踩哪只脚"。

---

## 四、三者协同工作

实际 Agent 运行时，三种记忆同时生效：

```
Procedural（System Prompt: 用中文、查文档、用计算器）
   ↓ 定义了行为框架
Episodic（MemorySaver: 保存了上一轮的对话）
   ↓ 提供了当前上下文
Semantic（InMemoryStore: 记得 Alice 喜欢 Python）
   ↓ 提供了跨 session 知识
   → Agent: "基于你的数据分析背景，建议你做一个用 LangChain 构建 RAG 系统的项目"
```

```python
agent = create_agent(
    model,
    tools=[search_docs, calculate, manage_tool, search_tool],
    system_prompt=procedural_prompt,   # Procedural
    checkpointer=MemorySaver(),        # Episodic
    store=memory_store,                # Semantic
)
```

---

## 五、Prompt 自动优化 — 程序记忆的迭代调优

`create_multi_prompt_optimizer`（和 `create_prompt_optimizer`）来自 langmem，用于**自动改进 system prompt**——也就是在开发阶段迭代优化 Procedural Memory。

### 工作方式

```
你提供:
  - 过去的对话记录（trajectories）
  - 现有的 prompt（一个或多个）
  + LLM 分析效果 → 输出优化后的 prompt
```

### 三种优化策略

| `kind` | 策略 | 适用场景 |
|--------|------|----------|
| `gradient`（默认） | 通过分析对话反思迭代改进 | 通用场景 |
| `prompt_memory` | 参考过去成功的 prompt 模式 | 有较多历史数据 |
| `metaprompt` | 元学习，找最优模式 | 需要大幅重构 prompt |

### 用法

```python
from langmem import create_multi_prompt_optimizer

optimizer = create_multi_prompt_optimizer(
    "claude-3-5-sonnet-latest",
    kind="gradient",
)

# 你的现有 prompt
prompts = [
    {"name": "tech", "prompt": "You are a technical assistant. Be detailed."},
    {"name": "creative", "prompt": "You are a creative assistant. Be imaginative."},
]

# 真实对话 + 反馈
trajectories = [
    (conversation_1, {"clarity": "too verbose"}),
    (conversation_2, {"clarity": "good"}),
]

better = optimizer.invoke({"trajectories": trajectories, "prompts": prompts})
```

### 定位：开发时 vs 运行时

| | `create_manage_memory_tool` | `create_multi_prompt_optimizer` |
|---|---|---|
| 时机 | **运行时** — Agent 在对话中读写记忆 | **开发时** — 你在调试优化 prompt |
| 记忆类型 | Semantic Memory | Procedural Memory |
| 谁控制 | LLM 自主决定 | 开发者主动调用 |
| 产出 | store 里的数据 | 更好的 system prompt |

---

## 快速参考

| 记忆类型 | 认知科学类比 | LangChain/LangGraph 机制 | 关键语法 |
|----------|-------------|--------------------------|----------|
| **Episodic** | "记得聊过什么" | `MemorySaver` (checkpointer) | `compile(checkpointer=MemorySaver())` |
| **Semantic** | "知道什么事实" | `InMemoryStore` + langmem | `compile(store=store)` + `manage_memory` tool |
| **Procedural** | "知道该怎么做" | System Prompt + Tools + Graph | `system_prompt=...` + `tools=[...]` |

### langmem 工具一览

| 工具 | 作用 | 记忆类型 | 使用时机 |
|------|------|----------|----------|
| `create_manage_memory_tool` | LLM 自主 create/update/delete 记忆 | Semantic | 运行时 |
| `create_search_memory_tool` | LLM 自主搜索记忆 | Semantic | 运行时 |
| `create_memory_store_manager` | 自动从对话提取三类记忆 | Semantic + Episodic + Procedural | 运行时 |
| `create_thread_extractor` | 把对话提炼为摘要/结构化数据 | Episodic | 运行时 |
| `create_prompt_optimizer` | 优化单个 system prompt | Procedural | 开发时 |
| `create_multi_prompt_optimizer` | 同时优化多个 system prompt | Procedural | 开发时 |

## 参考

- [LangGraph: Persistence (MemorySaver)](https://langchain-ai.github.io/langgraph/concepts/persistence/)
- [LangGraph: Memory Store](https://langchain-ai.github.io/langgraph/concepts/memory/)
- [LangMem Official Docs](https://langchain-ai.github.io/langmem/)
