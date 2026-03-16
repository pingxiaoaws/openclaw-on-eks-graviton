# OpenClaw EKS 部署脚本

本目录包含 OpenClaw 多租户 AI Agent 平台在 AWS EKS 上的完整部署脚本。

## 架构概述

OpenClaw 是一个基于 Kubernetes 的多租户 AI Agent 平台，具有以下特性：

- **VM 级别隔离**: 使用 Kata Containers (Firecracker/QEMU) 提供强隔离
- **多租户管理**: 自动化的实例生命周期管理（每用户独立命名空间）
- **安全认证**: 支持 Cognito JWT 或本地会话认证
- **持久化存储**: EFS 跨 AZ 共享存储（ReadWriteMany）
- **Auto-scaling**: Karpenter 自动扩缩容（可选）
- **全球分发**: CloudFront + ALB 架构

## 脚本列表

### 核心部署脚本

| 脚本 | 功能 | 执行时间 | 必需 |
|------|------|----------|------|
| `01-deploy-eks-cluster.sh` | 创建 EKS 集群和节点组 | 20-35 分钟 | ✅ |
| `02-deploy-controllers.sh` | 部署 EFS、ALB Controller、Pod Identity、Kata | 10-15 分钟 | ✅ |
| `03-deploy-karpenter-resources.sh` | 部署 Karpenter 自动扩缩容 | 5-10 分钟 | ⚠️ 可选 |
| `04-verify-deployment.sh` | 验证基础设施部署状态 | 1-2 分钟 | ✅ |
| `05-deploy-application-stack-db.sh` | 部署应用栈（推荐：Session + PostgreSQL） | 20-30 分钟 | ✅ |
| `05-deploy-application-stack-cognito.sh` | 部署应用栈（可选：Cognito 认证） | 20-30 分钟 | ⚠️ 备选 |
| `06-deploy-cloudfront-cognito.sh` | 部署 CloudFront 分发（仅限 Cognito 版本） | 5-10 分钟 | ⚠️ 可选 |
| `07-cleanup-all-resources.sh` | 清理所有 AWS 资源 | 15-30 分钟 | ⚠️ 清理用 |

### 辅助脚本

| 脚本 | 功能 |
|------|------|
| `build-and-push-image.sh` | 构建并推送 Provisioning Service Docker 镜像 |

## 快速开始

### 前置条件

1. **工具安装**：
   ```bash
   # 安装 eksctl
   brew install eksctl  # macOS

   # 安装 kubectl
   brew install kubectl

   # 安装 AWS CLI v2
   brew install awscli
   ```

2. **AWS 配置**：
   ```bash
   # 配置 AWS credentials
   aws configure

   # 验证权限
   aws sts get-caller-identity
   ```

3. **SSH 密钥**（仅 Kata 部署需要）：
   ```bash
   # 在目标区域创建 SSH 密钥对
   aws ec2 create-key-pair \
     --key-name openclaw-kata-key \
     --region <your-region> \
     --query 'KeyMaterial' \
     --output text > openclaw-kata-key.pem

   chmod 400 openclaw-kata-key.pem
   ```

### 标准部署流程

#### 步骤 1: 部署 EKS 集群

```bash
cd /path/to/eksctl-deployment/scripts

# 运行集群部署脚本
./01-deploy-eks-cluster.sh

# 交互式选择：
#   1) Standard cluster (m6g nodes only) - 推荐开发/测试
#   2) Kata cluster (m6g + c6g.metal) - 生产环境高安全性

# 输入集群配置：
#   - 集群名称: openclaw-prod
#   - AWS 区域: us-east-1 (或其他区域)
#   - 确认配置并等待完成（20-35 分钟）
```

**验证**：
```bash
kubectl get nodes
# 预期: 所有节点状态为 Ready
```

#### 步骤 2: 部署基础控制器

```bash
./02-deploy-controllers.sh

# 自动执行：
#   - 创建 EFS FileSystem
#   - 部署 EFS CSI Driver
#   - 部署 AWS Load Balancer Controller
#   - 部署 EKS Pod Identity Agent
#   - 部署 Kata Containers（如果集群包含 Kata 节点）
```

**验证**：
```bash
# 检查 EFS CSI Driver
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-efs-csi-driver

# 检查 ALB Controller
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# 检查 StorageClass
kubectl get storageclass efs-sc
```

#### 步骤 3: 部署 Karpenter（可选）

⚠️ **注意**: 仅在需要自动扩缩容时执行此步骤。

```bash
./03-deploy-karpenter-resources.sh

# 自动执行：
#   - 创建 Karpenter IAM 角色
#   - 部署 Karpenter Helm Chart
#   - 创建 NodePool 和 EC2NodeClass
```

**跳过条件**：
- 集群规模固定
- 节点数量已满足需求
- 不需要动态扩缩容

#### 步骤 4: 验证部署

```bash
./04-verify-deployment.sh

# 验证项目：
#   ✅ 集群连接正常
#   ✅ 所有节点 Ready
#   ✅ EFS CSI Driver 运行
#   ✅ EFS FileSystem 可用
#   ✅ StorageClass efs-sc 存在
#   ✅ ALB Controller 运行
#   ✅ Pod Identity Agent 运行
#   ✅ Kata RuntimeClass（如果适用）
```

**重要**: 所有检查必须通过才能继续下一步！

#### 步骤 5: 部署应用栈

**推荐选项: Session + PostgreSQL 认证**

```bash
./05-deploy-application-stack-db.sh

# 自动执行：
#   [1/9] 安装 OpenClaw Operator
#   [2/9] 创建 Bedrock IAM Role
#   [2.5/9] 创建 Provisioning Service IAM Role (含 PassRole 权限)
#   [3/9] 创建 Provisioning Service Pod Identity Association
#   [4/9] 创建 PostgreSQL 数据库（RDS 或本地）
#   [5/9] 构建并推送 Docker 镜像
#   [6/9] 部署 Provisioning Service（Session 认证）
#   [7/9] 配置 Internet-facing ALB
#   [8/9] 创建 CloudFront Distribution
#   [9/9] 更新 Service 环境变量

# 输出：
#   - ALB DNS: http://k8s-openclaw-....elb.amazonaws.com
#   - CloudFront URL: https://d1234567890abc.cloudfront.net
#   - 默认管理员: 第一个注册用户自动成为管理员
```

**验证**：
```bash
# 检查 Provisioning Service
kubectl get deployment openclaw-provisioning -n openclaw-provisioning
kubectl get pods -n openclaw-provisioning

# 检查 ALB
kubectl get ingress -n openclaw-provisioning

# 测试健康检查
curl http://<ALB-DNS>/health
```

**备选选项: Cognito 认证**（不推荐，仅用于兼容旧部署）

```bash
./05-deploy-application-stack-cognito.sh

# 需要手动创建 Cognito User Pool 和测试用户
```

#### 步骤 6: 访问应用

```bash
# 方式 1: 通过 CloudFront（推荐，HTTPS）
echo "访问 URL: https://$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='OpenClaw-openclaw-prod'].DomainName" \
  --output text)/login"

# 方式 2: 通过 ALB（HTTP）
ALB_DNS=$(kubectl get ingress -n openclaw-provisioning openclaw-provisioning \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "访问 URL: http://$ALB_DNS/login"
```

**首次登录**：
1. 访问 `/login` 页面
2. 点击 "注册" 创建账户
3. 第一个注册的用户自动成为管理员
4. 登录后可以创建 OpenClaw 实例

### 清理资源

⚠️ **警告**: 此操作将删除所有 AWS 资源，无法恢复！

```bash
./07-cleanup-all-resources.sh

# 交互式确认：
#   - 输入集群名称
#   - 输入 "DELETE" 确认
#   - 选择是否删除 EFS FileSystem

# 删除内容：
#   ✅ 所有 Kubernetes 资源
#   ✅ CloudFront Distribution
#   ✅ Cognito User Pool（如果存在）
#   ✅ Pod Identity Associations
#   ✅ EKS 集群（包括节点组）
#   ✅ IAM Roles 和 Policies
#   ✅ Security Groups
#   ⚠️ EFS FileSystem（可选保留）
```

## 重要配置说明

### 1. IAM 权限要求

Provisioning Service 需要以下权限（已在脚本中自动配置）：

```json
{
  "Statement": [
    {
      "Sid": "ManageUserIAMRoles",
      "Action": ["iam:CreateRole", "iam:DeleteRole", "iam:GetRole", ...],
      "Resource": "arn:aws:iam::*:role/openclaw-user-*"
    },
    {
      "Sid": "PassRoleToServiceAccounts",
      "Action": ["iam:PassRole"],
      "Resource": ["arn:aws:iam::*:role/OpenClawBedrockRole", ...]
    },
    {
      "Sid": "GetSharedBedrockRole",
      "Action": ["iam:GetRole"],
      "Resource": "arn:aws:iam::*:role/OpenClawBedrockRole"
    },
    {
      "Sid": "ManagePodIdentityAssociations",
      "Action": ["eks:CreatePodIdentityAssociation", ...],
      "Resource": "*"
    }
  ]
}
```

### 2. Runtime 选择

| Runtime | 启动时间 | 内存开销 | EFS 持久化 | 使用场景 |
|---------|----------|----------|------------|----------|
| **runc** (默认) | ~1s | 基础 | ✅ 完全支持 | 标准工作负载 |
| **kata-qemu** | ~500ms | 基础 + 30MB | ✅ 完全支持 (virtiofs) | VM 隔离 + 持久化 |
| **kata-fc** | ~125ms | 基础 + 5MB | ❌ tmpfs（写入不持久） | 无状态、快速启动 |

**重要**: 需要持久化存储时，**必须使用 kata-qemu**，不能使用 kata-fc。

### 3. 存储选择

- **EFS** (`efs-sc`): 跨 AZ 共享，ReadWriteMany，推荐
- **EBS gp3** (`gp3`): 单 AZ，ReadWriteOnce，性能更高

### 4. 环境变量

Provisioning Service 的关键环境变量（由脚本自动设置）：

```bash
# 认证配置（Session 模式不需要 Cognito）
DATABASE_URL=postgresql://...         # PostgreSQL 连接
SECRET_KEY=<random-secret>            # Flask session 密钥

# AWS 配置
AWS_REGION=us-east-1
AWS_ACCOUNT_ID=970547376847
EKS_CLUSTER_NAME=openclaw-prod

# Pod Identity
USE_POD_IDENTITY=true
SHARED_BEDROCK_ROLE_ARN=arn:aws:iam::...:role/OpenClawBedrockRole

# CloudFront
CLOUDFRONT_DOMAIN=d1234567890abc.cloudfront.net
CLOUDFRONT_DISTRIBUTION_ID=E1234567890ABC
PUBLIC_ALB_DNS=k8s-openclaw-....elb.amazonaws.com

# OpenClaw 默认配置
OPENCLAW_RUNTIME_CLASS=kata-qemu       # 或 null (runc)
OPENCLAW_STORAGE_CLASS=efs-sc
OPENCLAW_MODEL=bedrock/us.anthropic.claude-opus-4-6-v1:0
```

## 故障排查

### 问题 1: Pod Identity Association 创建失败

**错误信息**：
```
Failed to create Pod Identity Association: Caller does not have permission to perform `iam:PassRole`
```

**原因**: Provisioning Service IAM Policy 缺少 `iam:PassRole` 或 `iam:GetRole` 权限。

**解决方案**：
```bash
# 重新运行 Step 2.5 更新 IAM Policy
cd /path/to/eksctl-deployment/scripts
./05-deploy-application-stack-db.sh  # 会自动更新 Policy

# 或手动更新 Policy，然后重启 provisioning service
kubectl rollout restart deployment openclaw-provisioning -n openclaw-provisioning
```

### 问题 2: CloudFront 返回 502/503

**原因**：
1. ALB Security Group 未允许 CloudFront 访问
2. CloudFront Origin DNS 指向旧的 ALB

**解决方案**：
```bash
# 1. 检查 ALB Security Group
ALB_SG=$(aws elbv2 describe-load-balancers \
  --names k8s-openclaw-openclaw-... \
  --query 'LoadBalancers[0].SecurityGroups[0]' --output text)

aws ec2 describe-security-groups --group-ids $ALB_SG

# 2. 添加 CloudFront Prefix List 规则
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG \
  --ip-permissions IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds=[{PrefixListId=com.amazonaws.global.cloudfront.origin-facing}]

# 3. 更新 CloudFront Origin DNS（脚本已自动处理）
```

### 问题 3: Instance WebSocket 连接失败 (1006)

**症状**: Dashboard 显示 "disconnected (1006): no reason"

**原因**: Keeper Ingress 和 User Instance Ingress 的 ALB scheme 不一致。

**解决方案**: 使用统一的 PUBLIC_ALB 模式（脚本已修复）。

### 问题 4: Kata Pod 无法启动

**原因**: Kata 节点未安装或 RuntimeClass 不存在。

**解决方案**：
```bash
# 1. 检查 Kata 节点
kubectl get nodes -l workload-type=kata

# 2. 检查 RuntimeClass
kubectl get runtimeclass kata-qemu kata-fc

# 3. 如果缺失，重新运行 Step 2
./02-deploy-controllers.sh
```

### 问题 5: EFS PVC 卡在 Pending

**原因**: EFS CSI Driver 未运行或 Mount Target 不可用。

**解决方案**：
```bash
# 1. 检查 EFS CSI Driver
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-efs-csi-driver

# 2. 检查 EFS FileSystem
aws efs describe-file-systems --region <region>

# 3. 检查 Mount Targets
aws efs describe-mount-targets --file-system-id fs-...

# 4. 检查 Security Group (必须允许 TCP 2049 from VPC CIDR)
```

## 成本估算

### 标准集群 (无 Kata)

| 资源 | 配置 | 月成本 (us-east-1) |
|------|------|-------------------|
| EKS Control Plane | 1 cluster | $73 |
| m6g.xlarge | 2 nodes | $222 |
| NAT Gateway | Single | $32 |
| EFS | 50GB | $15 |
| EBS gp3 | 200GB | $16 |
| ALB | 1 | $22 |
| **总计** | | **~$380/月** |

### Kata 集群

| 资源 | 配置 | 月成本 (us-east-1) |
|------|------|-------------------|
| EKS Control Plane | 1 cluster | $73 |
| m6g.xlarge | 2 standard nodes | $222 |
| c6g.metal | 1 Kata node | $3,528 |
| NAT Gateway | Single | $32 |
| EFS | 100GB | $30 |
| EBS gp3 | 700GB | $56 |
| ALB | 1 | $22 |
| CloudFront | <1TB | $85 |
| **总计** | | **~$4,048/月** |

### 成本优化建议

1. **使用 Spot Instances**: 节省 ~70% 节点成本
2. **替换 NAT Gateway**: 使用 NAT Instance 节省 ~$25/月
3. **移除 CloudFront**: 仅内部访问可节省 $85/月
4. **使用 c6g.2xlarge 替代 c6g.metal**: Kata 成本降低至 ~$300/月（但容量有限）

## 高级配置

### 1. 修改集群配置

编辑配置文件：
```bash
vim ../../configs/openclaw-cluster.yaml
```

常见修改：
- `metadata.region`: 目标 AWS 区域
- `managedNodeGroups[].desiredCapacity`: 节点数量
- `managedNodeGroups[].instanceTypes`: 实例类型
- `vpc.cidr`: VPC CIDR 范围

### 2. 自定义 OpenClaw 实例默认配置

编辑 Provisioning Service 配置：
```bash
vim ../../eks-pod-service/app/config.py
```

修改 `OPENCLAW_DEFAULTS` 字典：
```python
OPENCLAW_DEFAULTS = {
    'runtime_class': 'kata-qemu',  # 或 None (runc)
    'storage_class': 'efs-sc',
    'storage_size': '10Gi',
    'model': 'bedrock/us.anthropic.claude-opus-4-6-v1:0',
    # ...
}
```

然后重新构建镜像：
```bash
./build-and-push-image.sh
```

### 3. 启用 Karpenter Auto-scaling

1. 运行 `03-deploy-karpenter-resources.sh`
2. 创建自定义 NodePool：

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: openclaw-spot
spec:
  disruption:
    consolidationPolicy: WhenEmpty
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]  # 使用 Spot 实例
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
      nodeClassRef:
        name: openclaw-arm64
```

## 参考资料

- [EKS 最佳实践](https://aws.github.io/aws-eks-best-practices/)
- [Kata Containers 文档](https://katacontainers.io/)
- [Karpenter 文档](https://karpenter.sh/)
- [OpenClaw 项目主页](../../README.md)
- [OpenClaw Operator 文档](../../k8s-operator/README.md)

## 支持

遇到问题时：

1. **查看日志**：
   ```bash
   kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning
   kubectl logs -n openclaw-operator-system deployment/openclaw-operator
   ```

2. **检查事件**：
   ```bash
   kubectl get events -A --sort-by='.lastTimestamp' | tail -20
   ```

3. **运行验证脚本**：
   ```bash
   ./04-verify-deployment.sh
   ```

4. **参考故障排查章节**（见上文）

---

**最后更新**: 2026-03-16
**维护者**: OpenClaw Team
