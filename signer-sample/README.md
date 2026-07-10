# signer-sample

Ed25519 数字签名示例项目，包含签名服务端和验签客户端。

## 项目结构

```
├── sign/
│   └── sign.go          # 核心库：密钥生成、签名、验签
├── cmd/
│   ├── server/main.go   # 签名端：生成密钥对并对消息签名
│   └── client/main.go   # 验签端：用公钥验证签名有效性
```

## 快速开始

```bash
# 服务端生成密钥并签名
go run ./cmd/server -msg "your message here"

# 客户端验签（复制 server 输出的命令）
go run ./cmd/client -pub <public-key> -sig <signature> -msg "your message here"
```

## 算法

使用 `crypto/ed25519`（标准库），密钥和签名均以 hex 编码输出。
