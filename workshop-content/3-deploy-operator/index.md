---
title: "部署 OpenClaw Operator"
weight: 40
---

# 部署 OpenClaw Kubernetes Operator

## OpenClaw Operator 简介

OpenClaw Kubernetes Operator 是本方案的核心控制组件。它监听 `OpenClawInstance` CRD 的变化，自动 Reconcile 出完整的运行时资源栈：

- **StatefulSet** — 管理 Agent Pod 的生命周期
- **Service** — 暴露 Gateway 端口（18789）
- **PVC** — 持久化工作空间和对话记录
- **ConfigMap** — Agent 配置（模型、技能等）
- **NetworkPolicy** — 网络隔离策略
- **PodDisruptionBudget** — 可用性保障
- **ServiceAccount + RBAC** — 最小权限访问

## 安装 Operator

### 方法一：使用 Helm Chart（推荐）

```bash
# 添加 Helm repo
helm repo add openclaw https://openclaw-rocks.github.io/k8s-operator
helm repo update

# 创建 Namespace
kubectl create namespace openclaw-system

# 安装 Operator
helm install openclaw-operator openclaw/openclaw-operator \
  --namespace openclaw-system \
  --set image.tag=latest \
  --set nodeSelector."kubernetes\\.io/arch"=arm64
```

### 方法二：使用 kubectl

```bash
# 安装 CRD
kubectl apply -f https://raw.githubusercontent.com/OpenClaw-rocks/k8s-operator/main/config/crd/bases/openclaw.rocks_openclawinstances.yaml
kubectl apply -f https://raw.githubusercontent.com/OpenClaw-rocks/k8s-operator/main/config/crd/bases/openclaw.rocks_openclawselfconfigs.yaml

# 部署 Operator
kubectl apply -f https://raw.githubusercontent.com/OpenClaw-rocks/k8s-operator/main/config/deploy/operator.yaml
```

## 验证 Operator

```bash
# 检查 Operator Pod
kubectl get pods -n openclaw-system
# 期望: openclaw-operator-xxx Running

# 检查 CRD
kubectl get crds | grep openclaw
# 期望:
# openclawinstances.openclaw.rocks
# openclawselfconfigs.openclaw.rocks

# 检查 Operator 日志
kubectl logs -n openclaw-system deployment/openclaw-operator --tail=20
```

## 测试：创建一个 OpenClaw 实例

让我们手动创建一个测试实例，验证 Operator 正常工作：

```yaml
cat << 'EOF' | kubectl apply -f -
apiVersion: openclaw.rocks/v1alpha1
kind: OpenClawInstance
metadata:
  name: test-agent
  namespace: openclaw-system
spec:
  envFrom:
    - secretRef:
        name: test-agent-keys
  storage:
    persistence:
      enabled: true
      size: 5Gi
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
EOF
```

```bash
# 观察 Operator 创建的资源
kubectl get all -n openclaw-system -l app.kubernetes.io/instance=test-agent

# 期望看到:
# pod/test-agent-0       Running
# service/test-agent     ClusterIP
# statefulset/test-agent 1/1
```

## 清理测试实例

```bash
kubectl delete openclawinstance test-agent -n openclaw-system
```

## OpenClawInstance CRD 关键字段

| 字段 | 说明 | 示例 |
|------|------|------|
| `spec.envFrom` | 环境变量来源（Secret） | API Keys 等 |
| `spec.storage.persistence` | 持久化存储配置 | 大小、StorageClass |
| `spec.resources` | 资源请求和限制 | CPU、Memory |
| `spec.availability.runtimeClassName` | 运行时类 | `kata-fc` |
| `spec.skills` | 预装技能列表 | MCP 服务器 |
| `spec.selfConfigure.enabled` | Agent 自适配 | true/false |

## 下一步

Operator 已就绪，接下来我们将部署 Provisioning Service，实现多租户自助服务。
