# Repository Rules

## Documentation output(强制)

本仓库是个人技术笔记库,文档输出必须遵守 `docs/STYLE_GUIDE.md`。任何新建或实质性修改 Markdown 文档时:

1. **先读规范**:`docs/STYLE_GUIDE.md`。
2. **选一个主类型**:Explanation / Tutorial / How-to / Reference / Case study。
3. **套模板**:从 `docs/templates/<type>.md` 开始,不要直接写散文。
4. **必须有元信息块**:

   ```markdown
   > **类型**:How-to(操作指南)
   > **状态**:未实测(YYYY-MM-DD)
   > **版本基线**:<软件/版本>
   > **适用**:<读者与场景>
   > **不覆盖**:<边界>
   ```

   `状态` 只能是 `已实测` / `部分实测` / `未实测` / `设计稿`,并带日期。

5. **结构**:
   - 全文 1 个 H1;
   - H2 用 `## 一、标题`;
   - H3 用 `### 1.1 标题`;
   - 不出现 H4;
   - 第一节是结论/速查/目标,不是背景;
   - 结尾有 `## 下一步` 或 `## 参考`。

6. **代码**:
   - 每个代码块必须有语言标记(`bash` / `yaml` / `json` / `text` / `mermaid`);
   - 命令用 `bash`,不带 `$`;
   - 输出单独用 `text`;
   - 不编造输出;没跑过的写"预期输出"并标 `未实测`;
   - 不写真实 secret/token/私钥,用 `<...>` 占位。

7. **索引与链接**:
   - 新增文档后更新目标目录的 `README.md` 索引;
   - **不要修改 `_sidebar.md`**,它由 `generate-sidebar.sh` 自动生成;
   - 同一主题只有一个 canonical 文档,其他文档只链接,不复制。

8. **检查**:

   ```bash
   python3 scripts/check_docs.py <改动的文件>
   ```

   新文档要求零 error、零 warning;存量文档至少不新增 error。

## 重构规则

- 先列章节映射,再改文件;
- 保留已实测输出和技术事实;
- 结构重排与技术内容修改分开;
- 不为了统一格式而把 How-to 硬套成 Explanation;类型不匹配时先建议拆分。

## 可用工具

- `.claude/skills/technical-docs/SKILL.md` —— 写/改文档流程
- `.claude/agents/docs-editor.md` —— 文档审稿 agent
- `docs/templates/` —— 五种模板
- `scripts/check_docs.py` —— 自动检查

## 其他

- 不要主动提交 Git,除非用户明确要求。
- 修改 Kubernetes / Argo CD 实验配置前,先确认当前 context 和集群状态。
- 代理、kind、colima 的注意事项见用户记忆和相关笔记,不要假设 Pod 自动继承宿主代理。
