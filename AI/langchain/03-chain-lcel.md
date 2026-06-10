# Chain（LCEL）

## 背景

所有旧的 `*Chain` 类在 LangChain 0.3+ 已废弃，2.0 彻底移除，全部由 **LCEL**（LangChain Expression Language）替代。

| 旧组件 | 替代方案 |
|---|---|
| `LLMChain` | `prompt \| llm \| StrOutputParser()` |
| `SimpleSequentialChain` | `chain1 \| chain2` |
| `SequentialChain` | `RunnablePassthrough.assign(...)` 或并行 dict |
| `RouterChain` / `MultiPromptChain` | `RunnableBranch` 或 `add_conditional_edges` |
| `ConversationChain` | `RunnableWithMessageHistory` 或 `StateGraph` |

## LCEL 示例

```python
# 1. LLMChain 替代
chain = prompt | llm | StrOutputParser()
chain.invoke({"topic": "programmers"})

# 2. SimpleSequentialChain 替代
pipeline = chain1 | chain2
pipeline.invoke({"weather": "rainy"})

# 3. SequentialChain 替代（多路并行）
multi_chain = {
    "summary": summary_chain,
    "sentiment": sentiment_chain,
} | RunnablePassthrough()

# 4. RouterChain 替代
from langchain_core.runnables import RunnableBranch

branch_chain = RunnableBranch(
    (lambda x: "math" in x["input"].lower(), math_chain),
    (lambda x: "code" in x["input"].lower(), code_chain),
    general_chain,  # fallback
)
```

核心变化：`chain.run(...)` / `chain(input)` → `chain.invoke(...)`，用 `|` 运算符组合组件，不再是对象组合模式。
