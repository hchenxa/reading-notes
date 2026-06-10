# Agent

## 背景

LangGraph V1.0 后，`create_react_agent` 已从 `langgraph.prebuilt` 移到 `langchain.agents`，改名为 `create_agent`。

## 当前可用的 Agent 类型

在 LangChain 1.3 / LangGraph 1.x 中，Agent 的入口统一为 `create_agent`，通过不同参数配置不同行为：

| 类型 | 配置方式 | 说明 |
|---|---|---|
| **Tool-calling Agent**（默认） | `create_agent(model, tools=[...])` | ReAct 风格，LLM 自主决定调哪个工具 |
| **Structured Output Agent** | `create_agent(model, response_format=MySchema)` | Agent 输出固定结构 |
| **Sub-agent** | `create_agent()` 嵌套 | Agent 内部再调 agent 作为工具 |
| **自定义 StateGraph Agent** | 手动 `StateGraph` + `ToolNode` | 完全自定义 agent 逻辑 |

### Tool-calling Agent（默认）

```python
from langchain.agents import create_agent

agent = create_agent(
    model=llm,
    tools=[my_tool1, my_tool2],
    system_prompt="You are a helpful assistant.",
)
result = agent.invoke({"messages": [("human", "Check my GitHub activity")]})
print(result["messages"][-1].content)
```

流程：User Input → LLM（决定调用哪个工具） → Tool（执行并返回结果） → LLM（生成最终回答）

### Structured Output Agent

```python
from langchain.agents import create_agent
from pydantic import BaseModel, Field

class CodeReview(BaseModel):
    score: int = Field(description="Overall score (1-10)")
    summary: str = Field(description="One-sentence summary")
    strengths: list[str]
    issues: list[str]

agent = create_agent(
    model=llm,
    tools=[my_tool],
    system_prompt="You are a code reviewer.",
    response_format=CodeReview,
)
result = agent.invoke({"messages": [("human", "Review this code")]})
```

> **注意**: DeepSeek 的 thinking 模式与 `response_format` 冲突，需要在初始化时添加 `extra_body={"thinking": {"type": "disabled"}}`。

### Sub-agent 模式

```python
from langchain.agents import create_agent

# 子 Agent
github_agent = create_agent(
    model=llm,
    tools=[query_github_activity],
    system_prompt="You are a GitHub data collector.",
)

# 把子 Agent 封装成工具
@tool
def collect_github_data(username: str) -> str:
    """收集 GitHub 用户的原始活动数据。"""
    result = github_agent.invoke({"messages": [("human", f"Get activity for {username}")]})
    return result["messages"][-1].content

# 主 Agent — 把子 Agent 当作工具调用
main_agent = create_agent(
    model=llm,
    tools=[collect_github_data, write_weekly_report],
    system_prompt="You are a report coordinator.",
)
```

### 自定义 Agent（StateGraph）

```python
from langgraph.graph import START, StateGraph
from langgraph.prebuilt import ToolNode

graph = StateGraph(MyState)
graph.add_node("agent", call_model)
graph.add_node("tools", tool_node)
graph.add_conditional_edges("agent", should_continue, ["tools", END])
graph.add_edge("tools", "agent")
graph.add_edge(START, "agent")
```

## 旧版情况（参考）

之前所有的 Agent 类（`create_tool_calling_agent`、`create_react_agent`、`create_openai_functions_agent`、`create_structured_chat_agent`、`AgentExecutor` 等）在 LangChain 1.x 中已统一为 `create_agent`。

## Agent 类型对比

选择建议：**优先用默认 Tool-calling Agent**，不够用时按需升级。

| 类型 | 配置方式 | 适用场景 |
|------|---------|---------|
| **Tool-calling Agent**（默认） | `create_agent(model, tools=[...])` | 一般问答 + 工具调用。LLM 自主决定何时调工具、调哪个，适合大多数场景 |
| **Structured Output Agent** | `create_agent(model, response_format=MyModel)` | 需要固定结构输出的场景，如代码审查、信息抽取、表单填充。输出直接是 Pydantic 对象 |
| **Sub-agent 模式** | Agent 嵌套，子 Agent 封装为工具 | 多步骤复杂任务。主 Agent 负责任务分解，子 Agent 专注子任务（如先查数据再生成报告） |
| **自定义 StateGraph Agent** | 手动 `StateGraph` + `ToolNode` | 需要对循环逻辑做精细控制的场景，如自定义终止条件、中间步骤介入、注入外部状态 |
