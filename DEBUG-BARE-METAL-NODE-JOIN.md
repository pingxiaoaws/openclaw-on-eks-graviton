# Bare Metal 节点无法加入 EKS 集群 - Debug 指南

## 问题现象

- Karpenter 创建了 EC2 实例（NodeClaim 状态为 Initializing 或 Unknown）
- 实例在几分钟后被终止
- `kubectl get nodes` 中看不到新节点
- Karpenter 日志显示 "deleted nodeclaim"

## Debug 步骤

### 1. 检查 Karpenter 日志

```bash
# 查看 Karpenter 创建和删除 NodeClaim 的日志
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=100 | grep -E "nodeclaim|terminat|i-0[a-f0-9]+"

# 查找具体实例 ID
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=200 | grep "provider-id"
```

**关键信息**：
- NodeClaim 名称
- EC2 Instance ID (i-xxxxxxxxx)
- 删除原因

### 2. 获取 EC2 实例 Console 输出日志

```bash
# 查看实例状态
aws ec2 describe-instances --instance-ids i-xxxxxxxxx \
  --query 'Reservations[0].Instances[0].[InstanceId,State.Name,StateTransitionReason]' \
  --output json

# 获取完整 console 日志 (最关键!)
aws ec2 get-console-output --instance-id i-xxxxxxxxx \
  --output text > /tmp/instance-console.log

# 查看 bootstrap 过程
grep "Phase\|EKS bootstrap\|kubelet\|ERROR\|FAIL" /tmp/instance-console.log
```

**关键检查点**：
- Phase 1: Devmapper setup 是否成功？
- Phase 2: EKS bootstrap 是否完成？
- Phase 3: Containerd 重启是否成功？
- Kubelet 是否启动？
- 是否有 ERROR 或 FAIL 消息？
- 系统是否立即进入 shutdown 流程？

### 3. 验证 API Server Endpoint 配置

**最常见的根本原因：UserData 中硬编码的 API endpoint 与实际集群不匹配**

```bash
# 获取实际集群的 API endpoint
ACTUAL_ENDPOINT=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "Actual cluster endpoint: $ACTUAL_ENDPOINT"

# 检查 NodeClass 中的 API_SERVER_URL
kubectl get ec2nodeclass kata-metal -o yaml | grep -A 5 "API_SERVER_URL"

# 获取实际集群信息
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' | cut -d'/' -f2)
aws eks describe-cluster --name $CLUSTER_NAME \
  --query 'cluster.{endpoint:endpoint,ca:certificateAuthority.data}' \
  --output json
```

**症状**：
- Bootstrap 日志显示 "EKS bootstrap completed"
- Kubelet 启动成功
- 但系统立即进入 shutdown 流程
- 节点从未在 `kubectl get nodes` 中出现

**解决方案**：更新 EC2NodeClass UserData 中的 `API_SERVER_URL` 和 `B64_CLUSTER_CA`

### 4. 检查 Security Group 规则

```bash
# 查看 NodeClass 的 security group 选择器
kubectl get ec2nodeclass kata-metal -o jsonpath='{.spec.securityGroupSelectorTerms}' | jq

# 查看实际的 security group 规则
aws ec2 describe-security-groups \
  --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER_NAME" \
  --query 'SecurityGroups[*].[GroupId,GroupName,IpPermissions,IpPermissionsEgress]' \
  --output json
```

**必须的出站规则**：
- TCP 443 → EKS API Server (或 0.0.0.0/0)
- TCP 443 → ECR (拉取容器镜像)
- TCP 10250 → 其他节点 (kubelet)
- UDP 53 → DNS

**推荐**：允许所有出站流量 `0.0.0.0/0`

### 5. 检查 IAM Role 和权限

```bash
# 检查 NodeClass 中的 IAM role
kubectl get ec2nodeclass kata-metal -o jsonpath='{.spec.role}'

# 验证 IAM role 存在
aws iam get-role --role-name KarpenterNodeRole-$CLUSTER_NAME

# 检查 EKS access entry
aws eks describe-access-entry \
  --cluster-name $CLUSTER_NAME \
  --principal-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/KarpenterNodeRole-$CLUSTER_NAME"
```

**必须的权限**：
- EC2 Instance Profile: `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonSSMManagedInstanceCore`
- EKS Access Entry: Type `EC2_LINUX`

### 6. 检查 Certificate Signing Requests (CSR)

```bash
# 查看是否有 pending 的 CSR
kubectl get csr | grep Pending

# 如果有 pending CSR，查看详情
kubectl describe csr <csr-name>
```

**如果有 pending CSR**：
- 说明 kubelet 尝试连接 API server 了
- 但证书认证失败
- 检查 IAM role 和 access entry 配置

**如果没有任何 CSR**：
- 说明 kubelet 根本没连接到 API server
- 检查 API endpoint 配置和 security group

### 7. 检查 Subnet 和 VPC 配置

```bash
# 查看 NodeClass 的 subnet 选择器
kubectl get ec2nodeclass kata-metal -o jsonpath='{.spec.subnetSelectorTerms}' | jq

# 查看实际的 subnet 配置
aws ec2 describe-subnets \
  --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER_NAME" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch]' \
  --output table

# 检查 VPC DNS 设置
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.resourcesVpcConfig.vpcId' --output text)
aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsSupport
aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsHostnames
```

**必须的 VPC 设置**：
- `enableDnsSupport`: true
- `enableDnsHostnames`: true

### 8. 验证 UserData 执行

如果实例还在运行，可以 SSH 进去检查：

```bash
# 使用 SSM Session Manager (推荐)
aws ssm start-session --target i-xxxxxxxxx

# 或使用 kubectl debug (如果配置了)
kubectl debug node/<node-name> -it --image=ubuntu

# 检查 cloud-init 日志
sudo cat /var/log/cloud-init-output.log
sudo journalctl -u cloud-init

# 检查 kubelet 日志
sudo journalctl -u snap.kubelet-eks.daemon -f

# 检查 containerd 日志
sudo journalctl -u containerd -f

# 验证 kubelet 配置
cat /var/lib/kubelet/kubeconfig
```

## 常见问题和解决方案

### 问题 1: API Endpoint 不匹配（本次遇到的）

**症状**：
- Bootstrap 完成，kubelet 启动
- 但节点立即关机，从未注册到集群

**原因**：
- UserData 中硬编码的 `API_SERVER_URL` 与实际集群不匹配
- Kubelet 尝试连接错误的 API server

**解决方案**：
```bash
# 动态获取并更新 NodeClass
./03-deploy-karpenter-resources.sh
```

### 问题 2: Security Group 缺少出站规则

**症状**：
- Kubelet 启动但无法连接 API server
- Console 日志显示网络超时

**解决方案**：
```bash
# 给 security group 添加出站规则
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)

aws ec2 authorize-security-group-egress \
  --group-id $SG_ID \
  --protocol all \
  --cidr 0.0.0.0/0
```

### 问题 3: IAM Role 缺少权限

**症状**：
- CSR pending 或拒绝
- Kubelet 日志显示认证失败

**解决方案**：
```bash
# 确保 IAM role 有正确的策略
aws iam attach-role-policy \
  --role-name KarpenterNodeRole-$CLUSTER_NAME \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

# 确保有 EKS access entry
aws eks create-access-entry \
  --cluster-name $CLUSTER_NAME \
  --principal-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/KarpenterNodeRole-$CLUSTER_NAME" \
  --type EC2_LINUX
```

### 问题 4: AMI 不兼容

**症状**：
- UserData 执行失败
- 缺少必要的命令或工具

**解决方案**：
- 使用 EKS-optimized AMI 或 Ubuntu EKS AMI
- 确保 AMI 有 `/etc/eks/bootstrap.sh` 脚本

### 问题 5: Bare Metal 实例特殊要求

**Kata 场景特殊要求**：
- 必须使用 bare metal 实例类型（如 c6g.metal）
- 需要额外的 devmapper setup
- Containerd 需要特殊配置

**解决方案**：
- 使用正确的 NodePool requirements (instance-category: metal)
- UserData 中包含完整的 Kata bootstrap 流程

## 快速诊断脚本

```bash
#!/bin/bash
# debug-bare-metal-join.sh

INSTANCE_ID="$1"
if [ -z "$INSTANCE_ID" ]; then
  echo "Usage: $0 <instance-id>"
  exit 1
fi

echo "=== Instance Info ==="
aws ec2 describe-instances --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].[InstanceId,InstanceType,State.Name,LaunchTime]' \
  --output table

echo ""
echo "=== Security Groups ==="
aws ec2 describe-instances --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].SecurityGroups[*].[GroupId,GroupName]' \
  --output table

echo ""
echo "=== IAM Role ==="
aws ec2 describe-instances --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
  --output text

echo ""
echo "=== Console Output (last 50 lines) ==="
aws ec2 get-console-output --instance-id $INSTANCE_ID \
  --output text | tail -50

echo ""
echo "=== Check for Errors ==="
aws ec2 get-console-output --instance-id $INSTANCE_ID \
  --output text | grep -i "error\|fail\|exception" | tail -20
```

## 预防措施

1. **使用动态配置**：不要在 UserData 中硬编码 cluster endpoint 和 CA
2. **测试 Security Group**：确保有正确的出站规则
3. **验证 IAM 权限**：部署前检查 role 和 access entry
4. **监控 Karpenter 日志**：实时查看 node provisioning 过程
5. **保留失败实例**：调试时不要立即终止失败的实例

## 相关文档

- [EKS Node Bootstrap](https://docs.aws.amazon.com/eks/latest/userguide/launch-workers.html)
- [Karpenter Troubleshooting](https://karpenter.sh/docs/troubleshooting/)
- [Kata Containers on EKS](https://github.com/kata-containers/kata-containers/tree/main/docs/how-to)

---

**最后更新**: 2026-03-30
**维护者**: Claude Code
