# LangChain / LangGraph KV 存储机制

## 概述

LangChain 生态中有三类不同的"存储"概念，各自解决不同的问题：

```
┌─ langchain_core.stores.InMemoryStore ─ 通用 KV 存储（任意数据）
├─ langgraph.store.memory.InMemoryStore ─ Agent 长期记忆（带命名空间）
├─ langgraph.checkpoint.memory.MemorySaver ─ graph 状态检查点（自动）
└─ langchain_core.chat_history.BaseChatMessageHistory ─ 对话历史
```

---

## 一、langchain_core.stores.InMemoryStore — 通用 KV 存储

### 接口

所有 store 实现 `BaseStore` 接口：

```python
from langchain_core.stores import BaseStore, InMemoryStore

store = InMemoryStore()

store.mset([("key1", value1), ("key2", value2)])  # 写入
store.mget(["key1", "key2"])                       # 读取 → [value1, value2]
store.mdelete(["key2"])                            # 删除
store.yield_keys(prefix="user:")                   # 遍历 key
```

| 方法 | 说明 | 异步版本 |
|------|------|----------|
| `mset(pairs)` | 批量写入 | `amset` |
| `mget(keys)` | 批量读取（缺失返回 None） | `amget` |
| `mdelete(keys)` | 批量删除 | `amdelete` |
| `yield_keys(prefix)` | 遍历 key（支持前缀过滤） | `ayield_keys` |

### 特点

- Key 是 **str**，Value 是 **任意 Python 对象**
- 无命名空间、无索引、不会自动过期
- 实现简单，**适合缓存、中间数据、测试**

### 常见实现

除了 `InMemoryStore`，还有：
- `langchain.storage.FileStore` — 文件系统存储
- `langchain.storage.RedisStore` — Redis 后端
- 自定义：继承 `BaseStore` 实现四个方法即可

---

## 二、langgraph.store.memory.InMemoryStore — 长期记忆

### 接口

专为 Agent 长期记忆设计，多了命名空间和搜索能力：

```python
from langgraph.store.memory import InMemoryStore

store = InMemoryStore()

store.put(("users", "alice"), "preferences", {"theme": "dark"})
item = store.get(("users", "alice"), "preferences")
# → Item(namespace=('users','alice'), key='preferences', value={'theme': 'dark'})

store.search(("conversations",))                # 搜索命名空间下的所有记录
store.list_namespaces()                         # 列出所有命名空间
store.delete(("users", "alice"), "preferences")  # 删除
```

| 方法 | 说明 | 参数摘要 |
|------|------|----------|
| `put` | 写入 | `(namespace, key, value)` — value 是 dict |
| `get` | 读取 | `(namespace, key)` → `Item \| None` |
| `search` | 按命名空间搜索 | `(prefix, query?, filter?, limit?)` |
| `delete` | 删除 | `(namespace, key)` |
| `list_namespaces` | 列出命名空间 | `(prefix?, suffix?, max_depth?)` |

### 对比 langchain_core 版本

| | langchain_core InMemoryStore | langgraph InMemoryStore |
|---|---|---|
| Key | `str` | `(tuple[str,...], str)` — 分层 |
| Value | 任意 | `dict` |
| 搜索 | 仅按 key 前缀遍历 | 按 namespace + 可选语义搜索 |
| 索引 | ❌ | ✅ 可配向量索引 |
| 用途 | 通用 KV | Agent 长期记忆、用户偏好 |

### 向量索引（可选）

InMemoryStore 支持嵌入向量索引，实现语义搜索：

```python
from langchain_openai import OpenAIEmbeddings

embeddings = OpenAIEmbeddings(model="text-embedding-3-small")
store = InMemoryStore(index={
    "embed": embeddings,
    "dims": 512,
    "fields": ["title", "content"],  # 哪些字段参与向量化
})

store.put(("docs",), "doc1", {"title": "...", "content": "..."})
results = store.search(("docs",), query="key-value storage")
# → 按语义相似度排序，每项带 score
```

> **注意**：向量索引在 `langgraph >= 0.4.0` 中可用。

---

## 三、MemorySaver — graph 状态检查点

与 InMemoryStore 同属 langgraph，但职责完全不同：

```python
from langgraph.checkpoint.memory import MemorySaver

checkpointer = MemorySaver()
graph = builder.compile(checkpointer=checkpointer)
```

| | MemorySaver | InMemoryStore (langgraph) |
|---|---|---|
| 角色 | graph 状态自动 checkpoint | 手动读写长期记忆 |
| 触发方式 | 自动（注入 `checkpointer`） | 显式调用 `put/get/search` |
| 作用域 | `thread_id`（单次对话内） | `namespace`（可跨对话） |
| 存储内容 | graph state + 消息历史 | 任意 KV 数据 |
| 用途 | 对话历史、中断恢复 | 用户偏好、知识记忆 |

---

## 四、BaseChatMessageHistory — 对话历史

这是 LangChain **最初**的对话记忆方式，通过 `RunnableWithMessageHistory` 使用：

```python
from langchain_core.runnables.history import RunnableWithMessageHistory
from langchain_community.chat_message_histories import ChatMessageHistory

history = ChatMessageHistory()  # 实现 BaseChatMessageHistory
chain = RunnableWithMessageHistory(
    chain,
    get_session_history=lambda sid: history,
)
```

与 MemorySaver 的关系：**做同一件事（记住对话），但方式不同**。

| | RunnableWithMessageHistory | MemorySaver |
|---|---|---|
| 框架 | LangChain（手动） | LangGraph（自动） |
| 存储 | `BaseChatMessageHistory` 接口 | `BaseCheckpointSaver` 接口 |
| 机制 | 手动注入历史 → 追加新消息 | 自动保存全部 graph state |
| 对话恢复 | 依赖外部 session 管理 | 按 `thread_id` 自动恢复 |

---

## 五、langmem — InMemoryStore 的 CRUD 工具

`create_manage_memory_tool` 和 `create_search_memory_tool` 来自独立的 **[langmem](https://langchain-ai.github.io/langmem/)** 库。它们把 InMemoryStore 的 CRUD 封装成工具，**LLM 在对话中自主决定读写哪些记忆**。

```python
from langmem import create_manage_memory_tool, create_search_memory_tool
from langgraph.store.memory import InMemoryStore
from langchain.agents import create_agent

store = InMemoryStore()

tools = [
    create_manage_memory_tool(
        namespace=("memories", "{langgraph_user_id}"),
        store=store,
    ),
    create_search_memory_tool(
        namespace=("memories", "{langgraph_user_id}"),
        store=store,
    ),
]

agent = create_react_agent("model", tools=tools, store=store)
```

### create_manage_memory_tool

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `namespace` | 记忆的命名空间（支持 `{user_id}` 等占位符） | 必填 |
| `actions_permitted` | 允许的操作 | `("create", "update", "delete")` |
| `schema` | 记忆的结构化 schema（Pydantic model） | `str` |
| `store` | BaseStore 实例（可留空，compile 时注入） | `None` |

三种操作：**create** — 创建新记忆、**update** — 更新已有记忆、**delete** — 删除记忆

### create_search_memory_tool

| 参数 | 说明 |
|------|------|
| `namespace` | 搜索的命名空间 |
| `query` | 自然语言查询（语义搜索） |
| `limit` / `offset` | 分页控制 |
| `filter` | 过滤条件 |

### 动态 Namespace

namespace 支持运行时占位符，**不同用户的记忆自动隔离**：

```python
manage_memory = create_manage_memory_tool(
    namespace=("memories", "{langgraph_user_id}"),
)

# 运行时从 config 中自动填充
agent.invoke(
    {"messages": [{"role": "user", "content": "I like pandas"}]},
    config={"configurable": {"user_id": "user-123"}},
)
# → 实际存储: ("memories", "user-123") / some_key
```

---

## 快速参考

| 存储类 | 模块 | Key 类型 | Value 类型 | 主要用途 |
|--------|------|----------|------------|----------|
| `InMemoryStore` | `langchain_core.stores` | `str` | 任意 | 通用 KV 缓存 |
| `InMemoryStore` | `langgraph.store.memory` | `(tuple, str)` | `dict` | Agent 长期记忆 |
| `MemorySaver` | `langgraph.checkpoint.memory` | `RunnableConfig` | `Checkpoint` | Graph 状态检查点 |
| `ChatMessageHistory` | `langchain_community.chat_message_histories` | `session_id` | `list[Message]` | 对话历史 |
| `create_manage_memory_tool` | `langmem` | —（工具封装） | — | LLM 自主 CRUD |
| `create_search_memory_tool` | `langmem` | —（工具封装） | — | LLM 自主搜索 |

## 参考

- [LangChain: BaseStore API](https://api.python.langchain.com/en/latest/core_api_reference.html#module-langchain_core.stores)
- [LangGraph: Memory Store](https://langchain-ai.github.io/langgraph/concepts/memory/)
- [LangGraph: Checkpointer](https://langchain-ai.github.io/langgraph/concepts/persistence/)
- [LangMem Official Docs](https://langchain-ai.github.io/langmem/)
