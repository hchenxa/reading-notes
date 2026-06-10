# Checkpointer

LangGraph 的 checkpointer（检查点机制）是 graph 运行状态持久化的核心。每次节点执行后，checkpointer 会自动保存一个 checkpoint，记录当前 state 和所有 pending writes。

## 支持的类型

| Checkpointer | 包 | 持久化 | Async | 生产可用 | 适用场景 |
|---|---|---|---|---|---|
| **MemorySaver** | `langgraph-checkpoint`（内置） | 内存（不持久） | ✅ 原生 | ❌ | 本地开发、单元测试 |
| **SqliteSaver** | `langgraph-checkpoint-sqlite` | 文件 | ❌ 同步 | ⚠️ 有限 | 单进程、低并发场景 |
| **AsyncSqliteSaver** | `langgraph-checkpoint-sqlite` | 文件 | ✅ 异步 | ❌ 不推荐 | 本地异步开发 |
| **PostgresSaver** | `langgraph-checkpoint-postgres` | PostgreSQL | ❌ 同步 | ✅ 推荐 | 多进程/容器化部署 |
| **AsyncPostgresSaver** | `langgraph-checkpoint-postgres` | PostgreSQL | ✅ 异步 | ✅ 推荐 | 高并发生产环境 |

> **注意：** `MemorySaver` 和 `InMemorySaver` 是同一个类的别名。

## 各类型详细介绍

### MemorySaver

最简 checkpointer，数据完全存在内存中，进程重启即丢失。适合开发调试和编写测试，**不应该用于生产**。

```python
from langgraph.checkpoint.memory import MemorySaver

checkpointer = MemorySaver()
app = workflow.compile(checkpointer=checkpointer)

# 带 thread_id 调用
result = app.invoke(
    {"messages": [("user", "hello")]},
    config={"configurable": {"thread_id": "1"}}
)
```

**特点：**
- 零依赖、零配置
- 读写最快（纯内存操作）
- 原生支持 async（`aput`、`aget` 等）
- 重启后数据全部丢失

---

### SqliteSaver

基于 SQLite 文件持久化，数据保存在磁盘上，进程重启后可恢复。适合单进程服务、本地 demo、嵌入式场景。

```python
from langgraph.checkpoint.sqlite import SqliteSaver

# 从已有 sqlite3 连接创建
import sqlite3
conn = sqlite3.connect("checkpoints.db", check_same_thread=False)
checkpointer = SqliteSaver(conn)

# 或直接从连接字符串创建（快捷方式）
checkpointer = SqliteSaver.from_conn_string("./checkpoints.db")
```

**特点：**
- SQLite 写锁会串行化并发写入，高并发有瓶颈
- 依赖 `langgraph-checkpoint-sqlite`（需额外安装）
- 容器化部署中如果没有挂载持久卷，重启后数据同样丢失

---

### AsyncSqliteSaver

SqliteSaver 的异步版本，使用 `aiosqlite`。LangGraph 官方文档明确**不推荐用于生产**。

```python
from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver

checkpointer = AsyncSqliteSaver.from_conn_string("./checkpoints.db")
```

---

### PostgresSaver

基于 PostgreSQL 的持久化方案，适合生产部署。支持连接池、Pipeline 批处理模式。

```python
from langgraph.checkpoint.postgres import PostgresSaver

# 单连接
checkpointer = PostgresSaver.from_conn_string(
    "postgresql://user:pass@localhost:5432/db"
)

# 连接池（推荐）
from psycopg_pool import ConnectionPool
with ConnectionPool("postgresql://user:pass@localhost:5432/db") as pool:
    conn = pool.getconn()
    checkpointer = PostgresSaver(conn)
    checkpointer.setup()  # 创建表
    app = workflow.compile(checkpointer=checkpointer)
```

**特点：**
- 完全 ACID，数据安全可靠
- 可跨进程、跨机器共享
- checkpoint 数据可直接做 SQL 查询和审计
- 连接池模式下可支撑大规模并发
- 依赖 `langgraph-checkpoint-postgres`（需额外安装）

---

### AsyncPostgresSaver

PostgresSaver 的异步版本，基于 `psycopg` async 支持。是高并发生产环境的**推荐方案**。

```python
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

async with AsyncPostgresSaver.from_conn_string(
    "postgresql://user:pass@localhost:5432/db"
) as checkpointer:
    await checkpointer.setup()
    app = workflow.compile(checkpointer=checkpointer)
```

**特点：**
- 非阻塞写入，相比同步版本吞吐提升 3-5 倍
- 适合 FastAPI / uvicorn 等异步框架

---

## 选择建议

| 场景 | 推荐 | 原因 |
|---|---|---|
| 本地开发、写测试 | MemorySaver | 零配置、每次重置干净 |
| 单进程服务、小项目 | SqliteSaver | 文件持久化、无需外部依赖 |
| 多进程/容器化部署 | PostgresSaver | ACID、可跨进程共享 |
| 高并发生产（FastAPI） | AsyncPostgresSaver | 非阻塞、吞吐高 |
| 预算有限、不想上 PG | SqliteSaver + 定期备份 | 简单够用 |

## 安装

```bash
# MemorySaver 随 langgraph 自带，无需额外安装
pip install langgraph

# Sqlite saver
pip install langgraph-checkpoint-sqlite

# Postgres saver
pip install langgraph-checkpoint-postgres
```
