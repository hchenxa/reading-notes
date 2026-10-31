# GitHub SSO 本地实验(kind-argocd)

目标:给 `kind-argocd` 配上 GitHub 登录,验证 Dex → GitHub → RBAC 整条链路。

> 这是**本地实验版**:
> - `url: https://localhost:8080`(port-forward)
> - 不配 `orgs`,任何 GitHub 用户都能登录
> - 所有 SSO 用户默认只读,只有你的 GitHub login 是 admin
>
> 生产环境的 `orgs` / `teams` 配置见 `ArgoCD/07-SSO与Dex.md`。

---

## 1. 创建 GitHub OAuth App

GitHub → Settings → Developer settings → OAuth Apps → New OAuth App:

| 字段 | 值 |
|---|---|
| Application name | `argocd-kind-lab`(随意) |
| Homepage URL | `https://localhost:8080` |
| Authorization callback URL | `https://localhost:8080/api/dex/callback` |

拿到 **Client ID** 和 **Client Secret**。

> **注意**:这个 OAuth App 只用于**用户登录**,不用于 repo clone。Argo CD 的仓库连接走
> Repository Secret(PAT / SSH key / GitHub App),和 SSO 的 OAuth App 是两套独立凭据;
> 公开仓库则不需要凭据。如果仓库连接用 GitHub App,你会有一个 GitHub App(机器身份)
> 加一个 OAuth App(用户身份),这是正常的。

---

## 2. 填 Client ID

编辑 `argocd-cm-patch.yaml`,把:

```yaml
clientID: REPLACE_WITH_GITHUB_CLIENT_ID
```

替换成你的 Client ID。Client ID 不是秘密,可以留在文件里。

## 3. 填 Client Secret(不要提交进仓库)

```bash
cp secret.example.yaml /tmp/argocd-github-oauth.yaml
# 编辑 /tmp/argocd-github-oauth.yaml,替换 REPLACE_WITH_GITHUB_CLIENT_SECRET
```

## 4. 填 GitHub login

编辑 `argocd-rbac-cm-patch.yaml`,把 `REPLACE_WITH_GITHUB_LOGIN` 换成你的 GitHub
用户名(不是邮箱)。`useLoginAsID: true` 时 OIDC subject 就是它。

## 5. 应用配置

```bash
kubectl -n argocd apply -f /tmp/argocd-github-oauth.yaml

kubectl -n argocd patch configmap argocd-cm \
  --type merge --patch-file argocd-cm-patch.yaml

kubectl -n argocd patch configmap argocd-rbac-cm \
  --type merge --patch-file argocd-rbac-cm-patch.yaml
```

## 6. 给 Dex Pod 配代理

kind 节点里的代理只影响 containerd / kubelet;Dex Pod 不会继承。

```bash
PROXY=http://host.docker.internal:7890
NO_PROXY='localhost,127.0.0.1,.svc,.svc.cluster.local,10.0.0.0/8,10.244.0.0/16,10.96.0.0/16,172.16.0.0/12,192.168.0.0/16'

kubectl -n argocd set env deployment/argocd-dex-server \
  HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY" http_proxy="$PROXY" https_proxy="$PROXY" \
  NO_PROXY="$NO_PROXY" no_proxy="$NO_PROXY"
```

## 7. 验证

```bash
kubectl -n argocd rollout status deploy/argocd-dex-server
kubectl -n argocd logs deploy/argocd-dex-server --tail=100
```

日志里不应再出现 `dex is not configured`。

port-forward:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

浏览器打开 `https://localhost:8080`,应出现 **LOG IN VIA GITHUB**。
CLI:

```bash
argocd login localhost:8080 --sso --insecure
```

## 8. 验收

- 用你的 GitHub 账号登录后是 admin
- 用另一个 GitHub 账号登录后只有只读权限
- `kubectl -n argocd logs deploy/argocd-server` 没有 OIDC 错误
- `argocd account get-user-info`(若 CLI 支持)能看到 subject/groups

## 9. 清理

```bash
# 删 Dex 配置和 url
kubectl -n argocd patch configmap argocd-cm --type json \
  -p '[{"op":"remove","path":"/data/dex.config"},{"op":"remove","path":"/data/url"}]'

# 删 secret
kubectl -n argocd delete secret argocd-github-oauth

# 清空 RBAC(或改成你要保留的)
kubectl -n argocd patch configmap argocd-rbac-cm --type json \
  -p '[{"op":"remove","path":"/data"}]'

# 可选:去掉 Dex 代理
kubectl -n argocd set env deployment/argocd-dex-server \
  HTTP_PROXY- HTTPS_PROXY- http_proxy- https_proxy- NO_PROXY- no_proxy-
```

清理后记得在 GitHub 删除或保留 OAuth App。
