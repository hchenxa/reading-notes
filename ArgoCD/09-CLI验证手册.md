# 09-CLI 验证手册:SSO、RBAC、Project Role 与 Application

> 08 里的多租户实验大量依赖 UI 点击;这一篇把同样的检查全部落到 `argocd` CLI。
> 目标:登录、查看身份、判断权限、检查 project role、验证跨租户隔离,都不需要打开浏览器。
>
> **类型**:Reference(参考)
> **状态**:部分实测(2026-10-31;查询/授权命令已实测,部分写操作仅核对 help)
> **版本基线**:Argo CD v3.5.6
> **适用**:用 CLI 验证 SSO/RBAC/多租户配置,或写自动化测试
> **不覆盖**:Argo CD UI 的所有交互、ApplicationSet 的批量生成细节

---

## 一、速查表

| 要做什么 | 命令 |
|---------|------|
| SSO 登录 | `argocd login <server> --sso --insecure` |
| 无浏览器启动 SSO | `argocd login <server> --sso --sso-launch-browser=false --insecure` |
| 看当前用户 | `argocd account get-user-info -o yaml` |
| 判断当前用户能否操作 | `argocd account can-i <action> <resource> <subresource>` |
| 校验全局 RBAC 文件 | `argocd admin settings rbac validate --namespace argocd` |
| 校验某个 subject/group | `argocd admin settings rbac can <subject> <action> <resource> <subresource> --namespace argocd` |
| 列出项目 | `argocd proj list` |
| 查看 project role | `argocd proj role get <project> <role>` |
| 查看应用 | `argocd app list -p <project> -o name` |
| 预览 sync | `argocd app sync <app> --dry-run` |
| 等待健康 | `argocd app wait <app> --sync --health --timeout 120` |
| 生成 project token | `argocd proj role create-token <project> <role>` |
| 生成本地账号密码 hash | `argocd account bcrypt --password '<password>'` |

---

## 二、登录与身份

### 2.1 SSO 登录

```bash
argocd login localhost:8080 --sso --insecure
```

会打开浏览器完成 GitHub 登录。无浏览器环境:

```bash
argocd login localhost:8080 --sso --sso-launch-browser=false --insecure
```

它打印一个 URL,在别的机器上打开并完成授权,再把回调结果贴回 CLI。

### 2.2 用不同身份隔离 CLI 配置

`argocd login` 会覆盖当前 CLI 的 context。要同时保留多个用户,用独立的 `--config`:

```bash
argocd --config /tmp/argocd-a-viewer.yaml login localhost:8080 \
  --username tenant-a-viewer --password '<password>' --insecure

argocd --config /tmp/argocd-a-viewer.yaml account get-user-info -o yaml
```

后续所有命令都加同一个 `--config`,就等价于"以这个用户登录"。

### 2.3 本地账号

本地账号的能力写在 `argocd-cm` 的 `accounts.<name>` 值里:

```yaml
data:
  accounts.tenant-a-viewer: "api, login"
```

不是 `accounts.<name>.capabilities`。写错会报:

```text
Account tenant-a-viewer does not have login capability
```

### 2.4 看当前用户

```bash
argocd --config /tmp/argocd-a-viewer.yaml account get-user-info -o yaml
```

实测输出:

```yaml
iss: argocd
loggedIn: true
username: tenant-a-viewer
```

SSO 用户还会带 `groups`;本地账号没有 groups。

---

## 三、RBAC 判定

### 3.1 当前用户:`account can-i`

这是最直接、最接近真实 API 的检查方式,并且**会考虑 project role**:

```bash
argocd --config /tmp/argocd-a-viewer.yaml account can-i \
  get applications team-a/guestbook-dev
```

实测结果:

| 身份 | 命令 | 结果 |
|------|------|------|
| `tenant-a-viewer` | `get applications team-a/guestbook-dev` | `yes` |
| `tenant-a-viewer` | `sync applications team-a/guestbook-dev` | `no` |
| `tenant-a-viewer` | `get applications team-b/guestbook-team-b-dev` | `no` |
| `tenant-a-developer` | `sync applications team-a/guestbook-dev` | `yes` |
| `tenant-a-developer` | `sync applications team-b/guestbook-team-b-dev` | `no` |
| `tenant-b-viewer` | `get applications team-b/guestbook-team-b-dev` | `yes` |

可用 action:`get create update delete sync override action invoke`。
可用 resource:`clusters projects applications applicationsets repositories write-repositories certificates accounts gpgkeys logs exec extensions`。

### 3.2 指定 subject/group:`admin settings rbac can`

```bash
argocd --kube-context kind-argocd admin settings rbac can \
  hchenxa-org:argo-viewer get applications team-a/guestbook-dev --namespace argocd
# Yes

argocd --kube-context kind-argocd admin settings rbac can \
  hchenxa-org:argo-viewer get applications team-b/guestbook-team-b-dev --namespace argocd
# No
```

注意:它读取 `argocd-rbac-cm` 的**全局 policy**,**不会展开 AppProject 里的 project role**。如果项目里定义了 project role,它会打印:

```text
user defined roles not found in policies: role:admin,proj:team-b:viewer,proj:team-a:developer
```

这不是错误;project role 的最终判定要用实际登录后的 `account can-i`,或者看 `proj role get`。

### 3.3 语法校验

```bash
argocd --kube-context kind-argocd admin settings rbac validate --namespace argocd
# Policy is valid.
```

也可以校验本地文件:

```bash
argocd admin settings rbac validate --policy-file rbac-multitenant-patch.yaml
```

同样会提示 project role 不在全局 policy 里,但只要 `Policy is valid.` 就说明全局 CSV 语法没问题。

---

## 四、项目与 project role

### 4.1 项目和角色查询

```bash
argocd proj list
argocd proj get team-a
argocd proj role list team-a
argocd proj role get team-a developer
```

实测 `proj role get team-a developer`:

```text
Role Name:     developer
Description:   read and sync team-a applications
Policies:
p, proj:team-a:developer, projects, get, team-a, allow
p, proj:team-a:developer, applications, get, team-a/*, allow
p, proj:team-a:developer, applications, sync, team-a/*, allow
Groups:
<none>
```

### 4.2 创建和修改 project role

```bash
# 创建角色
argocd proj role create team-a developer --description "read and sync team-a apps"

# 添加 policy：-a action，-p allow/deny，-r resource，-o object
argocd proj role add-policy team-a developer \
  -a get -p allow -r applications -o 'team-a/*'

argocd proj role add-policy team-a developer \
  -a sync -p allow -r applications -o 'team-a/*'

# 绑定 SSO group
argocd proj role add-group team-a developer hchenxa-org:argo-viewer
```

### 4.3 项目创建

```bash
argocd proj create team-b \
  --src https://github.com/hchenxa/reading-notes.git \
  --dest https://kubernetes.default.svc,team-b-dev \
  --dest https://kubernetes.default.svc,team-b-prod
```

如果项目用 `name: in-cluster` 而不是 server URL,和 CLI 创建的写法可以共存;
Application 的 destination 匹配由 Argo CD 解析。

### 4.4 project token(给 CI 用)

```bash
argocd proj role create-token team-a developer
argocd proj role list-tokens team-a
argocd proj role delete-token team-a developer <token-id>
```

token 的权限就是 `proj:team-a:developer` 的 policy,适合给 CI 做 sync,不需要共享个人 SSO 会话。

---

## 五、Application 验证

### 5.1 列表和详情

```bash
argocd app list -p team-a -o name
argocd app list -p team-b -o name
argocd app get guestbook-team-b-dev -o json
```

`-o json` 配合 `jq` 或 Python 可以断言 `status.sync.status`、`status.health.status` 和 conditions。

### 5.2 diff 与 dry-run

```bash
argocd app diff guestbook-team-b-dev
argocd app sync guestbook-team-b-dev --dry-run
```

`--dry-run` 仍然会渲染清单和做 diff;它验证的是"权限 + 渲染",不会改集群。

### 5.3 等待同步和健康

```bash
argocd app wait guestbook-team-b-dev --sync --health --timeout 120
```

### 5.4 跨租户负向测试

用 CLI 创建 Application 时,如果 project 不允许目标 namespace,Argo CD 会在创建阶段直接拒绝:

```bash
argocd app create guestbook-cross-tenant-cli \
  --project team-a \
  --repo https://github.com/hchenxa/reading-notes.git \
  --revision main \
  --path ArgoCD/labs/guestbook \
  --dest-name in-cluster \
  --dest-namespace team-b-dev \
  --sync-policy manual
```

实测返回:

```text
rpc error: code = InvalidArgument desc = application spec for guestbook-cross-tenant-cli is invalid:
InvalidSpecError: application destination server 'in-cluster' and namespace 'team-b-dev'
do not match any of the allowed destinations in project 'team-a'
```

对象不会创建成功,不需要再 delete。

### 5.5 删除

```bash
argocd app delete guestbook-cross-tenant --yes --cascade=false
```

---

## 六、本地账号管理

```bash
# 列出
argocd account list

# 查看某个账号
argocd account get --account tenant-a-viewer -o yaml

# 生成 bcrypt hash(写入 argocd-secret)
argocd account bcrypt --password '<password>'

# 修改密码(管理员可以改其他账号)
argocd account update-password \
  --account tenant-a-viewer \
  --new-password '<new-password>'

# 生成/删除 API token
argocd account generate-token --account tenant-a-viewer --expires-in 24h
argocd account delete-token --account tenant-a-viewer <token-id>
```

本地账号适合实验和自动化;生产优先用 SSO group。

---

## 七、SSO group 怎么不用第二个账号也能测

没有第二个 GitHub 账号时,可以分两层验证:

1. **策略层**:用 `admin settings rbac can` 验证 group → 全局 role 的映射:

   ```bash
   argocd admin settings rbac can hchenxa-org:argo-viewer \
     get applications team-a/guestbook-dev --namespace argocd
   # Yes
   ```

2. **身份层**:临时把 `hchenxa` 加进 `argo-viewer` team(或新建测试账号),
   用 `argocd login --sso` 重新登录,然后:

   ```bash
   argocd account get-user-info -o yaml   # 看 groups
   argocd account can-i get applications team-a/guestbook-dev
   ```

   这一步才能验证"GitHub team → Dex groups claim → Argo CD RBAC"的完整链路。
   `admin settings rbac can` 只验证策略,不会拉取 GitHub team。

---

## 八、限制与注意事项

- `admin settings rbac can` 只读全局 `argocd-rbac-cm`,**不展开 AppProject project role**;
  判断当前用户请用 `account can-i`。
- `account can-i` 用的是当前 CLI 登录身份;切换用户要换 `--config` 或重新 `login`。
- `app sync --dry-run` 失败不一定是权限问题;如果 targetRevision 不存在,会报
  `unable to resolve ... to a commit SHA`。
- SSO group 只在登录时刷新;改 team 后必须重新登录,否则 `get-user-info` 还是旧 groups。
- `proj role add-policy` 的 `-o` 是 object(如 `team-a/*`),`-r` 是 resource
  (如 `applications`),别把两者写反。
- `proj role create-token` 的 token 权限就是该 project role,适合 CI;不要把个人 SSO token 塞进 CI。

---

## 九、参考

- [08-多租户RBAC](08-多租户RBAC.md)
- [07-SSO与Dex](07-SSO与Dex.md)
- [04-多集群与多租户](04-多集群与多租户.md)
- [Argo CD RBAC Configuration](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/)
- [Argo CD CLI: account](https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_account/)
- [Argo CD CLI: proj role](https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_proj_role/)
