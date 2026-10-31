# 多租户 RBAC 实验清单

配套文档：[08-多租户RBAC](../../08-多租户RBAC.md)。

这个 lab 创建两个租户：

- `team-a`：已有 AppProject，增加 `developer` project role
- `team-b`：新建 AppProject + `guestbook-team-b-dev` Application

并用三个本地账号验证全局 RBAC 和 project role 的差异。

## 文件

| 文件 | 作用 |
|------|------|
| `team-b-project.yaml` | 创建 `team-b` AppProject，只允许 team-b-dev/prod |
| `guestbook-team-b-dev.yaml` | 在 team-b 部署 guestbook |
| `cross-tenant-app.yaml` | 负向测试：team-a 项目指向 team-b namespace |
| `team-a-roles-patch.yaml` | 给 team-a 增加 developer project role |
| `rbac-multitenant-patch.yaml` | 全局 RBAC + project role 绑定 |
| `local-accounts-cm-patch.yaml` | 开启三个本地实验账号 |
| `local-accounts-secret.example.yaml` | bcrypt 密码占位文件 |

## 1. 创建 team-b

```bash
kubectl -n argocd apply -f team-b-project.yaml
kubectl -n argocd apply -f guestbook-team-b-dev.yaml
kubectl -n argocd patch appproject team-a \
  --type merge --patch-file team-a-roles-patch.yaml
```

## 2. 应用 RBAC

```bash
kubectl -n argocd patch configmap argocd-rbac-cm \
  --type merge --patch-file rbac-multitenant-patch.yaml
```

注意 `policy.default` 是 `role:no-access`，不能是 `role:readonly`；后者会让所有已登录用户看到所有项目。

## 3. 创建本地测试账号

```bash
kubectl -n argocd patch configmap argocd-cm \
  --type merge --patch-file local-accounts-cm-patch.yaml

# 为每个账号生成 bcrypt hash，填入 /tmp/local-accounts-secret.yaml
cp local-accounts-secret.example.yaml /tmp/local-accounts-secret.yaml
argocd account bcrypt --password '<tenant-a-viewer-password>'
argocd account bcrypt --password '<tenant-b-viewer-password>'
argocd account bcrypt --password '<tenant-a-developer-password>'

kubectl -n argocd patch secret argocd-secret \
  --type merge --patch-file /tmp/local-accounts-secret.yaml
```

本地账号的能力写在 `accounts.<name>` 的值里，不是 `accounts.<name>.capabilities`。

## 4. 验证

```bash
# team-a 只读
argocd --config /tmp/a-viewer.yaml login localhost:8080 \
  --username tenant-a-viewer --password '<password>' --insecure
argocd --config /tmp/a-viewer.yaml app list

# team-b 只读
argocd --config /tmp/b-viewer.yaml login localhost:8080 \
  --username tenant-b-viewer --password '<password>' --insecure
argocd --config /tmp/b-viewer.yaml app list

# team-a developer
argocd --config /tmp/a-dev.yaml login localhost:8080 \
  --username tenant-a-developer --password '<password>' --insecure
argocd --config /tmp/a-dev.yaml app sync <team-a-app> --dry-run
```

预期：

| 身份 | 能看的应用 | 能 sync |
|------|-----------|--------|
| `tenant-a-viewer` | 只有 team-a | 否 |
| `tenant-b-viewer` | 只有 team-b | 否 |
| `tenant-a-developer` | team-a | 是（team-a） |

## 5. 跨租户拒绝测试

```bash
kubectl -n argocd apply -f cross-tenant-app.yaml
kubectl -n argocd get application guestbook-cross-tenant \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
kubectl -n argocd delete application guestbook-cross-tenant --wait=false
```

预期：

```text
InvalidSpecError: application destination server 'in-cluster' and namespace 'team-b-dev'
do not match any of the allowed destinations in project 'team-a'
```

## 6. 清理

```bash
kubectl -n argocd delete application guestbook-team-b-dev --wait=false
kubectl -n argocd delete appproject team-b
kubectl -n argocd patch appproject team-a --type json \
  -p '[{"op":"remove","path":"/spec/roles"}]'
```

本地账号可以从 `argocd-cm` 和 `argocd-secret` 删除；RBAC 恢复到实验前的配置。
