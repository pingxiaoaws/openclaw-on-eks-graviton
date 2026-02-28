# CLAUDE.md - OpenClaw on Kata Containers 部署指南

## 项目概述

本项目实现了在 EKS Graviton (ARM64) 节点上，使用 Kata Containers + Firecracker 运行 OpenClaw instances，提供 VM 级别的隔离和安全性。

**技术栈**:
- **集群**: EKS 1.34 (us-west-2, test-s4)
- **节点**: c6g.metal (ARM64 Graviton, Ubuntu 24.04)
- **Runtime**: Kata Containers 3.27.0 + Firecracker
- **Snapshotter**: devmapper (thin pool on EBS)
- **OpenClaw Operator**: k8s-operator from `/Users/pingxiao/aws-workspace/kata-open-claw/k8s-operator`

## 目录结构

```
/Users/pingxiao/aws-workspace/kata-open-claw/
├── CLAUDE.md                                    # 本文件 - 部署指南
├── KATA-GRAVITON-DEPLOYMENT-SUMMARY.md          # Kata 节点部署总结
├── KATA-QUICK-REFERENCE.md                      # Kata 快速参考
├── kata-graviton-ubuntu-final.yaml              # Kata nodegroup 配置
├── openclaw-kata-bedrock.yaml                   # OpenClaw instance (Kata) 配置
├── k8s-operator/                                # OpenClaw Operator 源码
├── eks-kata-containers/                         # Kata 参考实现
└── kata-containers/                             # Kata 源码
```

## 当前状态

### ✅ 已完成
1. **Kata Graviton 节点**:
   - 节点: `ip-172-31-7-197.us-west-2.compute.internal`
   - 状态: Ready
   - RuntimeClass: `kata-fc`
   - 测试 Pod 验证通过

2. **OpenClaw Operator**:
   - Namespace: `openclaw-operator-system`
   - Deployment: `openclaw-operator`
   - CRD: `openclawinstances.openclaw.rocks`

3. **现有 OpenClaw Instance**:
   - Name: `my-openclaw-bedrock`
   - Namespace: `openclaw`
   - Runtime: runc (标准容器)
   - 状态: Running

### ⏳ 待完成
- 在 Kata Container 中运行 OpenClaw instance
- 验证 Bedrock API 访问
- 性能测试和优化

## 部署计划

### Phase 1: 环境验证

#### 1.1 检查 Kata 环境

```bash
# 检查 Kata 节点
kubectl get nodes -l workload-type=kata -o wide

# 预期输出:
# NAME                                         STATUS   VERSION
# ip-172-31-7-197.us-west-2.compute.internal   Ready    v1.34.3

# 检查 RuntimeClass
kubectl get runtimeclass kata-fc

# 预期输出:
# NAME      HANDLER   AGE
# kata-fc   kata-fc   XXh

# 验证测试 Pod
kubectl get pod test-kata-firecracker -o wide
kubectl exec test-kata-firecracker -- uname -a
# 预期: Linux test-kata-firecracker 6.18.12 (Kata VM kernel)
```

#### 1.2 检查 OpenClaw Operator

```bash
# 检查 operator 状态
kubectl get deployment -n openclaw-operator-system openclaw-operator

# 检查 operator 版本和镜像
kubectl get deployment openclaw-operator -n openclaw-operator-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# 检查 CRD
kubectl get crd openclawinstances.openclaw.rocks

# 验证 runtimeClassName 字段支持
kubectl get crd openclawinstances.openclaw.rocks -o json | \
  jq '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.availability.properties.runtimeClassName'
```

### Phase 2: Operator 验证和更新

#### 2.1 验证代码实现

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/k8s-operator

# 检查 runtimeClassName 实现
grep -n "RuntimeClassName" internal/resources/statefulset.go

# 预期输出:
# 94:					RuntimeClassName:              instance.Spec.Availability.RuntimeClassName,

# 检查 API 定义
grep -n "RuntimeClassName" api/v1alpha1/openclawinstance_types.go
```

#### 2.2 更新 CRD（如果需要）

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/k8s-operator

# 重新生成 CRD
make manifests

# 应用更新的 CRD
kubectl apply -f config/crd/bases/openclaw.rocks_openclawinstances.yaml

# 验证 CRD 更新
kubectl get crd openclawinstances.openclaw.rocks -o yaml | grep storedVersions
```

#### 2.3 重新部署 Operator（如果需要）

**选项 A: 使用 Helm**

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/k8s-operator

# 升级 operator
helm upgrade --install openclaw-operator charts/openclaw-operator \
  --namespace openclaw-operator-system \
  --create-namespace

# 等待 operator 就绪
kubectl wait --for=condition=ready pod \
  -n openclaw-operator-system \
  -l app.kubernetes.io/name=openclaw-operator \
  --timeout=60s
```

**选项 B: 使用 kustomize**

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/k8s-operator

# 部署 operator
make deploy

# 验证部署
kubectl get deployment -n openclaw-operator-system
```

**选项 C: 本地运行（调试用）**

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/k8s-operator

# 安装 CRD
make install

# 本地运行 operator（连接到集群）
make run

# 在另一个终端中应用 OpenClawInstance
```

### Phase 3: 创建 Kata OpenClaw Instance

#### 3.1 配置文件说明

配置文件: `/Users/pingxiao/aws-workspace/kata-open-claw/openclaw-kata-bedrock.yaml`

**关键配置**:

```yaml
apiVersion: openclaw.rocks/v1alpha1
kind: OpenClawInstance
metadata:
  name: openclaw-kata-bedrock
  namespace: openclaw
spec:
  # Bedrock 配置
  config:
    raw:
      agents:
        defaults:
          model:
            primary: "bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0"

  # AWS credentials for Bedrock
  envFrom:
    - secretRef:
        name: aws-credentials

  # 资源配置 - 为 Kata VM 开销增加
  resources:
    requests:
      cpu: "600m"      # +100m for VM overhead
      memory: "1.2Gi"  # +200Mi for VM overhead
    limits:
      cpu: "2"
      memory: "4Gi"

  # Kata 调度配置 - 关键部分
  availability:
    runtimeClassName: kata-fc        # 使用 Kata Firecracker
    nodeSelector:
      workload-type: kata            # 调度到 Kata 节点
    tolerations:
      - key: kata-dedicated
        operator: Exists
        effect: NoSchedule

  # 存储
  storage:
    persistence:
      enabled: true
      size: 10Gi
      storageClass: gp3

  # 网络
  networking:
    service:
      type: ClusterIP

  # 安全配置
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
    networkPolicy:
      enabled: true
      allowDNS: true
    rbac:
      createServiceAccount: true

  # 监控
  observability:
    metrics:
      enabled: true
      port: 9090
    logging:
      level: info
      format: json
```

#### 3.2 部署步骤

```bash
# 应用配置
kubectl apply -f /Users/pingxiao/aws-workspace/kata-open-claw/openclaw-kata-bedrock.yaml

# 监控创建进度
kubectl get openclawinstance openclaw-kata-bedrock -n openclaw -w

# 预期输出:
# NAME                    PHASE     READY   GATEWAY                                    AGE
# openclaw-kata-bedrock   Running   True    openclaw-kata-bedrock.openclaw.svc:18789   1m
```

#### 3.3 验证部署

```bash
# 1. 检查 OpenClawInstance 状态
kubectl get openclawinstance openclaw-kata-bedrock -n openclaw
kubectl describe openclawinstance openclaw-kata-bedrock -n openclaw

# 2. 检查 StatefulSet
kubectl get statefulset openclaw-kata-bedrock -n openclaw

# 3. 检查 Pod
kubectl get pod -n openclaw -l app.kubernetes.io/instance=openclaw-kata-bedrock -o wide

# 4. 验证 runtimeClassName (关键验证)
kubectl get pod openclaw-kata-bedrock-0 -n openclaw -o jsonpath='{.spec.runtimeClassName}'
# 预期输出: kata-fc

# 5. 验证 Pod 在 Kata 节点上
kubectl get pod openclaw-kata-bedrock-0 -n openclaw -o jsonpath='{.spec.nodeName}'
# 预期输出: ip-172-31-7-197.us-west-2.compute.internal

# 6. 验证 VM 内核 (最重要!)
kubectl exec -n openclaw openclaw-kata-bedrock-0 -c openclaw -- uname -a
# 预期输出: Linux openclaw-kata-bedrock-0 6.18.12 ... aarch64 Linux
# 注意: 6.18.x 是 Kata VM 内核，不是宿主机的 6.17.x
```

### Phase 4: 功能测试

#### 4.1 测试 Bedrock API 访问

```bash
# 获取 gateway endpoint
GATEWAY_ENDPOINT=$(kubectl get openclawinstance openclaw-kata-bedrock -n openclaw -o jsonpath='{.status.gatewayEndpoint}')

# 获取 gateway token
GATEWAY_TOKEN=$(kubectl get secret openclaw-kata-bedrock-gateway-token -n openclaw -o jsonpath='{.data.token}' | base64 -d)

# 测试连接 (从集群内部)
kubectl run -it --rm test-openclaw --image=curlimages/curl:latest --restart=Never -- \
  curl -H "Authorization: Bearer $GATEWAY_TOKEN" \
  http://$GATEWAY_ENDPOINT/health

# 测试 Bedrock 调用
kubectl run -it --rm test-openclaw --image=curlimages/curl:latest --restart=Never -- \
  curl -X POST -H "Authorization: Bearer $GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0","messages":[{"role":"user","content":"Hello"}]}' \
  http://$GATEWAY_ENDPOINT/v1/messages
```

#### 4.2 性能对比测试

```bash
# 对比标准容器 vs Kata Container 性能
# 标准容器 instance
kubectl exec -n openclaw my-openclaw-bedrock-0 -c openclaw -- uname -a

# Kata instance
kubectl exec -n openclaw openclaw-kata-bedrock-0 -c openclaw -- uname -a

# 对比启动时间、内存使用、响应延迟等
```

### Phase 5: 故障排查

#### 5.1 runtimeClassName 未生效

**症状**: Pod 的 `.spec.runtimeClassName` 为空

**诊断步骤**:

```bash
# 1. 检查 OpenClawInstance 配置
kubectl get openclawinstance openclaw-kata-bedrock -n openclaw -o yaml | grep -A 5 "availability:"

# 2. 检查 StatefulSet 配置
kubectl get statefulset openclaw-kata-bedrock -n openclaw -o yaml | grep -A 5 "runtimeClassName:"

# 3. 检查 operator 日志
kubectl logs -n openclaw-operator-system deployment/openclaw-operator --tail=100 | grep openclaw-kata-bedrock

# 4. 检查 operator 版本
kubectl get deployment openclaw-operator -n openclaw-operator-system -o jsonpath='{.spec.template.spec.containers[0].image}'
```

**解决方案**:

**方案 A: Operator 版本过旧**
```bash
# 重新部署最新 operator
cd /Users/pingxiao/aws-workspace/kata-open-claw/k8s-operator
helm upgrade --install openclaw-operator charts/openclaw-operator \
  --namespace openclaw-operator-system

# 删除并重新创建 instance
kubectl delete openclawinstance openclaw-kata-bedrock -n openclaw
kubectl apply -f /Users/pingxiao/aws-workspace/kata-open-claw/openclaw-kata-bedrock.yaml
```

**方案 B: 临时手动修复**
```bash
# 直接修改 StatefulSet
kubectl patch statefulset openclaw-kata-bedrock -n openclaw \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/runtimeClassName", "value": "kata-fc"}]'

# 删除 Pod 触发重建
kubectl delete pod openclaw-kata-bedrock-0 -n openclaw
```

#### 5.2 Pod 无法调度

**症状**: Pod 处于 Pending 状态

```bash
# 检查事件
kubectl describe pod openclaw-kata-bedrock-0 -n openclaw

# 常见原因:
# 1. 节点资源不足
kubectl describe node ip-172-31-7-197.us-west-2.compute.internal

# 2. Taint 配置错误
kubectl get node ip-172-31-7-197.us-west-2.compute.internal -o yaml | grep -A 5 taints

# 3. NodeSelector 不匹配
kubectl get node ip-172-31-7-197.us-west-2.compute.internal --show-labels | grep workload-type
```

#### 5.3 Pod 启动失败

**症状**: Pod CrashLoopBackOff 或 Error

```bash
# 查看容器日志
kubectl logs -n openclaw openclaw-kata-bedrock-0 -c openclaw --tail=100

# 查看 Pod 事件
kubectl describe pod openclaw-kata-bedrock-0 -n openclaw

# 检查 Kata runtime 日志（在节点上）
kubectl debug node/ip-172-31-7-197.us-west-2.compute.internal -it --image=ubuntu -- \
  chroot /host journalctl -u containerd | grep kata-fc
```

#### 5.4 Bedrock API 访问失败

**症状**: OpenClaw 无法连接 Bedrock

```bash
# 检查 AWS credentials secret
kubectl get secret aws-credentials -n openclaw -o yaml

# 测试 Pod 内部网络
kubectl exec -n openclaw openclaw-kata-bedrock-0 -c openclaw -- \
  curl -I https://bedrock-runtime.us-west-2.amazonaws.com

# 检查 NetworkPolicy
kubectl get networkpolicy -n openclaw
kubectl describe networkpolicy openclaw-kata-bedrock -n openclaw
```

## 运维指南

### 日常操作

#### 查看 OpenClaw Instances

```bash
# 列出所有 instances
kubectl get openclawinstances -A

# 查看详细信息
kubectl describe openclawinstance openclaw-kata-bedrock -n openclaw

# 查看日志
kubectl logs -n openclaw openclaw-kata-bedrock-0 -c openclaw -f
```

#### 扩容/缩容

```bash
# OpenClaw 使用 StatefulSet，默认单副本
# 如需扩容，修改 instance 配置（注意：需要支持多副本的配置）
kubectl edit openclawinstance openclaw-kata-bedrock -n openclaw
```

#### 更新配置

```bash
# 修改配置文件
vim /Users/pingxiao/aws-workspace/kata-open-claw/openclaw-kata-bedrock.yaml

# 应用更新
kubectl apply -f /Users/pingxiao/aws-workspace/kata-open-claw/openclaw-kata-bedrock.yaml

# OpenClaw operator 会自动触发滚动更新
```

#### 备份和恢复

```bash
# 备份 OpenClawInstance 配置
kubectl get openclawinstance openclaw-kata-bedrock -n openclaw -o yaml > openclaw-kata-backup.yaml

# 备份持久化数据 (PVC)
kubectl get pvc -n openclaw
# 使用 Volume Snapshot 或其他备份方案
```

### 监控和告警

#### 关键指标

```bash
# Pod 资源使用
kubectl top pod -n openclaw -l app.kubernetes.io/instance=openclaw-kata-bedrock

# 节点资源使用
kubectl top node ip-172-31-7-197.us-west-2.compute.internal

# Kata VM 开销
# 对比 runc vs kata-fc 的资源使用
```

#### Prometheus 监控

```bash
# OpenClaw 暴露 metrics 端口 9090
kubectl port-forward -n openclaw openclaw-kata-bedrock-0 9090:9090

# 访问 metrics
curl http://localhost:9090/metrics
```

### 清理

#### 删除 OpenClaw Instance

```bash
# 删除 instance（保留 PVC）
kubectl delete openclawinstance openclaw-kata-bedrock -n openclaw

# 删除 PVC
kubectl delete pvc openclaw-kata-bedrock-data -n openclaw
```

#### 删除 Kata 节点

```bash
# 删除 nodegroup
eksctl delete nodegroup --cluster=test-s4 \
  --name=kata-graviton-metal \
  --region=us-west-2 \
  --drain=true
```

## 参考资料

### 文档

- [Kata Containers 官方文档](https://katacontainers.io/)
- [OpenClaw Operator README](/Users/pingxiao/aws-workspace/kata-open-claw/k8s-operator/README.md)
- [OpenClaw API Reference](/Users/pingxiao/aws-workspace/kata-open-claw/k8s-operator/docs/api-reference.md)
- [Kata 部署总结](./KATA-GRAVITON-DEPLOYMENT-SUMMARY.md)
- [Kata 快速参考](./KATA-QUICK-REFERENCE.md)

### 配置文件

- `kata-graviton-ubuntu-final.yaml` - Kata nodegroup 配置
- `openclaw-kata-bedrock.yaml` - OpenClaw instance 配置
- `k8s-operator/config/samples/` - 更多示例配置

### 命令速查

```bash
# 环境验证
kubectl get nodes -l workload-type=kata
kubectl get runtimeclass kata-fc
kubectl get openclawinstances -A

# 部署
kubectl apply -f openclaw-kata-bedrock.yaml
kubectl get openclawinstance openclaw-kata-bedrock -n openclaw -w

# 验证
kubectl get pod -n openclaw -l app.kubernetes.io/instance=openclaw-kata-bedrock -o wide
kubectl exec -n openclaw openclaw-kata-bedrock-0 -- uname -a

# 日志
kubectl logs -n openclaw openclaw-kata-bedrock-0 -c openclaw -f
kubectl logs -n openclaw-operator-system deployment/openclaw-operator -f

# 清理
kubectl delete openclawinstance openclaw-kata-bedrock -n openclaw
```

## 下一步

1. [ ] 验证当前 operator 版本是否支持 runtimeClassName
2. [ ] 更新/重新部署 operator（如果需要）
3. [ ] 创建 Kata OpenClaw instance
4. [ ] 验证 Bedrock API 访问
5. [ ] 性能测试和对比
6. [ ] 生产环境部署计划

---

**最后更新**: 2026-02-28
**维护者**: Claude Code
