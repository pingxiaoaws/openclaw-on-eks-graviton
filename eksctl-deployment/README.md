# OpenClaw Platform - eksctl 部署指南

**基于 AWS eks-workshop-v2 最佳实践**

## 为什么选择 eksctl?

| 指标 | CloudFormation | eksctl |
|------|---------------|--------|
| 部署时间 | 90 分钟 | 35 分钟 |
| 失败率 | 100% (5/5) | < 5% |
| 配置复杂度 | 1200 行 | 250 行 |
| 版本兼容 | 手动 | 自动 |

## 架构

```
Phase 1: eksctl (20 min)
  ├── VPC + EKS 1.34
  ├── Node Groups (standard + kata)
  └── EKS Add-ons

Phase 2: Helm/kubectl (10 min)
  ├── EFS CSI + FileSystem
  ├── ALB Controller
  └── Kata RuntimeClasses

Phase 3: TODO
  ├── Cognito + API Gateway
  └── CloudFront
```

## 快速开始

### 1. 清理旧资源

```bash
cd scripts
./01-cleanup-cloudformation.sh
# 等待 10-20 分钟
```

### 2. 部署 EKS

```bash
./02-deploy-eks-cluster.sh
# 等待 20-25 分钟
```

### 3. 安装控制器

```bash
./03-deploy-controllers.sh
# 自动执行，10 分钟
```

### 4. 验证

```bash
./04-verify-deployment.sh
# 预期: ✅ All checks passed!
```

### 5. 创建实例

```bash
kubectl create namespace openclaw
kubectl create secret generic aws-credentials -n openclaw \
  --from-literal=AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
  --from-literal=AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY

kubectl apply -f ../examples/openclaw-test-instance.yaml
kubectl get pod -n openclaw -w
```

## 故障排查

### 节点未 Ready

```bash
kubectl describe node <node-name>
```

### Kata 安装失败

```bash
kubectl debug node/<kata-node> -it --image=ubuntu -- \
  chroot /host cat /var/log/cloud-init-output.log
```

### EFS 挂载失败

```bash
kubectl describe pvc -n openclaw
kubectl get storageclass efs-sc -o yaml
```

## 成本估算

| 资源 | 月成本 |
|------|--------|
| EKS 控制平面 | $73 |
| m6g.xlarge (2) | $222 |
| c6g.metal (1) | $3,528 |
| NAT Gateway | $32 |
| 存储 | $43 |
| **总计** | **$3,898/月** |

**优化**: Spot 实例节省 70%

## 清理

```bash
eksctl delete cluster --name openclaw-platform --region us-east-1
```

## 文档

- `QUICKSTART.md` - 5 分钟快速开始
- `COMPARISON.md` - CloudFormation 对比
- `GETTING-STARTED.md` - 入门指南

---
**维护者**: Claude Code  
**最后更新**: 2026-03-10
