# 🚀 Getting Started - OpenClaw Platform eksctl 部署

**从现在开始，30 分钟后拥有一个运行中的 OpenClaw 平台**

---

## ⚡ 一键部署 (复制粘贴)

```bash
# 克隆项目 (如果还没有)
cd /path/to/kata-open-claw

# 进入部署目录
cd eksctl-deployment/scripts

# === Step 1: 清理旧资源 (10 分钟) ===
./01-cleanup-cloudformation.sh
# 提示确认时输入: yes
# 等待删除完成

# === Step 2: 部署 EKS (20 分钟) ===
./02-deploy-eks-cluster.sh
# 提示确认时输入: yes
# 喝杯咖啡 ☕

# === Step 3: 安装控制器 (10 分钟) ===
./03-deploy-controllers.sh
# 自动执行，无需输入

# === Step 4: 验证 (2 分钟) ===
./04-verify-deployment.sh
# 检查输出: "✅ All checks passed!"

# === Step 5: 创建测试实例 (3 分钟) ===
cd ..
kubectl create namespace openclaw
kubectl create secret generic aws-credentials -n openclaw \
  --from-literal=AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
  --from-literal=AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
  --from-literal=AWS_DEFAULT_REGION=us-west-2

kubectl apply -f examples/openclaw-test-instance.yaml
kubectl get openclawinstance test-instance -n openclaw -w
# 等待 PHASE=Running, READY=True

# === Step 6: 测试 (本地) ===
kubectl port-forward -n openclaw svc/test-instance 18789:18789 &
curl http://localhost:18789/health
# 预期: {"status": "healthy"}
```

**总时间**: 45 分钟 (含清理)

---

## 📋 前提条件

### 必需工具

```bash
# macOS 快速安装
brew install eksctl kubectl awscli helm

# Linux
# 参考: https://eksctl.io/installation/
```

### AWS 凭证

```bash
# 配置凭证
aws configure

# 验证
aws sts get-caller-identity
```

### SSH 密钥 (可选)

```bash
# 生成 (如果没有)
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
```

---

## 🎯 部署目标

部署完成后，你将拥有:

- ✅ EKS 1.34 集群 (us-east-1)
- ✅ 3 个节点 (2 标准 + 1 Kata)
- ✅ EFS 共享存储 (encrypted, elastic)
- ✅ Kata Containers runtime (kata-fc + kata-qemu)
- ✅ OpenClaw Operator
- ✅ 一个运行中的 OpenClaw 实例 (Bedrock API)

---

## ❓ 常见问题

### Q1: 我需要删除旧的 CloudFormation 吗?

**A**: 如果你之前尝试过 CloudFormation 部署，必须先删除:

```bash
cd eksctl-deployment/scripts
./01-cleanup-cloudformation.sh
```

如果没有旧资源，跳过此步骤。

### Q2: 部署需要多长时间?

**A**:
- 清理旧资源: 10-20 分钟 (首次)
- EKS 集群: 20-25 分钟
- 控制器: 10-15 分钟
- 验证: 2-3 分钟
- **总计**: 35-45 分钟 (含清理)

### Q3: 我需要修改配置吗?

**A**: 默认配置适合大多数场景，但你可以修改:

```bash
vim configs/openclaw-cluster.yaml

# 常见修改:
# - metadata.region: 部署区域
# - managedNodeGroups.desiredCapacity: 节点数量
# - nodeGroups.instanceType: Kata 节点类型
```

### Q4: 部署失败怎么办?

**A**: 运行验证脚本查看具体错误:

```bash
cd scripts
./04-verify-deployment.sh
```

查看 `README.md` 的故障排查章节。

### Q5: 如何清理所有资源?

**A**: 删除集群会自动清理所有资源:

```bash
eksctl delete cluster --name openclaw-platform --region us-east-1
```

---

## 📚 更多资源

| 文档 | 用途 |
|------|------|
| [QUICKSTART.md](./QUICKSTART.md) | 5 分钟快速开始 |
| [README.md](./README.md) | 完整部署指南 |
| [COMPARISON.md](./COMPARISON.md) | CloudFormation vs eksctl 对比 |
| [PROJECT-STRUCTURE.md](./PROJECT-STRUCTURE.md) | 项目结构说明 |

---

## 🆘 获取帮助

- **故障排查**: 查看 `README.md` 故障排查章节
- **错误诊断**: 运行 `./04-verify-deployment.sh`
- **日志查看**: `kubectl logs -n <namespace> <pod>`

---

**准备好了吗? 开始部署吧!** 🚀

```bash
cd eksctl-deployment/scripts
./01-cleanup-cloudformation.sh
```
