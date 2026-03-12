# 5分钟快速开始

## TL;DR

```bash
cd eksctl-deployment/scripts

# 1. 清理 CloudFormation (10 min)
./01-cleanup-cloudformation.sh

# 2. 部署 EKS (20 min)
./02-deploy-eks-cluster.sh

# 3. 安装控制器 (10 min)
./03-deploy-controllers.sh

# 4. 验证 (2 min)
./04-verify-deployment.sh

# 5. 创建测试实例
cd ..
kubectl create namespace openclaw
kubectl create secret generic aws-credentials -n openclaw \
  --from-literal=AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
  --from-literal=AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
  --from-literal=AWS_DEFAULT_REGION=us-west-2

kubectl apply -f examples/openclaw-test-instance.yaml
kubectl get openclawinstance test-instance -n openclaw -w
```

## 前提条件

```bash
# macOS
brew install eksctl kubectl awscli helm

# 配置 AWS
aws configure

# SSH 密钥 (可选)
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
```

## 部署目标

- ✅ EKS 1.34 集群 (us-east-1)
- ✅ 3 个节点 (2 standard + 1 kata)
- ✅ EFS 共享存储
- ✅ Kata Containers runtime
- ✅ OpenClaw Operator

## 验证

```bash
# 集群
kubectl cluster-info

# 节点
kubectl get nodes

# Kata 测试
kubectl exec test-instance-0 -n openclaw -c openclaw -- uname -r
# 预期: 6.18.12 (Kata VM kernel)
```

## 故障排查

```bash
# 运行验证脚本
cd scripts
./04-verify-deployment.sh

# 查看日志
kubectl logs -n openclaw test-instance-0 -c openclaw
```

## 清理

```bash
eksctl delete cluster --name openclaw-platform --region us-east-1
```

---
**详细文档**: README.md
