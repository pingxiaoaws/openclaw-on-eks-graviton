# 运行清理脚本

## 在终端中执行

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata/eksctl-deployment/scripts
./06-cleanup-all-resources.sh
```

## 交互提示回答

脚本会按顺序提示以下问题：

### 1. 确认集群配置
```
✓ Detected from kubectl context:
  Cluster: openclaw-prod
  Region: us-east-1

Use these values? (yes/no):
```
**回答**: `yes`

### 2. 查看待删除资源
脚本会扫描并显示所有资源，然后显示：
```
Total resources found: XX

Type the cluster name 'openclaw-prod' to confirm deletion:
```
**回答**: `openclaw-prod`

### 3. 最终确认
```
Are you ABSOLUTELY sure? Type 'DELETE' in uppercase:
```
**回答**: `DELETE`

### 4. EFS 删除确认
```
⚠️  EFS FileSystem contains persistent data
Delete EFS FileSystem? (yes/no, default: no):
```
**回答**: 
- `yes` - 删除 EFS (数据会丢失)
- `no` - 保留 EFS (推荐，避免误删数据)

### 5. eksctl 创建的 IAM Roles (如果有)
```
Delete these roles? (yes/no):
```
**回答**: `yes`

## 预计时间

- **总时间**: 15-30 分钟
- **CloudFront 禁用**: 10-15 分钟（最慢）
- **EKS 集群删除**: 10-15 分钟

## 删除的资源

✅ Kubernetes 资源
✅ CloudFront Distribution (E1JRM6XUVXVYBO)
✅ Cognito User Pool (us-east-1_WOuSPebvM)
✅ EKS Cluster (openclaw-prod)
✅ Pod Identity Associations
✅ IAM Roles & Policies
✅ ALB
✅ Security Groups
✅ EFS (可选: fs-0a2ecde5ed6dc0b7e)
✅ kubectl context

## 成本节省

删除后每月节省约 **$380-$4,000**（取决于部署模式）
