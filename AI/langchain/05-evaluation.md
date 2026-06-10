# Evaluation（评测）

## 背景

LangChain 1.3 已移除了内置的 `langchain.evaluation` 模块。`langchain_classic.evaluation` 有兼容层但已废弃。

## 方案选型

| 方案 | 说明 |
|---|---|
| `deepeval` | 开源评测框架，支持多种指标，可接自定义 LLM |
| LangSmith | LangChain 官方平台，trace + 数据集评测 |
| 自写 LLM-as-judge | 直接用 LLM 打分，灵活但需要自己实现 |

## 评测维度

| 指标 | 测什么 | 分数含义 |
|---|---|---|
| Correctness | 答案与标准答案是否一致 | 0~1，越高越正确 |
| Hallucination | 答案是否与已知 context 冲突 | 0=无幻觉，1=有幻觉 |
| AnswerRelevancy | 答案是否回答了问题 | 0~1，越高越相关 |

## 流程：先生成，再评测

两个方式都采用这个模式：
1. 用 LLM 基于 context 生成回答（模拟 RAG 流程）
2. 再用评测指标对生成的回答打分

### deepeval 方式

```python
from deepeval.metrics import HallucinationMetric, AnswerRelevancyMetric
from deepeval.test_case import LLMTestCase
from deepeval.models import GPTModel

model = GPTModel(model="deepseek-v4-flash", base_url="https://api.deepseek.com/v1", api_key="...")
metric = HallucinationMetric(model=model)

tc = LLMTestCase(input="...", actual_output="...", context=["..."])
metric.measure(tc)
print(metric.score, metric.reason)
```

### 手写 LLM-as-Judge 方式

```python
def judge_correctness(question, actual, expected):
    prompt = f"""Rate 0.0~1.0 how correct the answer is...
    Question: {question}
    Actual: {actual}
    Expected: {expected}
    Output ONLY the number."""
    return float((prompt_template | llm | StrOutputParser()).invoke({...}))
```

Custom metric 通过继承 `BaseMetric` 实现。
