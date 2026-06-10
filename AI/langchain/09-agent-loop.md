# Agent Loop — 思考-行动-观察循环

## 概述

Agent Loop 是 Agent 最核心的运行机制：**反复循环**直到得出最终答案。

```
用户提问
    ↓
┌─ THINK:  LLM 思考需要做什么（调用工具？直接回答？）
│   ↓
│  ACT:    执行工具调用，拿到结果
│   ↓
│  OBSERVE: 把工具结果放回上下文
│   ↓
└──→ 回到 THINK（LLM 根据最新信息再次决策）
    ↓
  ANSWER: LLM 认为够了，输出最终答案
```

## 手动实现 vs 框架封装

| | 框架封装（create_agent） | 手动实现 |
|---|---|---|
| 代码量 | 少，几行搞定 | 多，需要自己写 while 循环 |
| 透明性 | 循环细节被隐藏 | 每一步都可见 |
| 控制力 | 固定模式 | 完全控制何时停止、重试等 |
| 学习价值 | 适合生产 | 适合理解原理 |

**建议**：先理解手动实现明白原理，生产中用框架封装或 StateGraph。

## 关键实现

### 消息列表（messages）是循环的"记忆"

每次循环都在做同一件事：
1. 把当前 `messages` 发给 LLM
2. LLM 回复一个 `AIMessage`（可能带 `tool_calls`，也可能直接回答）
3. 如果是 `tool_calls` → 执行工具 → 把 `ToolMessage` 追加到 `messages` → 回到步骤 1
4. 如果直接回答 → 结束循环

```python
messages = [SystemMessage(...), HumanMessage(query)]

while True:
    response = llm.invoke(messages)           # THINK
    messages.append(response)

    if not response.tool_calls:               # 直接回答 → 结束
        break

    for tc in response.tool_calls:            # ACT
        result = tool_fn.invoke(tc["args"])
        messages.append(ToolMessage(...))     # OBSERVE
```

### 防止死循环

设置最大迭代次数，防止 LLM 无限调工具：

```python
MAX_ITERATIONS = 6

while step < MAX_ITERATIONS:
    ...
# 超限后强制返回最后一次 LLM 的回答
```

## 三种场景

| 场景 | 示例 | 循环次数 | 说明 |
|------|------|----------|------|
| 单工具 | 查天气 | 2 轮 | think → tool → think → answer |
| 多工具 | 天气 + GitHub stars | 2-3 轮 | 一次问多个独立问题 |
| 无工具 | 打招呼 | 1 轮 | 直接回答，不进工具循环 |

## 参考

- [LangChain Docs: Agents](https://python.langchain.com/docs/concepts/agents/)
- [LangChain Docs: Tools](https://python.langchain.com/docs/concepts/tools/)
