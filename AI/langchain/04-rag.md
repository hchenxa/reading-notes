# RAG（检索增强生成）

## 背景

旧版的 `VectorStoreIndexCreator` 已移除。现在的 RAG 流程需要手动组合：documents → split → embed → store → retrieve → generate。

## Embedding 模型选型

| 方案 | 安装 | 类型 | 说明 |
|---|---|---|---|
| `FastEmbedEmbeddings` | `pip install fastembed` | 本地，轻量 | 默认 `bge-small-en-v1.5`，384维，~30MB，无需 GPU |
| `HuggingFaceEmbeddings` | `pip install sentence-transformers` | 本地，标准 | 模型选择多，但依赖 PyTorch（~1GB） |
| `OpenAIEmbeddings` | `pip install langchain-openai` | 云端 API | `text-embedding-3-small/large`，效果好，按量付费 |

**注意**：对话模型（如 `deepseek-v4-flash`）不能做 embedding。Embedding 和 LLM 是两种不同的模型。

## Vector Store 选型

| 向量库 | 安装 | 持久化 | 场景 |
|---|---|---|---|
| `InMemoryVectorStore` | 内置在 `langchain-core` | 否 | 学习测试，无需安装 |
| Chroma | `pip install chromadb` + `langchain-chroma` | 是（磁盘） | 最常用的本地方案 |
| FAISS | `pip install faiss-cpu` | 是（存文件） | Meta 出品，纯本地，速度快 |
| Qdrant | `pip install qdrant-client` | 可选 | 本地可跑，也支持服务端 |
| PGVector | `pip install pgvector` | 是（PostgreSQL） | 已有 PG 的话零额外运维 |
| Pinecone | `pip install pinecone-client` | 纯云 | 无需自建基础设施 |

```python
# InMemoryVectorStore（学习测试）
from langchain_core.vectorstores import InMemoryVectorStore
vectorstore = InMemoryVectorStore.from_documents(docs, embedding=embeddings)

# Chroma（本地持久化）
from langchain_chroma import Chroma
vectorstore = Chroma.from_documents(docs, embedding=embedding, persist_directory="./chroma_db")

# FAISS（存本地文件）
from langchain_community.vectorstores import FAISS
vectorstore = FAISS.from_documents(docs, embedding=embeddings)
```

## LangChain 方式

```python
rag_chain = (
    {"context": retriever | format_docs, "question": RunnablePassthrough()}
    | prompt | llm | StrOutputParser()
)
rag_chain.invoke("What is LangGraph?")
```

## LangGraph 方式

```python
class RagState(TypedDict):
    question: str
    context: str
    answer: str

graph = StateGraph(RagState)
graph.add_node("retrieve", retrieve_node)
graph.add_node("generate", generate_node)
graph.add_edge(START, "retrieve")
graph.add_edge("retrieve", "generate")
```

关键区别：LangChain 用 `|` 把 retrieve 和 generate 串在一个 pipeline 里；LangGraph 分成两个独立节点，状态通过 `RagState` 显式传递。
