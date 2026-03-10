---
title: "Demo 演示"
weight: 100
---

# 端到端 Demo 演示

## 完整用户流程

[请在此处插入 Demo 演示截图或视频]

### 步骤 1：访问 Dashboard

```bash
echo "打开浏览器访问: https://${CLOUDFRONT_DOMAIN}/login"
```

使用 Cognito 注册一个新账户（或使用测试账户登录）。

### 步骤 2：创建 OpenClaw 实例

在 Dashboard 中：
1. 点击 **"Provision Instance"**
2. 选择模型提供商：**Amazon Bedrock** 或 **SiliconFlow**
3. 点击 **"Create"**

后台自动执行：
```
Provisioning Service 收到请求
  → 从 JWT 提取用户 email
  → 生成 user_id (SHA256 前 8 位)
  → 创建 Namespace: openclaw-{user_id}
  → 创建 ResourceQuota
  → 创建 NetworkPolicy
  → 创建 ServiceAccount + Pod Identity
  → 创建 OpenClawInstance CRD
  → Operator Reconcile → StatefulSet + Service + PVC...
```

### 步骤 3：等待实例就绪

```bash
# 观察实例创建过程
kubectl get pods --all-namespaces -l app.kubernetes.io/name=openclaw -w

# 大约 30-60 秒后，Pod 变为 Running
```

Dashboard 中实例状态变为 **Running** ✅

### 步骤 4：连接到 Agent

点击 **"Connect"** 按钮，通过 WebSocket 连接到您的 OpenClaw Agent：

```
wss://${CLOUDFRONT_DOMAIN}/instance/{user_id}?token=xxx
```

### 步骤 5：与 Agent 对话

尝试与您的 AI Agent 对话：

```
You: Hello! What can you do?
Agent: I'm your personal AI assistant running on Kubernetes...

You: What model are you using?
Agent: I'm running on Claude Sonnet via Amazon Bedrock...
```

### 步骤 6：验证多租户隔离

```bash
# 列出所有用户 Namespace
kubectl get namespaces | grep openclaw-

# 验证 NetworkPolicy
kubectl get networkpolicy --all-namespaces | grep openclaw

# 验证 ResourceQuota
kubectl get resourcequota --all-namespaces | grep openclaw

# 验证 Pod Identity
aws eks list-pod-identity-associations \
  --cluster-name ${CLUSTER_NAME} \
  --query 'associations[].{Namespace:namespace,SA:serviceAccount}' \
  --output table
```

## 高级测试（可选）

### 测试 Kata Containers 隔离

```bash
# 创建一个 Kata 隔离的实例
# 在 Dashboard 中选择 "High Security (Kata)" 选项
# 或手动：
kubectl patch openclawinstance <instance-name> -n <namespace> \
  --type merge -p '{"spec":{"availability":{"runtimeClassName":"kata-fc"}}}'
```

### 压力测试

```bash
# 同时创建 10 个实例，观察 Karpenter 扩容
for i in $(seq 1 10); do
  curl -X POST https://${CLOUDFRONT_DOMAIN}/provision \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"provider": "bedrock"}' &
done
wait

# 观察节点扩容
kubectl get nodes -w
```

## 关键指标

| 指标 | 目标值 | 验证方法 |
|------|--------|----------|
| 实例创建时间 | < 60 秒 | Dashboard 观察 |
| CloudFront 延迟 (p50) | < 100ms | curl -w 计时 |
| 静态资源缓存命中率 | > 80% | CloudFront 控制台 |
| Karpenter 扩容时间 | < 2 分钟 | kubectl 观察 |

## 下一步

恭喜完成 Demo！最后一步：清理所有资源。
