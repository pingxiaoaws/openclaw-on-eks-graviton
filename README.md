# OpenClaw Operator on EKS with Kata Containers

在 Amazon EKS 上使用 Kata Containers 和 Firecracker 部署 OpenClaw 的完整解决方案。

## 📖 项目简介

本项目展示如何在 AWS Graviton (ARM64) 裸金属实例上使用 Kata Containers 和 Firecracker 运行 OpenClaw AI Agent，提供硬件级别的虚拟化隔离，实现更高的安全性和多租户支持。

### 为什么选择这个方案？

**OpenClaw + Kata Containers + Firecracker + Graviton** 的组合提供了：

- ✅ **VM 级别隔离**：每个 Agent 运行在独立的 microVM 中
- ✅ **安全增强**：防止容器逃逸，满足合规要求
- ✅ **性能优化**：Firecracker 启动速度快（< 150ms），内存开销低
- ✅ **成本优势**：Graviton 实例性价比更高
- ✅ **容器兼容**：完全兼容 Kubernetes 和 OCI 标准

## 🎯 核心组件

### 1. OpenClaw

OpenClaw 是一个云原生 AI Agent 运行时，支持：

- **多 AI 提供商**：Claude (Bedrock/API), OpenAI, Google AI 等
- **技能系统**：可扩展的 MCP (Model Context Protocol) 技能
- **浏览器自动化**：内置 Chromium 支持
- **代码执行**：安全的沙箱执行环境
- **声明式配置**：通过 Kubernetes CRD 管理

**优势**：
- 🚀 容器化部署，易于扩展
- 🔒 内置安全策略（NetworkPolicy, RBAC, Pod Security）
- 📊 可观测性（Prometheus metrics, 结构化日志）
- 🔄 自动更新和回滚
- 💾 S3 备份和恢复

### 2. Kata Containers

Kata Containers 将容器的便利性与虚拟机的安全性结合：

- **硬件虚拟化**：使用 KVM/ARM Hyp 提供隔离
- **独立内核**：每个容器有独立的 Guest 内核
- **攻击面减少**：Container escape 需要突破 VM 边界
- **兼容性**：完全兼容 OCI 和 Kubernetes

**Kata 3.27.0 特性**：
- Firecracker 1.7 支持
- ARM64 优化
- Devmapper snapshotter 性能提升
- 降低内存开销

### 3. Firecracker

AWS 开源的 microVM 技术，专为 Serverless 设计：

- **极速启动**：< 150ms 冷启动
- **低开销**：每个 VM 仅需 ~5MB 内存
- **安全隔离**：每个 VM 独立进程 + seccomp 过滤
- **多租户友好**：支持高密度部署

**对比传统 VM**：

| 指标 | Firecracker | QEMU/KVM | Docker (runc) |
|------|-------------|----------|---------------|
| 启动时间 | < 150ms | 2-5s | 50-100ms |
| 内存开销 | ~5MB | 100-200MB | ~1MB |
| 隔离级别 | VM | VM | Namespace |
| 密度 | 高 | 中 | 很高 |

### 4. AWS Graviton

ARM64 架构的云原生处理器：

- **性价比**：比 x86 实例便宜 20-40%
- **性能**：单核性能和多核扩展性优秀
- **能效**：功耗更低，更环保
- **生态**：主流软件都已支持 ARM64

**为什么用 Graviton Metal？**
- **KVM 支持**：Kata Containers 需要硬件虚拟化
- **高密度**：Metal 实例提供完整的物理资源
- **成本效率**：Metal 实例按小时计费，适合高密度场景

## 🏗️ 架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Amazon EKS Cluster                            │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Standard Node Group (m5.large)                              │   │
│  │  - OpenClaw Operator                                         │   │
│  │  - System workloads                                          │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Kata Node Group (c6g.metal - ARM64 Graviton)               │   │
│  │                                                              │   │
│  │  ┌─────────────────────────────────────────────────────┐   │   │
│  │  │  Pod: openclaw-kata-bedrock-0                        │   │   │
│  │  │  RuntimeClass: kata-fc                               │   │   │
│  │  │                                                       │   │   │
│  │  │  ┌──────────────────────────────────────────────┐   │   │   │
│  │  │  │  Firecracker microVM                         │   │   │   │
│  │  │  │  Kernel: 6.18.12 (Guest)                     │   │   │   │
│  │  │  │                                               │   │   │   │
│  │  │  │  ┌─────────────┐  ┌────────────────┐       │   │   │   │
│  │  │  │  │  openclaw   │  │  gateway-proxy  │       │   │   │   │
│  │  │  │  │  container  │  │  (sidecar)      │       │   │   │   │
│  │  │  │  └─────────────┘  └────────────────┘       │   │   │   │
│  │  │  └──────────────────────────────────────────────┘   │   │   │
│  │  └─────────────────────────────────────────────────────┘   │   │
│  │                                                              │   │
│  │  Host Kernel: 6.17.0-1007-aws                               │   │
│  │  Containerd + Kata Runtime                                  │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 网络流量路径

```
External Client
      ↓
LoadBalancer / Ingress
      ↓
Kubernetes Service (ClusterIP)
      ↓
Gateway Proxy Sidecar :18790
      ↓
OpenClaw Container :18789
      ↓
AI Provider (AWS Bedrock)
```

## 📁 项目结构

```
.
├── README.md                    # 本文档
├── eksctl/                      # EKS 集群配置
│   └── cluster-with-kata.yaml   # 完整的 eksctl 配置（含 Kata 节点）
├── kata-deployment/             # Kata Containers 部署
│   ├── kata-firecracker-deploy.yaml       # Kata DaemonSet
│   └── kata-firecracker-runtimeclass.yaml # RuntimeClass 定义
├── openclaw-deployment/         # OpenClaw 实例部署
│   └── openclaw-kata-bedrock.yaml  # OpenClaw with Kata 配置
├── openclaw-operator/           # 改造后的 Operator 源码
│   ├── api/v1alpha1/            # CRD 定义（含 runtimeClassName）
│   ├── internal/controller/     # 控制器逻辑
│   ├── internal/resources/      # 资源构建（含 StatefulSet runtimeClassName 支持）
│   ├── config/crd/bases/        # 生成的 CRD YAML
│   ├── charts/                  # Helm Chart
│   └── docs/                    # Operator 文档
├── scripts/                     # 辅助脚本
│   └── install-kata-firecracker.sh  # Kata 自动安装脚本
└── docs/                        # 项目文档
    ├── DEPLOYMENT-SUCCESS.md             # 部署成功报告
    ├── KATA-GRAVITON-DEPLOYMENT-SUMMARY.md  # Kata Graviton 部署总结
    ├── KATA-QUICK-REFERENCE.md           # Kata 快速参考
    └── CLAUDE.md                         # OpenClaw 部署指南
```

## 🚀 快速开始

### 前提条件

- AWS 账号，已配置 CLI
- `eksctl` >= 0.176.0
- `kubectl` >= 1.34
- `helm` >= 3.12

### 步骤 1：创建 EKS 集群

使用提供的 eksctl 配置创建集群：

```bash
cd eksctl
eksctl create cluster -f cluster-with-kata.yaml
```

这将创建：
- 1 个 EKS 1.34 集群
- 2 个 m5.large 标准节点（用于系统工作负载）
- 1 个 c6g.metal Graviton 节点（用于 Kata 工作负载）
- 自动安装 Kata Containers 3.27.0 + Firecracker 1.7

**注意**：首次创建需要 15-20 分钟。

### 步骤 2：验证 Kata 安装

等待 Kata DaemonSet 就绪：

```bash
kubectl wait --for=condition=ready pod -l app=kata-firecracker-deploy -n kata-system --timeout=300s
```

验证 RuntimeClass：

```bash
kubectl get runtimeclass kata-fc
```

测试 Kata Container：

```bash
kubectl run kata-test --image=busybox --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"kata-fc"}}' \
  -- sh -c "echo 'Running in Firecracker VM!' && uname -a && sleep 3600"

# 等待 Pod 就绪
kubectl wait --for=condition=ready pod/kata-test --timeout=120s

# 验证内核版本（应该是 Kata VM 内核，不是主机内核）
kubectl exec kata-test -- uname -r
```

### 步骤 3：部署 OpenClaw Operator

安装改造后的 Operator（支持 runtimeClassName）：

```bash
cd openclaw-operator

# 安装 CRD
make install

# 部署 Operator
kubectl apply -k config/default

# 等待 Operator 就绪
kubectl wait --for=condition=available deployment/openclaw-operator \
  -n openclaw-operator-system --timeout=120s
```

**或者使用 Helm**：

```bash
helm install openclaw-operator ./charts/openclaw-operator \
  --namespace openclaw-operator-system \
  --create-namespace
```

### 步骤 4：部署 OpenClaw 实例

首先创建 AWS credentials Secret（用于 Bedrock）：

```bash
kubectl create namespace openclaw

kubectl create secret generic aws-credentials \
  --from-literal=AWS_ACCESS_KEY_ID=<your-access-key> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<your-secret-key> \
  --from-literal=AWS_REGION=us-west-2 \
  -n openclaw
```

部署 OpenClaw 实例：

```bash
kubectl apply -f openclaw-deployment/openclaw-kata-bedrock.yaml
```

等待实例就绪：

```bash
kubectl wait --for=condition=ready pod/openclaw-kata-bedrock-0 \
  -n openclaw --timeout=300s
```

### 步骤 5：验证部署

检查 OpenClaw 实例状态：

```bash
kubectl get openclawinstance -n openclaw
# NAME                    PHASE     READY   GATEWAY
# openclaw-kata-bedrock   Running   True    openclaw-kata-bedrock.openclaw.svc:18789

kubectl get pods -n openclaw
# NAME                      READY   STATUS    RESTARTS   AGE
# openclaw-kata-bedrock-0   2/2     Running   0          5m
```

验证 Pod 运行在 Kata Container 中：

```bash
# 检查 runtimeClassName
kubectl get pod openclaw-kata-bedrock-0 -n openclaw \
  -o jsonpath='{.spec.runtimeClassName}'
# Output: kata-fc

# 检查内核版本（应该是 Kata VM 内核）
kubectl exec -n openclaw openclaw-kata-bedrock-0 -c openclaw -- uname -r
# Output: 6.18.12 (Kata VM 内核，不是主机的 6.17.x)

# 检查节点标签
kubectl get pod openclaw-kata-bedrock-0 -n openclaw \
  -o jsonpath='{.spec.nodeName}' | xargs kubectl get node -o wide
```

查看 OpenClaw 日志：

```bash
kubectl logs -n openclaw openclaw-kata-bedrock-0 -c openclaw -f
```

### 步骤 6：访问 OpenClaw

端口转发到本地：

```bash
kubectl port-forward -n openclaw svc/openclaw-kata-bedrock 18789:18789
```

在另一个终端中，使用 Claude Code CLI 连接：

```bash
# 获取 gateway token
TOKEN=$(kubectl get secret openclaw-kata-bedrock-gateway-token \
  -n openclaw -o jsonpath='{.data.token}' | base64 -d)

# 连接到 OpenClaw
claude-code connect ws://localhost:18789 --token $TOKEN
```

或者通过浏览器访问 Canvas UI：

```
http://localhost:18789/__openclaw__/canvas/
```

## 🔧 配置说明

### Kata RuntimeClass 配置

关键配置项在 `openclaw-kata-bedrock.yaml` 中：

```yaml
spec:
  availability:
    runtimeClassName: kata-fc      # 使用 Kata Firecracker runtime
    nodeSelector:
      workload-type: kata          # 调度到 Kata 节点
    tolerations:
      - key: kata-dedicated        # 容忍 Kata 节点的 taint
        operator: Exists
        effect: NoSchedule

  resources:
    requests:
      cpu: "600m"      # +100m 用于 VM 开销
      memory: "1.2Gi"  # +200Mi 用于 VM 开销
    limits:
      cpu: "2"
      memory: "4Gi"
```

### Operator RuntimeClassName 支持

改造的关键代码：

**1. CRD 定义** (`api/v1alpha1/openclawinstance_types.go`):

```go
type AvailabilitySpec struct {
    // RuntimeClassName refers to a RuntimeClass object in the cluster
    // +optional
    RuntimeClassName *string `json:"runtimeClassName,omitempty"`

    // ... 其他字段
}
```

**2. StatefulSet 构建** (`internal/resources/statefulset.go`):

```go
func BuildStatefulSet(instance *openclawv1alpha1.OpenClawInstance) *appsv1.StatefulSet {
    // ...

    sts := &appsv1.StatefulSet{
        Spec: appsv1.StatefulSetSpec{
            Template: corev1.PodTemplateSpec{
                Spec: corev1.PodSpec{
                    RuntimeClassName: instance.Spec.Availability.RuntimeClassName,
                    // ...
                },
            },
        },
    }

    return sts
}
```

### 性能调优

#### 资源配置

Kata Container 比标准容器需要额外的资源：

| 配置项 | runc | Kata (Firecracker) | 差异 |
|--------|------|-------------------|------|
| CPU requests | 500m | 600m | +100m |
| Memory requests | 1Gi | 1.2Gi | +200Mi |
| 启动时间 | ~10s | ~15s | +5s |

#### 存储性能

使用 GP3 EBS 卷，配置 IOPS：

```yaml
storage:
  persistence:
    enabled: true
    size: 10Gi
    storageClass: gp3  # GP3 支持自定义 IOPS
```

对于高 I/O 场景，考虑使用 NVMe 本地盘（m5d/c6gd 实例）。

## 📊 监控和可观测性

### Prometheus Metrics

OpenClaw 暴露 Prometheus metrics：

```bash
kubectl port-forward -n openclaw openclaw-kata-bedrock-0 9090:9090
curl localhost:9090/metrics
```

关键指标：
- `openclaw_requests_total` - 请求总数
- `openclaw_request_duration_seconds` - 请求延迟
- `openclaw_active_sessions` - 活跃会话数
- `openclaw_vm_memory_bytes` - VM 内存使用

### 日志

结构化 JSON 日志：

```bash
kubectl logs -n openclaw openclaw-kata-bedrock-0 -c openclaw | jq .
```

### 事件

查看 Kubernetes 事件：

```bash
kubectl get events -n openclaw --sort-by='.lastTimestamp'
```

## 🔒 安全最佳实践

### 1. 多层隔离

OpenClaw on Kata 提供三层隔离：

1. **Namespace 隔离**：Kubernetes namespace + RBAC
2. **NetworkPolicy**：默认 deny-all，只允许必要流量
3. **VM 隔离**：Firecracker microVM 硬件虚拟化边界

### 2. Pod Security

使用 Restricted Pod Security Standard：

```yaml
security:
  podSecurityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    runAsNonRoot: true
  containerSecurityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: false
    capabilities:
      drop:
        - ALL
```

### 3. Secret 管理

使用 Kubernetes Secrets + AWS IRSA：

```yaml
envFrom:
  - secretRef:
      name: aws-credentials  # Bedrock credentials

# 推荐：使用 External Secrets Operator
# 从 AWS Secrets Manager 同步
```

### 4. 网络策略

默认 deny-all，明确允许必要流量：

```yaml
networkPolicy:
  enabled: true
  allowDNS: true
  ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            name: ingress-nginx
      ports:
      - protocol: TCP
        port: 18789
```

## 🐛 故障排查

### Kata Pod 无法启动

**症状**：Pod 卡在 `ContainerCreating`

**排查步骤**：

```bash
# 1. 检查 DaemonSet 状态
kubectl get ds -n kata-system

# 2. 查看 DaemonSet 日志
kubectl logs -n kata-system -l app=kata-firecracker-deploy

# 3. 检查节点上的 Kata 二进制
kubectl debug node/<node-name> -- ls -l /host/opt/kata/bin/

# 4. 检查 containerd 配置
kubectl debug node/<node-name> -- cat /host/etc/containerd/config.toml | grep kata-fc

# 5. 查看 containerd 日志
kubectl debug node/<node-name> -- journalctl -u containerd -f
```

### Kata VM 启动超时

**症状**：Pod 启动时间 > 2 分钟

**可能原因**：
1. Firecracker 下载失败
2. 内核镜像损坏
3. 存储性能瓶颈

**解决方案**：

```bash
# 重新安装 Kata
kubectl delete ds kata-firecracker-deploy -n kata-system
kubectl apply -f kata-deployment/kata-firecracker-deploy.yaml

# 检查存储性能
kubectl run fio-test --image=dmonakhov/alpine-fio --rm -it -- \
  fio --name=test --ioengine=libaio --iodepth=64 --rw=randwrite \
  --bs=4k --direct=1 --size=1G --numjobs=4 --runtime=60
```

### OpenClaw 连接失败

**症状**：`kubectl logs` 显示 "Bedrock connection failed"

**排查步骤**：

```bash
# 1. 检查 AWS credentials
kubectl get secret aws-credentials -n openclaw -o yaml

# 2. 测试 Bedrock 连接
kubectl run aws-cli --image=amazon/aws-cli --rm -it \
  --env AWS_ACCESS_KEY_ID=<key> \
  --env AWS_SECRET_ACCESS_KEY=<secret> \
  --env AWS_REGION=us-west-2 \
  -- bedrock-runtime invoke-model \
  --model-id us.anthropic.claude-sonnet-4-5-20250929-v1:0 \
  --body '{"messages":[{"role":"user","content":"hello"}],"max_tokens":100}' \
  --region us-west-2 output.json

# 3. 检查 NetworkPolicy
kubectl get networkpolicy -n openclaw
```

## 📚 参考文档

### 项目文档

- [DEPLOYMENT-SUCCESS.md](docs/DEPLOYMENT-SUCCESS.md) - 详细的部署成功报告
- [KATA-GRAVITON-DEPLOYMENT-SUMMARY.md](docs/KATA-GRAVITON-DEPLOYMENT-SUMMARY.md) - Kata Graviton 部署总结
- [KATA-QUICK-REFERENCE.md](docs/KATA-QUICK-REFERENCE.md) - Kata 快速参考
- [CLAUDE.md](docs/CLAUDE.md) - OpenClaw 部署指南

### 外部资源

- [Kata Containers 官方文档](https://github.com/kata-containers/kata-containers)
- [Firecracker 文档](https://firecracker-microvm.github.io/)
- [OpenClaw GitHub](https://github.com/openclaw-rocks/openclaw)
- [AWS Graviton 性能指南](https://github.com/aws/aws-graviton-getting-started)

### AWS 博客

- [Enhancing Kubernetes Workload Isolation and Security using Kata Containers](https://aws.amazon.com/blogs/containers/enhancing-kubernetes-workload-isolation-and-security-using-kata-containers/)

## 🤝 贡献

欢迎贡献！请参考：

1. Fork 本项目
2. 创建 feature 分支 (`git checkout -b feat/amazing-feature`)
3. 提交更改 (`git commit -m 'feat: add amazing feature'`)
4. 推送到分支 (`git push origin feat/amazing-feature`)
5. 创建 Pull Request

## 📄 许可证

本项目使用 Apache 2.0 许可证 - 详见 [LICENSE](openclaw-operator/LICENSE) 文件。

## 💬 支持

遇到问题？

- 📖 查看 [故障排查](#-故障排查) 部分
- 💬 提交 [GitHub Issue](https://github.com/openclaw-rocks/k8s-operator/issues)
- 📧 联系维护者

---

**部署负责人**: AWS Solutions Architects
**最后更新**: 2026-02-28
**状态**: ✅ 生产就绪
