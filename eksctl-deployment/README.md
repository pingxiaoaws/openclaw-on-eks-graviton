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
Phase 1: EKS 集群部署 (20-35 min)
  ├── VPC + EKS 1.34
  ├── Node Groups (standard + kata optional)
  └── EKS Add-ons (vpc-cni, coredns, kube-proxy, ebs-csi)

Phase 2: 基础设施控制器 (10 min)
  ├── EFS CSI Driver + FileSystem
  ├── AWS Load Balancer Controller
  ├── EKS Pod Identity
  └── Kata Containers (if kata nodes exist)

Phase 3: 验证部署 (1 min)
  └── 验证所有组件状态

Phase 4: 应用栈部署 (20-30 min)
  ├── OpenClaw Operator
  ├── Bedrock IAM Role & Pod Identity
  ├── Cognito User Pool & Client
  ├── Provisioning Service Docker 镜像构建
  ├── Provisioning Service 部署
  ├── Internet-facing ALB
  └── CloudFront Distribution
```

## 快速开始

### 先决条件

- AWS CLI v2
- eksctl >= 0.150.0
- kubectl >= 1.28
- helm >= 3.0
- Docker (如果本地构建镜像)

### 1. 部署 EKS 集群

**选择部署模式**:

- **标准集群**: 仅标准节点 (m6g Graviton ARM64), 成本较低
- **Kata 集群**: 标准节点 + Kata 节点 (m5.metal), VM 级别隔离

```bash
cd scripts

# 交互式选择部署模式
./01-deploy-eks-cluster.sh

# 选择 1: 标准集群 (20-25 分钟)
# 选择 2: Kata 集群 (30-35 分钟)
```

**注意**: Kata 部署需要:
- SSH 密钥对 `openclaw-kata-key` (或修改配置)
- Bare metal 实例 (m5.metal) - 成本较高

### 2. 安装基础设施控制器

```bash
./02-deploy-controllers.sh
# 自动执行以下操作:
# - EFS CSI Driver 安装
# - EFS FileSystem 创建 (encrypted, elastic)
# - StorageClass efs-sc 配置
# - ALB Controller 安装
# - EKS Pod Identity 安装
# - Kata Containers 安装 (如果有 Kata 节点)
#
# 时间: 10-15 分钟
```

### 3. 验证部署

```bash
./03-verify-deployment.sh
# 预期输出:
# ✅ All checks passed!
#
# 验证项目:
# - Node Groups: Standard ✅, Kata ✅ (if applicable)
# - EFS CSI Driver ✅
# - EFS FileSystem ✅
# - StorageClass efs-sc ✅
# - ALB Controller ✅
# - Pod Identity ✅
# - Kata DaemonSet ✅ (if applicable)
# - RuntimeClass kata-fc ✅ (if applicable)
```

### 4. 部署应用栈 (Provisioning Service + Cognito + CloudFront)

**统一部署脚本** - 一次性部署所有应用组件:

```bash
./04-deploy-application-stack.sh
#
# 自动执行:
# [1/9] OpenClaw Operator
# [2/9] Bedrock IAM Policy & Role
# [3/9] Pod Identity Association
# [4/9] Cognito User Pool & Client
# [5/9] Docker 镜像构建 (支持本地/远程构建)
# [6/9] Provisioning Service 部署 (with Cognito config)
# [7/9] 转换 ALB 为 Internet-facing
# [8/9] CloudFront Distribution 创建
# [9/9] 更新 Provisioning Service (with CloudFront config)
#
# 时间: 20-30 分钟 (CloudFront 部署占 10-15 分钟)
```

**输出**:

```
🎯 Deployed Components:
  ✅ OpenClaw Operator
  ✅ Bedrock IAM Role: arn:aws:iam::111122223333:role/OpenClawBedrockRole
  ✅ Cognito User Pool: us-west-2_ExAmPlE
  ✅ Cognito Client: xxxxxxxxxxxxxxxxxxxxxxxxxx
  ✅ Internet-facing ALB: internal-*.elb.amazonaws.com
  ✅ CloudFront Distribution: d1234567890abc
  ✅ CloudFront Domain: d1234567890abc.cloudfront.net

🌐 Access URLs:
  - Public URL: https://d1234567890abc.cloudfront.net
  - Login: https://d1234567890abc.cloudfront.net/login
  - Dashboard: https://d1234567890abc.cloudfront.net/dashboard

👤 Create Test User:
  aws cognito-idp admin-create-user \
    --user-pool-id us-west-2_ExAmPlE \
    --username test@example.com \
    --temporary-password 'TempPass123!' \
    --region us-west-2
```

### 5. 创建测试用户并访问

```bash
# 创建 Cognito 用户
aws cognito-idp admin-create-user \
  --user-pool-id <USER_POOL_ID> \
  --username test@example.com \
  --temporary-password 'TempPass123!' \
  --region <AWS_REGION>

# 访问登录页面
open https://<CLOUDFRONT_DOMAIN>/login

# 登录后系统会提示修改临时密码
```

### 6. 创建 OpenClaw Instance

通过 Dashboard UI 创建实例，或使用 kubectl:

```bash
kubectl create namespace openclaw

# 如果使用 AWS credentials (非 Pod Identity)
kubectl create secret generic aws-credentials -n openclaw \
  --from-literal=AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
  --from-literal=AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY

kubectl apply -f ../examples/openclaw-test-instance.yaml
kubectl get pod -n openclaw -w
```

## 部署模式对比

### 标准模式 (无 Kata)

**适用场景**:
- 开发/测试环境
- 单租户或可信环境
- 成本敏感

**配置**:
- Node Group: m6g.xlarge/2xlarge (ARM64 Graviton)
- OS: Amazon Linux 2023
- Runtime: containerd (runc)
- 成本: ~$300/月 (2 节点)

### Kata 模式 (VM 隔离)

**适用场景**:
- 生产多租户环境
- AI Agent 平台
- 安全隔离要求高

**配置**:
- Standard Nodes: m6g.xlarge/2xlarge (系统工作负载)
- Kata Nodes: m5.metal (Ubuntu 24.04, Kata Containers)
- Runtime: Kata Firecracker (kata-fc) 或 QEMU (kata-qemu)
- 成本: ~$3,900/月 (2 标准 + 1 bare metal)

**Kata Runtime 选择**:
- `kata-fc` (Firecracker): 快速启动 (~125ms), 轻量级, **不支持 EFS 写入持久化**
- `kata-qemu` (QEMU): 启动稍慢 (~500ms), 完整 virtiofs 支持, **支持 EFS 读写**

## 脚本说明

| 脚本 | 说明 | 时间 |
|------|------|------|
| `01-deploy-eks-cluster.sh` | 创建 EKS 集群 (交互式选择 Kata/非 Kata) | 20-35 min |
| `02-deploy-controllers.sh` | 安装基础设施控制器 (EFS, ALB, Kata) | 10-15 min |
| `03-verify-deployment.sh` | 验证所有组件部署状态 | 1 min |
| `04-deploy-application-stack.sh` | **统一部署**应用栈 (Operator + Cognito + CloudFront + Service) | 20-30 min |
| `build-and-push-image.sh` | 独立的 Docker 镜像构建脚本 (支持本地/远程) | 5-10 min |
| `06-cleanup-all-resources.sh` | **完整清理**所有资源 (Cognito + CloudFront + EKS + IAM + EFS) | 15-30 min |

**Deprecated Scripts** (不推荐使用，已被 04 统一脚本替代):
- `04-deploy-provisioning-service.sh` - 已合并到统一脚本
- `05-deploy-cloudfront-cognito.sh` - 已合并到统一脚本

## 故障排查

### 1. EKS 集群创建失败

```bash
# 检查 eksctl 日志
tail -f /tmp/eksctl-create-*.log

# 检查 IAM 权限
aws sts get-caller-identity
aws iam get-user
```

### 2. Kata 节点未 Ready

```bash
# 检查节点状态
kubectl get nodes -l workload-type=kata

# 查看节点初始化日志
kubectl debug node/<kata-node> -it --image=ubuntu -- \
  chroot /host cat /var/log/kata-setup.log

# 检查 Kata runtime
kubectl debug node/<kata-node> -it --image=ubuntu -- \
  chroot /host which kata-runtime
```

### 3. Kata Pod 无法创建

```bash
# 检查 RuntimeClass
kubectl get runtimeclass kata-fc

# 检查 Kata DaemonSet
kubectl get ds -n kube-system kata-deploy
kubectl logs -n kube-system -l name=kata-deploy

# 检查 Pod 事件
kubectl describe pod <pod-name> -n <namespace>
```

### 4. EFS 挂载失败

```bash
# 检查 EFS FileSystem
aws efs describe-file-systems --region <region>

# 检查 Mount Targets
aws efs describe-mount-targets --file-system-id <fs-id> --region <region>

# 检查 Security Group
aws ec2 describe-security-groups --group-ids <sg-id> --region <region>

# 检查 PVC
kubectl describe pvc -n openclaw
kubectl get storageclass efs-sc -o yaml
```

### 5. Provisioning Service 无法访问

```bash
# 检查 Deployment
kubectl get deployment -n openclaw-provisioning

# 检查 Pods
kubectl get pods -n openclaw-provisioning
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning

# 检查 Ingress
kubectl get ingress -n openclaw-provisioning
kubectl describe ingress openclaw-provisioning-ingress -n openclaw-provisioning

# 检查 ALB
aws elbv2 describe-load-balancers --region <region>
```

### 6. Cognito 认证失败

```bash
# 检查 Cognito 环境变量
kubectl get deployment openclaw-provisioning -n openclaw-provisioning \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq .

# 检查 User Pool
aws cognito-idp describe-user-pool --user-pool-id <pool-id> --region <region>

# 测试 JWKS 端点
curl https://cognito-idp.<region>.amazonaws.com/<pool-id>/.well-known/jwks.json
```

### 7. CloudFront 访问失败

```bash
# 检查 Distribution 状态
aws cloudfront get-distribution --id <dist-id>

# 检查 ALB Security Group
aws ec2 describe-security-groups --group-ids <sg-id> --region <region>

# 验证 CloudFront 可以访问 ALB
curl -H "Host: <alb-dns>" http://<alb-dns>/health
```

## 环境变量

### EKS 集群配置

从 `kubectl config current-context` 自动提取:
- `CLUSTER_NAME` - EKS 集群名称
- `AWS_REGION` - AWS 区域
- `AWS_ACCOUNT` - AWS 账号 ID

### Provisioning Service

**自动配置** (由 `04-deploy-application-stack.sh` 设置):
- `COGNITO_REGION` - Cognito 区域
- `COGNITO_USER_POOL_ID` - User Pool ID
- `COGNITO_CLIENT_ID` - Client ID
- `CLOUDFRONT_DOMAIN` - CloudFront 域名
- `CLOUDFRONT_DISTRIBUTION_ID` - Distribution ID
- `PUBLIC_ALB_DNS` - ALB DNS 名称
- `SHARED_BEDROCK_ROLE_ARN` - Bedrock IAM Role ARN
- `EKS_CLUSTER_NAME` - EKS 集群名称
- `AWS_ACCOUNT_ID` - AWS 账号

**可选配置** (通过 Deployment 环境变量覆盖):
- `OPENCLAW_RUNTIME_CLASS` - 默认 RuntimeClass (default: kata-fc)
- `OPENCLAW_NODE_SELECTOR` - 节点选择器 JSON
- `OPENCLAW_CPU_REQUEST` - CPU 请求
- `OPENCLAW_MEMORY_REQUEST` - 内存请求
- `OPENCLAW_STORAGE_CLASS` - 存储类 (default: efs-sc)

### Docker 镜像构建

**本地构建** (在构建机器设置):
- `AWS_REGION` - ECR 区域
- `AWS_ACCOUNT` - AWS 账号 ID

**远程构建** (在脚本中交互式输入):
- `REMOTE_HOST` - 远程主机地址
- `REMOTE_USER` - SSH 用户
- `REMOTE_KEY` - SSH 密钥路径

## 成本估算

### 标准模式 (无 Kata)

| 资源 | 配置 | 月成本 (us-east-1) |
|------|------|--------------------|
| EKS 控制平面 | 1 集群 | $73 |
| m6g.xlarge | 2 节点 | $222 |
| NAT Gateway | Single | $32 |
| EFS | 50GB | $15 |
| EBS (gp3) | 200GB | $16 |
| ALB | 1 个 | $22 |
| **总计** | | **$380/月** |

### Kata 模式

| 资源 | 配置 | 月成本 (us-east-1) |
|------|------|--------------------|
| EKS 控制平面 | 1 集群 | $73 |
| m6g.xlarge | 2 标准节点 | $222 |
| c6g.metal | 1 Kata 节点 | $3,528 |
| NAT Gateway | Single | $32 |
| EFS | 100GB | $30 |
| EBS (gp3) | 700GB (500 Kata) | $56 |
| ALB | 1 个 | $22 |
| CloudFront | < 1TB | $85 |
| Cognito | < 50K MAU | $0 |
| **总计** | | **$4,048/月** |

**成本优化**:
- 使用 Spot 实例节省 70% (标准节点)
- NAT Gateway 替换为 NAT Instance 节省 $25/月
- CloudFront 移除可节省 $85/月 (使用 ALB 直接访问)

## 清理资源

### 自动化完整清理 (推荐) ⭐

**新增**: 一键删除所有资源的自动化脚本

```bash
cd scripts
./06-cleanup-all-resources.sh

# 脚本会自动:
# 1. 检测集群名称和区域 (从 kubectl context)
# 2. 扫描所有相关资源
# 3. 显示清理计划并要求确认
# 4. 按正确顺序删除所有资源
```

**删除的资源**:
- ✅ Kubernetes 资源 (所有 namespace, deployments, services)
- ✅ CloudFront Distribution (自动禁用后删除)
- ✅ Cognito User Pool & Clients
- ✅ EKS Cluster (包括所有 node groups, addons)
- ✅ Pod Identity Associations
- ✅ IAM Roles & Policies (OpenClawBedrockRole, OpenClawBedrockAccess)
- ✅ ALB (通过删除 Ingress 自动删除)
- ✅ Security Groups (CloudFront SG, EFS SG)
- ✅ EFS FileSystem (可选, 默认保留)
- ✅ CloudFormation Stack (如果存在)
- ✅ kubectl context

**交互式确认**:
- 显示所有待删除资源的详细列表
- 需要输入集群名称确认
- 需要输入 "DELETE" 二次确认
- EFS 单独确认 (避免误删数据)

**执行示例**:

```bash
$ ./06-cleanup-all-resources.sh

╔════════════════════════════════════════════════════════════════╗
║     ⚠️  COMPLETE RESOURCE CLEANUP - DESTRUCTIVE OPERATION ⚠️  ║
╚════════════════════════════════════════════════════════════════╝

[Step 1/12] Gathering configuration...
✓ Detected from kubectl context:
  Cluster: openclaw-prod
  Region: us-east-1

Use these values? (yes/no): yes

[Step 2/12] Scanning resources...

Resources to be deleted:

📦 Kubernetes Resources:
  ✓ openclaw-provisioning namespace
  ✓ openclaw-operator-system namespace
  ✓ 3 user namespace(s)

🌐 CloudFront:
  ✓ Distribution: E1234567890ABC

👤 Cognito:
  ✓ User Pool: us-east-1_ExAmPlE

🏗️  EKS Cluster:
  ✓ Cluster: openclaw-prod
  ✓ 2 node group(s)

🗄️  Storage:
  ✓ EFS FileSystem: fs-077bd850b7bb23b4f (15GB)

🔐 IAM Resources:
  ✓ IAM Role: OpenClawBedrockRole
  ✓ IAM Policy: OpenClawBedrockAccess

Total resources found: 12

╔════════════════════════════════════════════════════════════════╗
║                    ⚠️  FINAL WARNING ⚠️                        ║
║                                                                ║
║  This will PERMANENTLY DELETE all resources listed above.     ║
║  Data stored in EFS will be LOST unless you choose to skip it.║
║  This action CANNOT be undone.                                ║
╚════════════════════════════════════════════════════════════════╝

Type the cluster name 'openclaw-prod' to confirm deletion: openclaw-prod
Are you ABSOLUTELY sure? Type 'DELETE' in uppercase: DELETE

✓ Confirmation received. Starting cleanup...

⚠️  EFS FileSystem contains persistent data
Delete EFS FileSystem? (yes/no, default: no): no

[Step 3/12] Deleting Kubernetes resources...
✅ Kubernetes resource deletion initiated

[Step 4/12] Deleting CloudFront distribution...
Disabling distribution...
Waiting for distribution to be disabled (this may take 5-10 minutes)...
Deleting distribution...
✅ CloudFront distribution deleted

[Step 5/12] Deleting Cognito user pool...
Deleting user pool clients...
Deleting user pool...
✅ Cognito user pool deleted

[Step 6/12] Deleting Pod Identity associations...
✅ Pod Identity associations deleted

[Step 7/12] Deleting EKS cluster...
⏱️  This process typically takes 10-15 minutes...
✅ EKS cluster deleted

[Step 8/12] Deleting IAM resources...
✅ OpenClawBedrockRole deleted
✅ OpenClawBedrockAccess policy deleted

[Step 9/12] Deleting EFS FileSystem...
⚠️  EFS FileSystem preserved: fs-077bd850b7bb23b4f (15GB)

[Step 10/12] Cleaning up security groups...
✅ CloudFront security group deleted

[Step 11/12] Checking for CloudFormation stack...
No CloudFormation stack found

[Step 12/12] Cleaning up local configuration...
✅ kubectl context removed

╔════════════════════════════════════════════════════════════════╗
║                  ✅ CLEANUP COMPLETE ✅                        ║
╚════════════════════════════════════════════════════════════════╝

✨ Cleanup complete! All resources have been removed.
```

### 手动清理 (高级用户)

如果需要更精细的控制或自动化脚本失败,可以手动执行以下步骤:

<details>
<summary>点击展开手动清理步骤</summary>

```bash
# 1. 删除 CloudFront Distribution
DIST_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='OpenClaw-<cluster-name>'].Id" \
  --output text)

aws cloudfront get-distribution-config --id $DIST_ID > /tmp/dist-config.json
# 修改 Enabled: false
aws cloudfront update-distribution --id $DIST_ID --if-match <etag> \
  --distribution-config file:///tmp/dist-config.json
aws cloudfront delete-distribution --id $DIST_ID --if-match <etag>

# 2. 删除 Cognito User Pool
aws cognito-idp delete-user-pool --user-pool-id <pool-id> --region <region>

# 3. 删除 Pod Identity Association
aws eks delete-pod-identity-association \
  --cluster-name <cluster-name> \
  --association-id <assoc-id> \
  --region <region>

# 4. 删除 IAM Resources
aws iam detach-role-policy \
  --role-name OpenClawBedrockRole \
  --policy-arn arn:aws:iam::<account>:policy/OpenClawBedrockAccess
aws iam delete-role --role-name OpenClawBedrockRole
aws iam delete-policy --policy-arn arn:aws:iam::<account>:policy/OpenClawBedrockAccess

# 5. 删除 EKS 集群 (包括所有 Node Groups, ALB)
eksctl delete cluster --name <cluster-name> --region <region>

# 6. 手动删除 EFS FileSystem (可选 - 如果不需要保留数据)
aws efs delete-mount-target --mount-target-id <mt-id> --region <region>
# 等待所有 mount targets 删除后
aws efs delete-file-system --file-system-id <fs-id> --region <region>

# 7. 删除 Security Groups
aws ec2 delete-security-group --group-id <cf-sg-id> --region <region>
aws ec2 delete-security-group --group-id <efs-sg-id> --region <region>
```

</details>

### 快速清理 (仅 EKS)

**仅删除 EKS 集群**,保留其他所有资源:

```bash
eksctl delete cluster --name <cluster-name> --region <region>
```

⚠️ **警告**: 快速清理不会删除 CloudFront, Cognito, IAM Roles, EFS 等资源,这些资源会继续产生费用!

建议使用**自动化完整清理脚本**确保删除所有资源。

### 清理验证

删除后验证所有资源已移除:

```bash
# 检查 EKS 集群
aws eks describe-cluster --name <cluster-name> --region <region>
# 应该返回: ResourceNotFoundException

# 检查 CloudFront
aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='OpenClaw-<cluster-name>']"
# 应该返回: null 或空列表

# 检查 Cognito
aws cognito-idp list-user-pools --max-results 60 --region <region> \
  --query "UserPools[?Name=='openclaw-users-<cluster-name>']"
# 应该返回: null 或空列表

# 检查 IAM Role
aws iam get-role --role-name OpenClawBedrockRole
# 应该返回: NoSuchEntity

# 检查 EFS (如果删除了)
aws efs describe-file-systems --region <region> \
  --query "FileSystems[?Tags[?Key=='Name' && Value=='openclaw-shared-storage']]"
# 应该返回: null 或空列表
```

### 成本节省

完整清理后,您将停止以下费用:

| 资源 | 月成本节省 (Kata 模式) |
|------|----------------------|
| EKS 控制平面 | $73 |
| c6g.metal (Kata) | $3,528 |
| m6g.xlarge (标准) | $222 |
| NAT Gateway | $32 |
| ALB | $22 |
| CloudFront | ~$85 |
| EFS (100GB) | $30 |
| Cognito (< 50K MAU) | $0 |
| **总计** | **~$3,992/月** |

标准模式约节省 **$380/月**

## 参考文档

- [eksctl 官方文档](https://eksctl.io/)
- [EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [Kata Containers 文档](https://katacontainers.io/)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
- [EFS CSI Driver](https://github.com/kubernetes-sigs/aws-efs-csi-driver)

## 相关文档

- `configs/openclaw-cluster.yaml` - 标准集群配置
- `configs/openclaw-cluster-with-kata.yaml` - Kata 集群配置
- `QUICKSTART.md` - 5 分钟快速开始
- `COMPARISON.md` - CloudFormation vs eksctl 对比
- `../CLAUDE.md` - 项目完整指南

---
**维护者**: Claude Code
**最后更新**: 2026-03-13
