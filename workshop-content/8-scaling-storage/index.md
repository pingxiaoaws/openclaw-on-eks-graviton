---
title: "弹性扩展与存储"
weight: 90
---

# Karpenter 弹性扩展与存储方案

## Karpenter 自动伸缩

### 工作原理

```
新的 OpenClaw Pod (Pending)
  ↓ Karpenter 检测到 Unschedulable
  ↓
选择最优实例类型 (t4g.medium / c6g.large / m6g.xlarge)
  ↓ 优先 Spot，回退 On-Demand
  ↓
调用 EC2 Fleet API → 启动新节点 (<2 分钟)
  ↓
Pod 调度到新节点 → Running
```

### 观察 Karpenter 行为

```bash
# 创建多个测试实例，触发 Karpenter 扩容
for i in $(seq 1 5); do
  cat << EOF | kubectl apply -f -
apiVersion: openclaw.rocks/v1alpha1
kind: OpenClawInstance
metadata:
  name: scale-test-${i}
  namespace: openclaw-system
spec:
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
EOF
done

# 观察 Karpenter 日志
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f --tail=20
# 期望看到: "launched nodeclaim" / "registered nodeclaim"

# 观察节点变化
kubectl get nodes -w
```

### Karpenter 整合 (Consolidation)

```bash
# 删除测试实例
for i in $(seq 1 5); do
  kubectl delete openclawinstance scale-test-${i} -n openclaw-system
done

# 等待 30 分钟后观察（consolidateAfter: 30m）
# Karpenter 会自动回收空闲节点

# 查看 Karpenter 节点状态
kubectl get nodeclaims
kubectl get nodepools
```

## 存储方案

### 方案一：Amazon EBS (gp3) — 默认

每个用户独立 PVC，数据隔离性最好：

```yaml
# StorageClass（通常 EKS 已内置）
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
```

OpenClaw Operator 默认使用 EBS：
```yaml
spec:
  storage:
    persistence:
      enabled: true
      size: 10Gi
      storageClassName: gp3
```

### 方案二：Amazon EFS — 跨 AZ 共享

```bash
# 创建 EFS 文件系统
EFS_ID=$(aws efs create-file-system \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --encrypted \
  --tags Key=Name,Value=openclaw-workshop \
  --query 'FileSystemId' --output text)

echo "EFS ID: $EFS_ID"

# 为每个子网创建 Mount Target
for SUBNET_ID in $(aws ec2 describe-subnets \
  --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
  --query 'Subnets[].SubnetId' --output text); do
  aws efs create-mount-target \
    --file-system-id $EFS_ID \
    --subnet-id $SUBNET_ID
done
```

```yaml
# EFS StorageClass
cat << EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: "${EFS_ID}"
  directoryPerms: "700"
  uid: "1000"
  gid: "1000"
  basePath: "/openclaw"
mountOptions:
  - tls
EOF
```

### 存储方案对比

| 维度 | EBS (gp3) | EFS |
|------|-----------|-----|
| **访问模式** | ReadWriteOnce | ReadWriteMany |
| **跨 AZ** | ❌ 同 AZ | ✅ 多 AZ |
| **性能** | 高 IOPS (3000) | 中等 |
| **价格** | $0.08/GB/月 | $0.30/GB/月 |
| **适用场景** | 单 Pod 独占 | 跨 Pod 共享 |
| **推荐** | ✅ 默认选择 | 需要跨 AZ 时 |

## 下一步

基础设施全部就绪，进入 Demo 演示环节！
