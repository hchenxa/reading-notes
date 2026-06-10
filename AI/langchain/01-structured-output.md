# 结构化输出

## 两种方案对比

### 旧方式 — `PydanticOutputParser`

```python
from langchain_core.output_parsers import PydanticOutputParser
from pydantic import BaseModel, Field

class Person(BaseModel):
    name: str = Field(description="person's name")
    age: int = Field(description="person's age")

parser = PydanticOutputParser(pydantic_object=Person)
chain = prompt | llm | parser
```

原理：在 prompt 里塞 `format_instructions`，LLM 吐纯文本 JSON 后解析。
缺点：小模型格式不稳定，容易解析失败。

### 新方式 — `with_structured_output`

```python
from pydantic import BaseModel

class Person(BaseModel):
    name: str
    age: int

structured_llm = llm.with_structured_output(Person)
result = structured_llm.invoke("Xiao Ming is 25 years old")
```

原理：走模型 native tool calling / JSON mode，不依赖 prompt 模板。
优点：零解析失败，速度更快。

### 对比表

| | `PydanticOutputParser` | `with_structured_output` |
|---|---|---|
| 依赖 | 文本生成 + 正则/JSON 解析 | 模型原生 tool calling / JSON mode |
| 稳定性 | 小模型格式经常出错 | 基本 100% 成功 |
| Format instructions | 需手动写 | 不需要 |
| 适用模型 | 所有 LLM | 需支持 tool calling |

### LangGraph 注意点

LangGraph 不直接支持 `|` 管道给节点，需要在节点函数内部处理。用 `with_structured_output` 更简洁。

```python
def extract_node(state: State):
    result = llm.with_structured_output(Person).invoke(state["input"])
    return {"person": result}
```

**建议**：模型支持 function calling 就用 `with_structured_output`。DeepSeek 兼容 OpenAI 的 tool calling，可以直接用。

---

## Tagging（文本分类标注）

Tagging 本质就是结构化输出的一个典型应用 —— 用 Pydantic 定义分类维度，通过 `with_structured_output` 让 LLM 自动标注。

### 核心技巧：用 `Field(enum=[...])` 约束维度

```python
from pydantic import BaseModel, Field

class Tags(BaseModel):
    sentiment: str = Field(
        description="情感倾向",
        enum=["positive", "negative", "neutral"],
    )
    language: str = Field(
        description="文本语言",
        enum=["en", "zh", "ja", "other"],
    )
    topic: str = Field(
        description="话题类别",
        enum=["technology", "entertainment", "sports", "politics", "other"],
    )
    aggressiveness: int = Field(
        description="攻击性 1-5",
        ge=1, le=5,
    )

tagger = llm.with_structured_output(Tags)
result = tagger.invoke("This new AI model is absolutely revolutionary!")
# → Tags(sentiment="positive", language="en", topic="technology", aggressiveness=1)
```

### 为什么不需要 `create_tagging_chain`

LangChain 旧版有专门的 `create_tagging_chain()` / `create_tagging_chain_pydantic()`，**v1.0 已移除**。替换方案就是 `with_structured_output`：

| 旧（移除） | 新 |
|---|---|
| `create_tagging_chain(schema, llm)` | `llm.with_structured_output(Schema)` |
| `create_tagging_chain_pydantic(schema, llm)` | `llm.with_structured_output(Schema)` |

两者的输入输出完全一样，只是新方式不需要单独学一个 API。

### 配合 batch 批量标注

```python
texts = [
    "I love this product!",
    "This is terrible.",
    "The weather is fine.",
]
results = tagger.batch(texts)
for text, tag in zip(texts, results):
    print(f"[{tag.sentiment}] {text}")
```

### LangGraph 中的 Tagging

Tagging 也可以作为 Graph 的一个节点，配合后处理节点做审核、过滤：

```python
class TaggingState(TypedDict):
    text: str
    tags: Tags | None

def tag_node(state: TaggingState):
    return {"tags": tagger.invoke(state["text"])}

def review_node(state: TaggingState):
    # 对政治类中性文本标记二次确认
    if state["tags"].sentiment == "neutral" and state["tags"].topic == "politics":
        log_for_review(state["text"])
    return {}

graph = StateGraph(TaggingState)
graph.add_node("tag", tag_node)
graph.add_node("review", review_node)
graph.add_edge(START, "tag")
graph.add_edge("tag", "review")
```
