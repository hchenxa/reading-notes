---
name: technical-docs
description: Write, restructure, or review Markdown documentation in this repository using its Diátaxis-based style guide and templates. Use when creating a new note, updating an existing doc, reorganizing sections, or checking documentation consistency.
---

# Technical Docs

本仓库所有 Markdown 文档必须遵守 `docs/STYLE_GUIDE.md`。写或改文档时按下面的流程执行,不要凭感觉直接输出。

## 必须先读

1. `docs/STYLE_GUIDE.md` —— 规范正文
2. `docs/templates/<type>.md` —— 对应类型的骨架
3. 目标目录的 `README.md` —— 主题索引和已有文档的写法

## 工作流程

### 1. 判定文档类型

从五种类型中选**一个主类型**:

| 类型 | 何时用 | 模板 |
|------|--------|------|
| Explanation | 解释概念、机制、取舍 | `docs/templates/explanation.md` |
| Tutorial | 带读者从零完成一件事 | `docs/templates/tutorial.md` |
| How-to | 解决一个具体任务 | `docs/templates/how-to.md` |
| Reference | 字段、矩阵、默认值 | `docs/templates/reference.md` |
| Case study | 事故、异常、根因分析 | `docs/templates/case-study.md` |

混合内容拆成多篇,或用"不覆盖"链接到 canonical 文档。

### 2. 先写元信息块

```markdown
> **类型**:How-to(操作指南)
> **状态**:未实测(YYYY-MM-DD)
> **版本基线**:<软件/版本>
> **适用**:<读者与场景>
> **不覆盖**:<边界>
```

状态只能是 `已实测` / `部分实测` / `未实测` / `设计稿`,并带日期。
没在当前环境跑过的命令或结论,标 `未实测`,不要写"输出如下"。

### 3. 再搭骨架

复制对应模板,先把 H2 标题和每节的一句话目标写出来,再填内容。
不要先写一大段散文再补结构。

### 4. 按规范写正文

- 全文 1 个 H1;H2 用 `## 一、标题`;H3 用 `### 1.1 标题`;不出现 H4。
- 第一节是结论/速查/目标,不是背景。
- 操作类必须有:前置条件、步骤、验证、排错、回滚(如适用)。
- 命令用 `bash`,不带 `$`;输出单独用 `text`;代码块必须有语言。
- 表格只放结构化数据,不超过 5 列。
- 提示统一用 `> **注意**:` / `> **坑**:` / `> **未实测**:` / `> **安全**:`。
- 不复制其他 canonical 文档的内容,只链接。

### 5. 更新索引与交叉链接

- 新增文档后更新目标目录 `README.md` 的文件索引。
- **不要修改 `_sidebar.md`**,它由 `generate-sidebar.sh` 自动生成。
- 在 `## 下一步` 或 `## 参考` 里链接相关文档。

### 6. 检查

```bash
python3 scripts/check_docs.py <文件路径>
```

新文档要求零 error、零 warning;存量文档至少不新增 error。

## 重构已有文档

1. 先列出"保留 / 移动 / 删除 / 待补"的章节映射;
2. 保留所有已实测输出和事实,不趁机改技术结论;
3. 结构重排和技术内容修改分开做;
4. 重排后按模板补齐缺失的元信息、结论、验证、排错;
5. 跑检查脚本,更新 README 索引和交叉链接。

## 禁止

- 不要编造命令输出、日志、错误码;示例要标明"示例"。
- 不要写真实密码、token、私钥;用 `<...>` 占位。
- 不要把长段落塞进表格或代码块。
- 不要手改 `_sidebar.md`。
- 不要为了"看起来完整"而堆砌空章节;没有内容就删掉该节并写"不覆盖"。

## 相关文件

- `docs/STYLE_GUIDE.md`
- `docs/templates/`
- `.claude/agents/docs-editor.md`
- `scripts/check_docs.py`
- `CLAUDE.md`
