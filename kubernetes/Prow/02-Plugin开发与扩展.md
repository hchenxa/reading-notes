# Plugin 开发与扩展:启用、内置插件与外部服务

> **类型**:How-to(操作指南)
> **状态**:未实测(2026-11-27)
> **版本基线**:kubernetes-sigs/prow `main` @ `6dceccd02`(2026-11-26)
> **适用**:需要在 Prow 实例中启用插件、新增内置插件,或部署一个 external plugin
> **不覆盖**:plugin 机制的原理细节(见 [01-Plugin机制](01-Plugin机制.md))、Prow 整体部署

## 一、目标与适用场景

- **目标**:完成三种扩展之一:启用已有 plugin、新增一个内置 plugin、部署一个 external plugin。
- **适用**:维护 Prow 实例、给仓库加自动化、或需要把内部系统接入 Prow。
- **不适用**:只想了解 plugin 如何分发事件;这种情况先读 [01-Plugin机制](01-Plugin机制.md)。

三条路径的选择:

| 需求 | 路径 | 是否改 Prow 源码 |
|------|------|-----------------|
| 官方已有 plugin,只是没启用 | 改 `plugins.yaml` | 否 |
| 逻辑需要 ProwJob/Owners/Config,或希望跟 hook 一起发布 | 新增内置 plugin | 是 |
| 逻辑慢、依赖重、需要进程隔离或独立权限 | external plugin | 否 |

## 二、前置条件

- 能编译 kubernetes-sigs/prow 的 Go 工具链(版本以仓库 `go.mod` 为准);
- 一个可访问的 Prow 实例,或本地 Tilt 开发环境;
- 可修改 `plugins.yaml`、job 配置,并能运行 `checkconfig`;
- 若使用 GitHub App/PAT,相关凭据已通过文件挂载;
- 已读 [01-Plugin机制](01-Plugin机制.md),了解注册表、`Agent` 和 external plugin 契约。

## 三、操作步骤

### 3.1 启用一个已有 plugin

在 `plugins.yaml` 里把 plugin 名加到 org 或 org/repo 下:

```yaml
plugins:
  org:
    plugins:
    - lgtm
    - approve
    excluded_repos:
    - legacy-repo
  org/special-repo:
    plugins:
    - trigger
```

规则:

- org 级 plugin 对该 org 下所有仓库生效,`excluded_repos` 除外;
- repo 级 plugin 追加到 org 级之后;
- 同一个 plugin 不能同时出现在 org 级和 repo 级,除非该 repo 在 `excluded_repos` 里。

用 `checkconfig` 校验配置和 plugin 名:

```bash
checkconfig \
  --config-path=config/prow/config.yaml \
  --job-config-path=config/jobs \
  --plugin-config=config/prow/plugins.yaml
```

预期输出(未实测):命令退出码为 0,没有 `error` 级别的配置错误。

> **注意**:hook 自己不会校验 plugin 名是否存在;名字写错时不会报错,只会静默不生效。`checkconfig` 会拒绝未注册的 plugin 名,所以这一步不能省。

配置由 `plugins.ConfigAgent` 每分钟热加载,通常不需要重启 hook。验证方式:查看 hook 日志中的 reload 记录,或访问 `/plugin-help` 确认 plugin 出现在该仓库的列表里。

### 3.2 新增一个内置 plugin

以内置 plugin 名为 `my-plugin`、包目录为 `pkg/plugins/myplugin` 为例。

**第一步:创建包和 handler。**

```go
// Package myplugin implements the my-plugin plugin.
package myplugin

import (
	"sigs.k8s.io/prow/pkg/config"
	"sigs.k8s.io/prow/pkg/github"
	"sigs.k8s.io/prow/pkg/pluginhelp"
	"sigs.k8s.io/prow/pkg/plugins"
)

const pluginName = "my-plugin"

func init() {
	plugins.RegisterGenericCommentHandler(pluginName, handleGenericComment, helpProvider)
}

func handleGenericComment(pc plugins.Agent, e github.GenericCommentEvent) error {
	if e.Action != github.GenericCommentActionCreated {
		return nil
	}
	// 在这里检查 e.Body、调用 pc.GitHubClient 等。
	return nil
}

func helpProvider(_ *plugins.Configuration, _ []config.OrgRepo) (*pluginhelp.PluginHelp, error) {
	return &pluginhelp.PluginHelp{
		Description: "The my-plugin plugin does something useful.",
	}, nil
}
```

约定:

- `pluginName` 必须与 `plugins.yaml` 里的名字一致;目录名可以不同(参考 `issue-management` -> 包名 `issuemanagement`);
- handler 只依赖自己用到的接口,便于用 `fakegithub.FakeClient` 测试;
- 需要多种事件就多次调用 `Register*`,共用同一个 `helpProvider`。

**第二步:把包链接进 hook。**

在 `pkg/hook/plugin-imports/plugin-imports.go` 的 import 列表里按字母序加一行:

```go
_ "sigs.k8s.io/prow/pkg/plugins/myplugin"
```

> **坑**:仓库里还有一个 `cmd/hook/plugin-imports/plugin-imports.go`,当前没有被引用,但最近的 plugin PR 仍会同步更新它。漏掉它通常不影响构建,但会让两个文件继续漂移。

**第三步(可选):增加配置结构。**

如果 plugin 需要自己的配置:

1. 在 `pkg/plugins/config.go` 增加结构体和 `Configuration` 字段,字段要有 godoc 和 snake_case JSON tag;
2. 在 `setDefaults` 里补默认值;
3. 在 `Validate` 里补校验;
4. 增加 `XFor(org, repo)` 查询辅助函数;
5. 如果支持补充配置文件,把字段加入 `mergeFrom` 的白名单;
6. 在 `helpProvider` 里用 `plugins.CommentMap.GenYaml` 生成带注释的 YAML 片段。

**第四步:写测试。**

```go
func TestHandleGenericComment(t *testing.T) {
	fc := fakegithub.NewFakeClient()
	_ = fc
	// 构造 github.GenericCommentEvent,调用 handler,断言标签/评论等副作用。
}
```

运行:

```bash
hack/make-rules/go-test/unit.sh pkg/plugins/myplugin/...
```

预期输出(未实测):该包的测试全部 PASS。

**第五步:重新生成配置文档并校验。**

```bash
make update-codegen
make verify-codegen
```

`update-codegen` 会重新生成 `pkg/plugins/plugin-config-documented.yaml`;`verify-codegen` 在 CI 中检查生成结果是否最新。plugin 目录本身不需要手工登记到某个静态列表,plugin 目录页是运行时根据注册表生成的。

**第六步:构建并验证。**

重新构建 hook 镜像并部署,然后在测试仓库发一条会触发该 plugin 的评论,观察 hook 日志和 GitHub 副作用。

### 3.3 新增一个 external plugin

**第一步:在 `plugins.yaml` 注册。**

```yaml
external_plugins:
  org/repo:
  - name: my-external
    endpoint: http://my-external
    events:
    - issue_comment
    - pull_request
```

- key 可以是 `org/repo` 或 `org`;
- `events` 为空表示接收所有事件;
- 省略 `endpoint` 时默认 `http://<name>`。

**第二步:实现 HTTP 服务。**

external plugin 收到的请求与 GitHub 发给 hook 的请求形态一致,必须自己验签:

```go
package main

import (
	"encoding/json"
	"net/http"

	"sigs.k8s.io/prow/pkg/config/secret"
	"sigs.k8s.io/prow/pkg/github"
)

func main() {
	tokenGenerator := secret.GetTokenGenerator("/etc/webhook/hmac")

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		eventType, eventGUID, payload, ok, _ := github.ValidateWebhook(w, r, tokenGenerator)
		if !ok {
			return
		}
		_ = eventGUID

		switch eventType {
		case "issue_comment":
			var e github.IssueCommentEvent
			if err := json.Unmarshal(payload, &e); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			go handleIssueComment(e)
		}
		w.WriteHeader(http.StatusOK)
	})

	_ = http.ListenAndServe(":8080", nil)
}

func handleIssueComment(e github.IssueCommentEvent) {
	// 省略:解析命令、调用 GitHub API 等。
}
```

关键点:

- 只接受 `POST` + JSON,和 hook 的校验规则一致;
- 必须用与 hook 相同的 HMAC secret 验签(签名头会原样转发);
- 返回 2xx,否则 hook 会记录错误;传输错误会重试 5 次;
- 处理逻辑建议异步,避免阻塞 webhook 响应。

**第三步:实现 help(可选)。**

external plugin 可以实现 `POST /help`,响应 `PluginHelp` JSON,这样 deck 的 `/plugins` 页面也能展示它。hook 收集 external help 时只有一个 1 秒的总超时,慢的 help 会被静默丢弃。

**第四步:构建镜像并部署。**

把镜像加入 `.prow-images.yaml`,然后:

```bash
make build-single-image PROW_IMAGE=my-external
```

Prow 仓库不提供 external plugin 的 Kubernetes manifest,需要自己部署 Service/Deployment,并保证 `endpoint` 可达。

**第五步:接入 GitHub 能力。**

external plugin 通常需要自己的 GitHub client:

```bash
my-external \
  --github-token-path=/etc/github/token
```

多组织场景改用 GitHub App 的 `--github-app-id` 和 `--github-app-private-key-path`;需要知道哪些仓库启用了自己时,可以像 `needs-rebase` 一样加载 `plugins.ConfigAgent`。

## 四、验证

- [ ] `checkconfig` 退出码为 0,没有未知 plugin 名;
- [ ] hook 日志出现配置 reload,且没有校验错误;
- [ ] `/plugin-help` 返回的 JSON 中包含新 plugin(内置和 external 都适用);
- [ ] 在测试仓库发一条命令评论,plugin 产生预期标签/评论/ProwJob;
- [ ] 内置 plugin:`unit.sh` 对应包测试全部 PASS,`make verify-codegen` 通过;
- [ ] external plugin:endpoint 返回 2xx,hook 日志出现 `Dispatched event to external plugin`;
- [ ] 失败时先看 hook 日志中的 plugin 名、事件类型和错误,再看目标仓库的 plugin 配置。

```bash
# 查看 help 中是否包含目标 plugin(预期输出包含 plugin 名)
curl -s http://<hook-host>:8888/plugin-help | grep -o 'my-plugin'
```

预期输出:

```text
my-plugin
```

> **未实测**:以上命令未在真实 Prow 实例上执行,主机名和端口按实际部署替换。

## 五、回滚与清理

- 启用类变更:从 `plugins.yaml` 删除 plugin 名,等待热加载(约一分钟),不需要重启。
- 内置 plugin:从 `pkg/hook/plugin-imports/plugin-imports.go` 删除 import,重新构建 hook;未启用但已链接的 plugin 不会执行,通常可以暂时保留。
- 配置结构:删除 `pkg/plugins/config.go` 中的结构体、默认值、校验和辅助函数,再运行 `make update-codegen`。
- external plugin:先从 `external_plugins` 删除配置,再下线 Deployment/Service;顺序反过来会让 hook 持续重试失败的 endpoint。

## 六、排错

| 现象 | 原因 | 解决 |
|------|------|------|
| 启用后完全没反应 | plugin 名拼错、未注册、未加入 plugin-imports | 用 `checkconfig` 校验;确认 `pkg/hook/plugin-imports` 有对应 import |
| `checkconfig` 报未知 plugin | 名字与 `Register*` 的 name 不一致,或包没被链接 | 统一名字;补 import |
| 改了配置不生效 | 配置文件校验失败,hook 保留旧配置 | 看 hook 日志的 reload 错误;确认补充配置字段在合并白名单里 |
| external plugin 收不到事件 | key 不匹配、`events` 过滤、endpoint 默认值错误 | 检查 `external_plugins` 的 key 和事件名;显式写 endpoint |
| external plugin 偶尔收不到 | 事件反序列化失败发生在外部转发之前;或事件缺少 `repository.full_name` | 看 hook 日志;确认 payload 是可识别的 GitHub 事件 |
| help 页面没有新 plugin | help provider 返回 nil;external help 超过 1 秒 | 补 help provider;优化 external `/help` 响应 |
| help 的 YAML 片段没有注释 | 直接 `go build`,二进制名不是 `hook` | 用仓库的构建方式,确保 `version.Name=hook` |
| 测试之间互相影响 | 测试注册了全局 handler,名字冲突 | 每个测试用唯一 plugin 名,或避免并行修改全局注册表 |

## 七、参考

- [01-Plugin机制](01-Plugin机制.md):注册表、分发、配置合并、external 契约
- [03-GitHub事件与认证](03-GitHub事件与认证.md):webhook 验签、GitHub App/PAT
- [Prow Plugins 文档](https://docs.prow.k8s.io/docs/components/plugins/)(访问于 2026-11-27)
- [pkg/plugins GoDoc](https://pkg.go.dev/sigs.k8s.io/prow/pkg/plugins)
