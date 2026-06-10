# Memory 机制

## 旧组件状态

| 组件 | 状态 |
|---|---|
| `ConversationBufferMemory` | 已废弃 (0.3.1)，2.0 移除 |
| `ConversationBufferWindowMemory` | 已移除 |
| `ConversationSummaryBufferMemory` | 已废弃 |
| `ConversationChain` | 已废弃 (0.2.7)，2.0 移除 |

## 当前方案

### LangChain 方式 — `RunnableWithMessageHistory`

```python
from langchain_core.runnables.history import RunnableWithMessageHistory
from langchain_community.chat_message_histories import ChatMessageHistory

store = {}
def get_session_history(session_id: str):
    if session_id not in store:
        store[session_id] = ChatMessageHistory()
    return store[session_id]

chain_with_history = RunnableWithMessageHistory(
    prompt | llm,
    get_session_history,
    input_messages_key="input",
    history_messages_key="history",
)
```

- 每次调用自动注入历史消息
- 用 `session_id` 区分不同会话
- 适合简单对话场景

### LangGraph 方式 — `StateGraph` + checkpointer

```python
from langgraph.checkpoint.memory import MemorySaver
from langgraph.graph import START, StateGraph, MessagesState

workflow = StateGraph(state_schema=MessagesState)

def call_model(state: MessagesState):
    response = llm.invoke(state["messages"])
    return {"messages": response}

workflow.add_node("model", call_model)
workflow.add_edge(START, "model")
app = workflow.compile(checkpointer=MemorySaver())

app.invoke(
    {"messages": [HumanMessage(content="Hi")]},
    {"configurable": {"thread_id": "1"}},
)
```

- 消息历史是 state 的一部分，天然跨轮持久化
- `thread_id` 区分不同会话
- 支持更复杂的对话流（分支、循环、多节点）

## Context 窗口控制

默认无限累积，需要手动截断：

```python
from langchain_core.messages import trim_messages

trimmed = trim_messages(
    state["messages"],
    max_tokens=4096,
    strategy="last",
    token_counter=llm.get_num_tokens_from_messages,
)
```

核心原则：**截断即失忆**，重要信息（如用户名）应放到 system prompt 里。
