---
title: "运行时隔离"
weight: 70
---

# 运行时隔离：标准容器 vs Kata Containers

## 为什么需要运行时隔离？

在多租户 AI Agent 平台中，每个 Agent 实例可能：
- 执行用户提供的代码
- 访问用户的个人数据和对话记录
- 通过浏览器自动化访问外部服务

标准 Linux 容器共享宿主机内核，存在潜在的容器逃逸风险。对于高安全场景，需要 VM 级别的隔离。

## 方案对比

[请在此处插入运行时对比图]

| 维度 | 标准容器 (runc) | Kata Containers + Firecracker |
|------|----------------|-------------------------------|
| **隔离级别** | Linux Namespace + cgroups | VM（独立 Guest Kernel） |
| **启动时间** | ~10 秒 | ~15 秒（含 VM 启动 <150ms） |
| **内存开销** | ~1MB 运行时开销 | ~5MB（Firecracker VM 开销） |
| **容器逃逸风险** | 较高（共享内核） | 极低（VM 边界隔离） |
| **合规场景** | 一般场景 | 金融、医疗等高合规要求 |
| **部署密度** | 高 | 中（需要 Metal 实例） |
| **节点要求** | 任意实例类型 | Graviton Metal (c6g.metal) |

## 部署 Kata Containers (可选)

{{% notice warning %}}
Kata Containers 需要 **Metal 实例**（如 c6g.metal），成本较高。本步骤为可选内容，如果预算有限可以跳过。
{{% /notice %}}

### 创建 Metal NodePool

```yaml
cat << 'EOF' | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: kata-graviton-metal
spec:
  template:
    metadata:
      labels:
        type: karpenter
        workload-type: kata
        arch: arm64
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["metal"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: kata-graviton-metal
  limits:
    cpu: 200
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: kata-graviton-metal
spec:
  role: "KarpenterNodeRole-${CLUSTER_NAME}"
  amiSelectorTerms:
    - alias: "al2023@latest"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  userData: |
    #!/bin/bash
    # Install Kata Containers
    dnf install -y kata-containers
    # Register kata-fc RuntimeClass
    kata-runtime kata-env
EOF
```

### 注册 RuntimeClass

```yaml
cat << 'EOF' | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-fc
handler: kata-fc
overhead:
  podFixed:
    cpu: 100m
    memory: 200Mi
scheduling:
  nodeSelector:
    workload-type: kata
EOF
```

### 测试 Kata 隔离

```bash
# 创建一个使用 Kata 运行时的测试 Pod
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: kata-test
  namespace: openclaw-system
spec:
  runtimeClassName: kata-fc
  containers:
    - name: test
      image: busybox
      command: ["uname", "-a"]
  restartPolicy: Never
EOF

# 查看日志 - 应该显示独立的 Guest Kernel
kubectl logs kata-test -n openclaw-system
# 期望: Linux kata-... (独立内核，而非宿主机内核)

# 清理
kubectl delete pod kata-test -n openclaw-system
```

## 在 OpenClaw 中使用 Kata

只需在 OpenClawInstance CRD 中添加一行：

```yaml
apiVersion: openclaw.rocks/v1alpha1
kind: OpenClawInstance
metadata:
  name: secure-agent
spec:
  availability:
    runtimeClassName: kata-fc  # 使用 Kata Firecracker
  envFrom:
    - secretRef:
        name: agent-keys
  resources:
    requests:
      cpu: 200m    # +100m overhead
      memory: 456Mi # +200Mi overhead
```

## 多层安全隔离总结

```
Layer 1: Namespace 隔离（每用户独立 Namespace）
  ↓
Layer 2: NetworkPolicy（默认拒绝，仅允许 ALB 和 DNS）
  ↓
Layer 3: ResourceQuota（CPU/Memory 限额）
  ↓
Layer 4: Pod Security Standard（non-root, read-only rootfs）
  ↓
Layer 5 (可选): Kata Containers（VM 级别隔离）
```

## 下一步

接下来配置多模型提供商支持。
