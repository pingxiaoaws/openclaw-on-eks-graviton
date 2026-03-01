# OpenClaw Multi-Tenant 部署指南

## 🎯 最终架构

```
用户 (Internet)
  ↓ HTTPS + JWT Token
API Gateway (Regional, Cognito Authorizer)
  ↓ VPC Link (Private Connection)
ALB (internal, Layer 7) ⚠️ 不暴露公网
  ↓ HTTP Headers: X-User-Email, X-Cognito-Sub
Provisioning Service (EKS Pods)
  ↓ 创建 K8s 资源
OpenClaw Operator → Per-User OpenClaw Instances
```

## 📋 当前状态

| 组件 | 状态 | 说明 |
|------|------|------|
| EKS Cluster | ✅ | test-s4, us-west-2 |
| Karpenter Graviton Nodepool | ✅ | provisioning-graviton |
| OpenClaw Operator | ✅ | 1 replica, ARM64 |
| Provisioning Service | ✅ | 2 replicas, ARM64 |
| Provisioning Service 代码 | ✅ | 支持 Headers (X-User-Email, X-Cognito-Sub) |
| ALB Service YAML | ✅ | service-lb.yaml (internal scheme) |
| **ALB 部署** | ⏳ | **待执行** |
| **Cognito User Pool** | ⏳ | **待创建** |
| **API Gateway** | ⏳ | **待配置** |
| **镜像重新构建** | ⏳ | **待执行** (代码已修改) |

## 🚀 部署步骤

### Phase 1: 重新构建 Provisioning Service 镜像

代码已修改支持从 Headers 读取用户信息，需要重新构建：

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata/eks-pod-service

# 登录 ECR
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin 970547376847.dkr.ecr.us-west-2.amazonaws.com

# 构建镜像
docker build -t openclaw-provisioning:latest .

# 标记镜像
docker tag openclaw-provisioning:latest \
  970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest

# 推送镜像
docker push 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest
```

### Phase 2: 部署 ALB (internal)

```bash
# 部署 ALB Service
kubectl apply -f kubernetes/service-lb.yaml

# 等待 ALB 创建完成 (需要 5-10 分钟)
kubectl get svc -n openclaw-provisioning openclaw-provisioning-alb -w

# 获取 ALB DNS 名称
kubectl get svc -n openclaw-provisioning openclaw-provisioning-alb \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# 输出示例:
# k8s-openclaw-openclaw-xxx.elb.us-west-2.amazonaws.com
```

**验证 ALB 配置：**

```bash
# 获取 ALB ARN
ALB_NAME="openclaw-provisioning-internal"
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --region us-west-2 \
  --query "LoadBalancers[?LoadBalancerName=='${ALB_NAME}'].LoadBalancerArn" \
  --output text)

# 验证 Scheme 为 internal
aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].Scheme'

# 期望输出: "internal"

# 验证 Target Health
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups \
  --load-balancer-arn $ALB_ARN \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

aws elbv2 describe-target-health \
  --target-group-arn $TARGET_GROUP_ARN

# 期望: 2 个 healthy targets (Provisioning Service Pods)
```

### Phase 3: 重启 Provisioning Service (拉取新镜像)

```bash
# 重启 Deployment
kubectl rollout restart deployment/openclaw-provisioning -n openclaw-provisioning

# 等待滚动更新完成
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning

# 验证 Pods 运行
kubectl get pods -n openclaw-provisioning
```

### Phase 4: 测试 ALB (内网测试)

**方法 1: 从 EKS Pod 内部测试**

```bash
# 获取 ALB DNS
ALB_DNS=$(kubectl get svc -n openclaw-provisioning openclaw-provisioning-alb \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# 创建测试 Pod
kubectl run -it --rm test-alb --image=curlimages/curl:latest --restart=Never -- sh

# 在 Pod 内执行:
# 健康检查
curl -v http://$ALB_DNS/health

# 创建实例 (模拟 API Gateway Headers)
curl -X POST http://$ALB_DNS/provision \
  -H "Content-Type: application/json" \
  -H "X-User-Email: test@example.com" \
  -H "X-Cognito-Sub: test-sub-123" \
  -d '{}' | jq .
```

**方法 2: 从本地通过 kubectl port-forward**

```bash
# Port-forward 到 ALB (通过 Service)
kubectl port-forward -n openclaw-provisioning svc/openclaw-provisioning-alb 8080:80

# 在另一个终端测试
curl -X POST http://localhost:8080/provision \
  -H "Content-Type: application/json" \
  -H "X-User-Email: test@example.com" \
  -H "X-Cognito-Sub: test-sub-123" \
  -d '{}' | jq .
```

### Phase 5: 创建 Cognito User Pool

```bash
# 创建 User Pool
aws cognito-idp create-user-pool \
  --pool-name openclaw-users \
  --region us-west-2 \
  --policies "PasswordPolicy={MinimumLength=12,RequireUppercase=true,RequireLowercase=true,RequireNumbers=true,RequireSymbols=true}" \
  --auto-verified-attributes email \
  --username-attributes email \
  --schema '[{"Name":"email","Required":true,"Mutable":false}]' \
  --mfa-configuration OPTIONAL \
  --user-attribute-update-settings "AttributesRequireVerificationBeforeUpdate=[\"email\"]"

# 记录 User Pool ID
USER_POOL_ID=$(aws cognito-idp list-user-pools --max-results 10 --region us-west-2 \
  --query "UserPools[?Name=='openclaw-users'].Id" --output text)

echo "User Pool ID: $USER_POOL_ID"

# 创建 App Client
aws cognito-idp create-user-pool-client \
  --user-pool-id $USER_POOL_ID \
  --client-name openclaw-client \
  --region us-west-2 \
  --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
  --generate-secret \
  --supported-identity-providers COGNITO

# 记录 Client ID
CLIENT_ID=$(aws cognito-idp list-user-pool-clients \
  --user-pool-id $USER_POOL_ID \
  --region us-west-2 \
  --query "UserPoolClients[0].ClientId" \
  --output text)

echo "Client ID: $CLIENT_ID"

# 创建测试用户
aws cognito-idp admin-create-user \
  --user-pool-id $USER_POOL_ID \
  --username testuser@example.com \
  --region us-west-2 \
  --user-attributes Name=email,Value=testuser@example.com Name=email_verified,Value=true \
  --temporary-password 'TempPassword123!' \
  --message-action SUPPRESS

# 设置永久密码
aws cognito-idp admin-set-user-password \
  --user-pool-id $USER_POOL_ID \
  --username testuser@example.com \
  --password 'MySecurePassword123!' \
  --permanent \
  --region us-west-2
```

### Phase 6: 创建 VPC Link

```bash
# 获取 ALB ARN (如果没有)
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --region us-west-2 \
  --query "LoadBalancers[?LoadBalancerName=='openclaw-provisioning-internal'].LoadBalancerArn" \
  --output text)

# 获取 EKS 私有子网 IDs
SUBNET_IDS=$(aws ec2 describe-subnets \
  --region us-west-2 \
  --filters "Name=vpc-id,Values=vpc-xxxxx" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[*].SubnetId' \
  --output text | tr '\t' ',')

# 创建 VPC Link
aws apigatewayv2 create-vpc-link \
  --name openclaw-provisioning-vpclink \
  --subnet-ids ${SUBNET_IDS//,/ } \
  --region us-west-2

# 记录 VPC Link ID
VPC_LINK_ID=$(aws apigatewayv2 get-vpc-links \
  --region us-west-2 \
  --query "Items[?Name=='openclaw-provisioning-vpclink'].VpcLinkId" \
  --output text)

echo "VPC Link ID: $VPC_LINK_ID"

# 等待 VPC Link 可用 (需要 5-10 分钟)
aws apigatewayv2 get-vpc-link \
  --vpc-link-id $VPC_LINK_ID \
  --region us-west-2 \
  --query 'VpcLinkStatus'

# 期望输出: "AVAILABLE"
```

### Phase 7: 创建 API Gateway

**Option A: 使用 AWS CLI 创建**

```bash
# 创建 REST API
API_ID=$(aws apigateway create-rest-api \
  --name openclaw-provisioning-api \
  --description "OpenClaw Multi-Tenant Provisioning API" \
  --endpoint-configuration types=REGIONAL \
  --region us-west-2 \
  --query 'id' \
  --output text)

echo "API Gateway ID: $API_ID"

# 创建 Cognito Authorizer
AUTHORIZER_ID=$(aws apigateway create-authorizer \
  --rest-api-id $API_ID \
  --name CognitoAuthorizer \
  --type COGNITO_USER_POOLS \
  --provider-arns arn:aws:cognito-idp:us-west-2:970547376847:userpool/$USER_POOL_ID \
  --identity-source method.request.header.Authorization \
  --region us-west-2 \
  --query 'id' \
  --output text)

echo "Authorizer ID: $AUTHORIZER_ID"

# ... (继续创建资源、方法、集成 - 见下文完整脚本)
```

**Option B: 使用 Terraform / CloudFormation (推荐生产环境)**

参考文件: `terraform/api-gateway.tf` (待创建)

### Phase 8: 端到端测试

```bash
# 获取 API Gateway URL
API_URL="https://${API_ID}.execute-api.us-west-2.amazonaws.com/prod"

# 1. 用户登录获取 token
TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id $CLIENT_ID \
  --region us-west-2 \
  --auth-parameters USERNAME=testuser@example.com,PASSWORD='MySecurePassword123!' \
  --query 'AuthenticationResult.IdToken' \
  --output text)

# 2. 调用 API 创建实例
curl -X POST "${API_URL}/provision" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}' | jq .

# 期望输出:
# {
#   "status": "created",
#   "user_id": "a744863d",
#   "namespace": "openclaw-a744863d",
#   "gateway_endpoint": "openclaw-a744863d.openclaw-a744863d.svc:18789"
# }

# 3. 查询状态
curl -X GET "${API_URL}/status/a744863d" \
  -H "Authorization: Bearer $TOKEN" | jq .

# 4. 验证实例
kubectl get all,openclawinstance -n openclaw-a744863d
```

## 🔧 故障排查

### 问题 1: ALB Target Unhealthy

**症状：**
```bash
aws elbv2 describe-target-health --target-group-arn $TG_ARN
# State: unhealthy
```

**排查：**
```bash
# 1. 检查 Pod 状态
kubectl get pods -n openclaw-provisioning

# 2. 检查 Pod 日志
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=50

# 3. 测试健康检查
kubectl port-forward -n openclaw-provisioning svc/openclaw-provisioning 8080:8080
curl http://localhost:8080/health

# 4. 检查安全组
# 确保 ALB 安全组允许访问 Pod 端口 8080
```

### 问题 2: VPC Link 创建失败

**症状：**
```bash
aws apigatewayv2 get-vpc-link --vpc-link-id $VPC_LINK_ID
# VpcLinkStatus: FAILED
```

**排查：**
```bash
# 1. 检查子网配置
# 确保子网是私有子网，有 internal-elb tag

# 2. 检查 NAT Gateway
# VPC Link 需要 NAT Gateway 访问 AWS APIs

# 3. 重新创建 VPC Link
aws apigatewayv2 delete-vpc-link --vpc-link-id $VPC_LINK_ID
# 重新执行 Phase 6
```

### 问题 3: API Gateway 返回 403

**症状：**
```bash
curl -X POST "$API_URL/provision" -H "Authorization: Bearer $TOKEN"
# {"message": "Unauthorized"}
```

**排查：**
```bash
# 1. 验证 Token
echo $TOKEN | cut -d. -f2 | base64 -d | jq .

# 2. 检查 Authorizer 配置
aws apigateway get-authorizer \
  --rest-api-id $API_ID \
  --authorizer-id $AUTHORIZER_ID

# 3. 测试 Authorizer
aws apigateway test-invoke-authorizer \
  --rest-api-id $API_ID \
  --authorizer-id $AUTHORIZER_ID \
  --headers Authorization="Bearer $TOKEN"
```

### 问题 4: Headers 未传递

**症状：**
Provisioning Service 日志显示 "email is required"

**排查：**
```bash
# 1. 检查 API Gateway Mapping Template
# 确保配置了:
# X-User-Email: $context.authorizer.claims.email
# X-Cognito-Sub: $context.authorizer.claims.sub

# 2. 检查 ALB 是否转发 Headers
# ALB (Layer 7) 应该支持 Headers

# 3. 测试直接调用 (跳过 API Gateway)
kubectl port-forward -n openclaw-provisioning svc/openclaw-provisioning-alb 8080:80
curl -X POST http://localhost:8080/provision \
  -H "X-User-Email: test@example.com" \
  -H "X-Cognito-Sub: test-123" \
  -d '{}' | jq .
```

## 📊 监控和日志

### CloudWatch Metrics

```bash
# API Gateway
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApiGateway \
  --metric-name Count \
  --dimensions Name=ApiName,Value=openclaw-provisioning-api \
  --start-time 2026-03-01T00:00:00Z \
  --end-time 2026-03-01T23:59:59Z \
  --period 3600 \
  --statistics Sum

# ALB
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name TargetResponseTime \
  --dimensions Name=LoadBalancer,Value=app/openclaw-provisioning-internal/xxx \
  --start-time 2026-03-01T00:00:00Z \
  --end-time 2026-03-01T23:59:59Z \
  --period 300 \
  --statistics Average
```

### 日志

```bash
# Provisioning Service Logs
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=100 -f

# API Gateway Logs (需要启用)
aws logs tail /aws/apigateway/openclaw-provisioning-api --follow

# ALB Access Logs (需要启用 S3 存储)
aws s3 ls s3://my-alb-logs/openclaw-provisioning-internal/ --recursive
```

## 🎯 成功标准

部署成功后，应该能够：

- ✅ 用户通过 Cognito 登录获取 JWT token
- ✅ 调用 API Gateway 创建 OpenClaw 实例
- ✅ API Gateway 自动注入 X-User-Email, X-Cognito-Sub headers
- ✅ Provisioning Service 读取 headers，生成 user_id
- ✅ 每个用户获得独立的 namespace 和 OpenClaw instance
- ✅ ALB 不暴露到公网（internal scheme）
- ✅ 所有流量经过 Cognito 认证

## 📚 相关文档

- [MULTI-TENANT-ARCHITECTURE.md](./MULTI-TENANT-ARCHITECTURE.md) - 完整架构说明
- [SECURITY-ARCHITECTURE.md](./SECURITY-ARCHITECTURE.md) - 安全最佳实践
- [README.md](./eks-pod-service/README.md) - Provisioning Service 详细文档
- [QUICKSTART.md](./eks-pod-service/QUICKSTART.md) - 快速开始指南

---

**维护者**: Claude Code
**最后更新**: 2026-03-01
**状态**: 等待部署验证
