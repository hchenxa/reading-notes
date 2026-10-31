# Reading Notes

This is a collection of my learning notes on various technologies.

## Topics

| Topic | Description |
|-------|-------------|
| [Go](go/) | Go language fundamentals, Gin, GORM |
| [Kafka](kafka/) | Kafka architecture, producer, consumer, broker |
| [Python](python/) | Python basics, data types, functions |
| [JavaScript](javascript/) | JavaScript fundamentals, DOM, events |
| [AI](AI/) | AI/ML concepts, LoRA, fine-tuning |
| [Argo CD](ArgoCD/) | Argo CD 一周掌握计划:GitOps 模型、同步机制、ApplicationSet、多集群与生产化 |
| [Ansible](ansible/) | Ansible automation |
| [Appium](appium/) | Appium mobile testing framework |
| [Kubernetes](kubernetes/) | Kubernetes internals, Pod scheduling |
| [Knative](Knative/) | Knative Serving on kind：Kourier / Istio 两套网络层实验、对象模型、从 Deployment 迁移 |
| [Istio](Istio/) | Istio 服务网格：升级方式与中断排查、Gateway 配置相关问题 |
| [TLS](TLS/) | TLS/mTLS 握手与双向认证、代理终结/透传/桥接、证书签发与管理 |
| [signer-sample](signer-sample/) | Ed25519 数字签名示例：签名服务端与验签客户端 |

## Documentation

所有笔记遵循 [docs/STYLE_GUIDE.md](docs/STYLE_GUIDE.md)。新文档从 `docs/templates/` 选择一种类型开始写;
提交前运行:

```bash
python3 scripts/check_docs.py <改动的文件>
```
