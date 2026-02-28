# OpenClaw on Kata Containers - 快速开始

5 分钟快速部署指南。

## 前提条件

```bash
# 安装必要工具
brew install eksctl kubectl helm awscli

# 配置 AWS credentials
aws configure
```

## 步骤 1：创建集群（15-20 分钟）

```bash
cd eksctl
eksctl create cluster -f cluster-with-kata.yaml
```

**注意**：这会创建一个 c6g.metal 实例，费用约 $2.18/小时。

## 步骤 2：验证 Kata 安装（2 分钟）

```bash
# 等待 Kata DaemonSet 就绪
kubectl wait --for=condition=ready pod \
  -l app=kata-firecracker-deploy \
  -n kata-system \
  --timeout=300s

# 验证 RuntimeClass
kubectl get runtimeclass kata-fc
```

## 步骤 3：部署 Operator（3 分钟）

```bash
cd ../openclaw-operator

# 方式 1：使用 Helm（推荐）
helm install openclaw-operator ./charts/openclaw-operator \
  --namespace openclaw-operator-system \
  --create-namespace

# 方式 2：使用 Kustomize
make install
kubectl apply -k config/default
```

## 步骤 4：部署 OpenClaw（5 分钟）

```bash
cd ../openclaw-deployment

# 创建 AWS credentials Secret
kubectl create namespace openclaw
kubectl create secret generic aws-credentials \
  --from-literal=AWS_ACCESS_KEY_ID=<your-key> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<your-secret> \
  --from-literal=AWS_REGION=us-west-2 \
  -n openclaw

# 部署 OpenClaw 实例
kubectl apply -f openclaw-kata-bedrock.yaml

# 等待就绪
kubectl wait --for=condition=ready pod/openclaw-kata-bedrock-0 \
  -n openclaw \
  --timeout=300s
```

## 步骤 5：验证部署

```bash
# 检查实例状态
kubectl get openclawinstance -n openclaw

# 验证运行在 Kata Container
kubectl exec -n openclaw openclaw-kata-bedrock-0 -c openclaw -- uname -r
# 应该输出: 6.18.12 (Kata VM 内核)

# 查看日志
kubectl logs -n openclaw openclaw-kata-bedrock-0 -c openclaw -f
```

## 步骤 6：访问 OpenClaw

```bash
# 端口转发
kubectl port-forward -n openclaw svc/openclaw-kata-bedrock 18789:18789

# 在另一个终端获取 token
TOKEN=$(kubectl get secret openclaw-kata-bedrock-gateway-token \
  -n openclaw -o jsonpath='{.data.token}' | base64 -d)

# 连接
claude-code connect ws://localhost:18789 --token $TOKEN
```

或者访问浏览器：http://localhost:18789/__openclaw__/canvas/

## 清理资源

```bash
# 删除 OpenClaw 实例
kubectl delete openclawinstance openclaw-kata-bedrock -n openclaw

# 删除 Operator
helm uninstall openclaw-operator -n openclaw-operator-system

# 删除集群
eksctl delete cluster -f eksctl/cluster-with-kata.yaml
```

## 故障排查

### Kata Pod 无法启动

```bash
kubectl get ds -n kata-system
kubectl logs -n kata-system -l app=kata-firecracker-deploy -c kata-artifacts
```

### Bedrock 连接失败

```bash
kubectl get secret aws-credentials -n openclaw -o yaml
kubectl logs -n openclaw openclaw-kata-bedrock-0 -c openclaw
```

## 下一步

- 📖 阅读 [完整文档](README.md)
- 🔒 查看 [安全最佳实践](README.md#-安全最佳实践)
- 📊 配置 [监控和告警](README.md#-监控和可观测性)
- 💰 优化 [成本](README.md#-成本分析)

## 获取帮助

- 查看 [故障排查指南](README.md#-故障排查)
- 提交 [GitHub Issue](https://github.com/openclaw-rocks/k8s-operator/issues)
- 阅读 [AWS 博客文章](docs/aws-blog-cn.md)
