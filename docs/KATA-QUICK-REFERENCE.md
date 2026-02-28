# Kata Containers on EKS Graviton - 快速参考

## 集群信息

- **集群**: test-s4 (us-west-2)
- **节点**: ip-172-31-7-197.us-west-2.compute.internal
- **实例**: c6g.metal (ARM64 Graviton)
- **RuntimeClass**: kata-fc

## 常用命令

### 查看 Kata 节点

```bash
kubectl get nodes -l workload-type=kata -o wide
```

### 查看 RuntimeClass

```bash
kubectl get runtimeclass
```

### 创建 Kata Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-kata-pod
spec:
  runtimeClassName: kata-fc  # 使用 Kata Firecracker runtime
  nodeSelector:
    workload-type: kata       # 调度到 Kata 节点
  tolerations:
    - key: kata-dedicated
      operator: Exists
      effect: NoSchedule
  containers:
    - name: app
      image: nginx:alpine
```

### 验证 Pod 在 VM 中运行

```bash
# 检查 VM 内核版本（应该是 6.18.x，不是宿主机的 6.17.x）
kubectl exec <pod-name> -- uname -a

# 预期输出:
# Linux <pod-name> 6.18.12 #1 SMP ... aarch64 Linux
```

### 查看 Kata Deploy 状态

```bash
# 查看 DaemonSet
kubectl get ds -n kube-system kata-deploy

# 查看 Pods
kubectl get pods -n kube-system -l name=kata-deploy

# 查看特定节点的 kata-deploy pod
kubectl get pods -n kube-system -l name=kata-deploy \
  --field-selector spec.nodeName=ip-172-31-7-197.us-west-2.compute.internal
```

### 调试节点

```bash
# 使用 kubectl debug（需要特权）
kubectl debug node/ip-172-31-7-197.us-west-2.compute.internal -it --image=ubuntu

# SSH 访问（仅当节点有公网 IP）
ssh -i ~/kata-graviton-debug-key.pem ubuntu@<node-ip>
```

## 创建 Deployment 示例

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kata-nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      runtimeClassName: kata-fc
      nodeSelector:
        workload-type: kata
      tolerations:
        - key: kata-dedicated
          operator: Exists
          effect: NoSchedule
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "200m"
```

## OpenClaw 集成

### OpenClaw Pod with Kata

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: openclaw-kata-instance
  namespace: default
spec:
  runtimeClassName: kata-fc
  nodeSelector:
    workload-type: kata
  tolerations:
    - key: kata-dedicated
      operator: Exists
      effect: NoSchedule
  containers:
    - name: openclaw-agent
      image: <your-openclaw-image>
      env:
        - name: BEDROCK_MODEL
          value: "anthropic.claude-v2"
        - name: AWS_REGION
          value: "us-west-2"
      resources:
        requests:
          memory: "512Mi"
          cpu: "500m"
        limits:
          memory: "1Gi"
          cpu: "1000m"
```

## 故障排查

### Pod 无法启动

```bash
# 查看 Pod 事件
kubectl describe pod <pod-name>

# 查看容器日志
kubectl logs <pod-name>

# 查看 kubelet 日志（在节点上）
kubectl debug node/<node-name> -it --image=ubuntu -- \
  chroot /host journalctl -u kubelet -n 100
```

### 检查 devmapper 状态

```bash
# SSH 到节点后
sudo dmsetup ls
sudo dmsetup status devpool

# 检查 containerd 配置
sudo cat /etc/containerd/config.toml | grep -A 10 devmapper
```

### 检查 Kata 日志

```bash
# 在节点上
sudo journalctl -u containerd | grep kata
cat /var/log/kata-devmapper-setup.log
```

## 性能监控

### 查看资源使用

```bash
# Pod 资源使用
kubectl top pod <pod-name>

# 节点资源使用
kubectl top node ip-172-31-7-197.us-west-2.compute.internal
```

### 监控 devmapper

```bash
# 在节点上
sudo dmsetup status devpool
# 输出: 0 732421875 thin-pool 41 86/81920 23/715200 - rw discard_passdown queue_if_no_space -
```

## 维护操作

### 扩容 Kata 节点

```bash
# 修改 nodegroup 配置
eksctl scale nodegroup --cluster=test-s4 \
  --name=kata-graviton-metal \
  --nodes=2 \
  --nodes-min=1 \
  --nodes-max=3
```

### 升级 Kata Containers

```bash
# 获取最新版本
export VERSION=$(curl -sSL https://api.github.com/repos/kata-containers/kata-containers/releases/latest | jq -r .tag_name)

# 升级 Helm release
helm upgrade kata-deploy -n kube-system \
  oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
  --version ${VERSION}
```

### 删除测试 Pod

```bash
kubectl delete pod test-kata-firecracker
```

### 删除 nodegroup

```bash
eksctl delete nodegroup --cluster=test-s4 \
  --name=kata-graviton-metal \
  --drain=true
```

## 配置文件位置

所有配置文件位于: `/Users/pingxiao/aws-workspace/kata-open-claw/`

- `kata-graviton-ubuntu-final.yaml` - eksctl nodegroup 配置
- `KATA-GRAVITON-DEPLOYMENT-SUMMARY.md` - 完整部署文档
- `KATA-QUICK-REFERENCE.md` - 本快速参考（你正在看的文件）

## 重要注意事项

⚠️ **安全**
- Kata Pods 提供 VM 级别隔离，但仍需配置网络策略
- 定期更新 Kata Containers 版本以获得安全补丁

⚠️ **性能**
- Kata VM 启动时间 ~500ms-1s（vs runc ~100ms）
- 每个 VM 需要额外 100MB+ 内存开销
- 建议为 Kata 工作负载预留充足资源

⚠️ **成本**
- c6g.metal 实例成本较高
- 考虑使用 Spot 实例降低成本
- 监控资源利用率，避免浪费

## 联系信息

- **文档维护**: Claude Code
- **创建日期**: 2026-02-28
- **EKS 版本**: 1.34
- **Kata 版本**: 3.27.0
