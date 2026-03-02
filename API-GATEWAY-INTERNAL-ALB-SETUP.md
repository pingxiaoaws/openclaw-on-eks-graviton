# API Gateway + Internal ALB 架构部署指南

## 架构概述

```
┌──────────────┐
│ 用户浏览器    │
└──────┬───────┘
       │ HTTPS + JWT Token
       ↓
┌─────────────────────────────────────────────────────────────┐
│ API Gateway (0qu1ls4sf5.execute-api.us-west-2.amazonaws.com)│
│ - JWT Authorizer (Cognito)                                  │
│ - Route: /prod/instance/{user_id}/{proxy+}                  │
└──────┬──────────────────────────────────────────────────────┘
       │ VPC Link (kn1heg)
       ↓
┌─────────────────────────────────────────────────────────────┐
│ Internal ALB (not exposed to internet)                      │
│ - Ingress Group: openclaw-instances                         │
│ - Scheme: internal                                           │
│ - Path-based routing: /instance/{user_id}/*                 │
└──────┬──────────────────────────────────────────────────────┘
       │ Kubernetes Service
       ↓
┌─────────────────────────────────────────────────────────────┐
│ OpenClaw Instances (Pods)                                   │
│ - openclaw-a744863d (namespace: openclaw-a744863d)         │
│ - openclaw-b8529c1e (namespace: openclaw-b8529c1e)         │
│ - ...                                                        │
└─────────────────────────────────────────────────────────────┘
```

## 优势

### ✅ 安全性
- **双层认证**：API Gateway JWT + OpenClaw gateway_token
- **ALB 不暴露公网**：scheme: internal
- **VPC 内部通信**：API Gateway → VPC Link → ALB

### ✅ 成本
- **无需域名和证书**：复用 API Gateway 的 HTTPS
- **共享 Internal ALB**：所有 instances 共用一个 ALB
- **无额外费用**：VPC Link 已存在

### ✅ 简单
- **无需 DNS 配置**：使用 API Gateway 现有域名
- **统一访问入口**：所有请求通过 API Gateway
- **便于监控**：集中在 API Gateway 查看日志

---

## 已完成配置

### ✅ AWS 资源
- **API Gateway**: `0qu1ls4sf5` (HTTP API)
- **API Endpoint**: `https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com`
- **VPC Link**: `kn1heg` (openclaw-provisioning-vpclink)
- **VPC Link Status**: AVAILABLE
- **Subnets**:
  - subnet-0ddf028eca68fffa2
  - subnet-08a07253e176e1909
  - subnet-05abc2d68c50fd8ae

### ✅ Kubernetes 资源
- **AWS Load Balancer Controller**: 已安装
- **IngressClass**: `alb`

### ✅ 代码更改
- Internal ALB 配置（scheme: internal）
- Path-based routing（无需 host）
- API Gateway URL 生成
- 前端 Connect 按钮适配

---

## 部署步骤

### 步骤 1: 重新部署 Operator（支持 Internal ALB）

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata/openclaw-operator

# 1. 重新生成 CRD 和 manifests
make manifests

# 2. 应用 CRD（如果有变更）
make install

# 3. 重新部署 operator
kubectl delete deployment openclaw-operator -n openclaw-operator-system
make deploy

# 4. 验证 operator 运行
kubectl get deployment -n openclaw-operator-system
kubectl logs -n openclaw-operator-system deployment/openclaw-operator --tail=20
```

### 步骤 2: 构建并部署 Provisioning Service

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata/eks-pod-service

# 1. 登录 ECR
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin \
  970547376847.dkr.ecr.us-west-2.amazonaws.com

# 2. 构建镜像
docker build -t 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest .

# 3. 推送镜像
docker push 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest

# 4. 重启 deployment
kubectl rollout restart deployment/openclaw-provisioning -n openclaw-provisioning
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning
```

### 步骤 3: 创建第一个 OpenClaw Instance

```bash
# 方法 A: 通过 Dashboard UI（推荐）
# 1. 访问：https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/dashboard
# 2. 登录（testuser@example.com / TestPass123!）
# 3. 点击 "Create OpenClaw Instance"

# 方法 B: 通过 API
TOKEN=$(cat /tmp/fresh_token.txt)  # 或重新获取 token
curl -X POST "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/provision" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'
```

### 步骤 4: 等待 Internal ALB 创建

```bash
# 监控 Ingress 创建（需要 2-3 分钟）
watch kubectl get ingress -A -l alb.ingress.kubernetes.io/group.name=openclaw-instances

# 预期输出：
# NAMESPACE           NAME                 CLASS   HOSTS   ADDRESS                                                    PORTS
# openclaw-a744863d   openclaw-a744863d    alb     *       internal-k8s-openc-xxxx.us-west-2.elb.amazonaws.com       80

# 检查 ALB 状态
kubectl describe ingress -n openclaw-a744863d openclaw-a744863d | grep -A 5 "Events:"
```

### 步骤 5: 配置 API Gateway 路由

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata

# 运行配置脚本
chmod +x scripts/setup-api-gateway-routes.sh
./scripts/setup-api-gateway-routes.sh
```

**脚本输出示例**：
```
🔧 Setting up API Gateway routes for OpenClaw instances...

📋 Step 1: Getting Internal ALB DNS...
✅ Internal ALB DNS: internal-k8s-openc-xxxxxxxx-1234567890.us-west-2.elb.amazonaws.com

📋 Step 2: Creating API Gateway integration...
✅ Integration created: xyz123

📋 Step 3: Creating API Gateway route...
✅ Route created: abc456

📋 Step 4: Verifying configuration...
--------------------------------------------------------------------
|                           GetRoutes                              |
+----------------------------------+-------------------------------+
|            RouteKey              |            Target             |
+----------------------------------+-------------------------------+
|  ANY /instance/{user_id}/{proxy+}|  integrations/xyz123          |
+----------------------------------+-------------------------------+

✅ API Gateway configuration complete!

🎉 OpenClaw instances are now accessible via:
   https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/instance/{user_id}/
```

### 步骤 6: 测试访问

```bash
# 1. 获取 user_id
USER_ID=$(kubectl get openclawinstance -A -o jsonpath='{.items[0].metadata.labels.openclaw\.rocks/user-id}')

# 2. 通过 Dashboard Connect 按钮测试（推荐）
# - 访问 Dashboard
# - 点击 "Connect to Gateway" 按钮
# - 应该自动打开新标签：https://0qu1ls4sf5.../prod/instance/{user_id}/

# 3. 或通过 curl 测试
TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id 62csdgbfh62kqtekbhjpqhmlta \
  --auth-parameters USERNAME=testuser@example.com,PASSWORD=TestPass123! \
  --region us-west-2 \
  --query 'AuthenticationResult.IdToken' \
  --output text)

curl -H "Authorization: Bearer $TOKEN" \
  "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/instance/$USER_ID/" -v
```

---

## 故障排查

### Internal ALB 未创建

```bash
# 检查 Ingress
kubectl get ingress -A

# 如果为空，检查 OpenClawInstance
kubectl get openclawinstance -A
kubectl describe openclawinstance -n openclaw-{user_id} openclaw-{user_id}

# 检查 operator 日志
kubectl logs -n openclaw-operator-system deployment/openclaw-operator --tail=100

# 检查 AWS Load Balancer Controller
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=100
```

### API Gateway 502 Bad Gateway

**可能原因**：

1. **ALB 健康检查失败**
```bash
# 检查 ALB target health
kubectl describe ingress -n openclaw-{user_id} openclaw-{user_id}

# 检查 Pod 状态
kubectl get pods -n openclaw-{user_id}
kubectl logs -n openclaw-{user_id} openclaw-{user_id}-0 -c openclaw
```

2. **Security Group 阻止流量**
```bash
# ALB 需要能访问 Pod 所在节点
# 检查节点安全组是否允许来自 VPC Link subnets 的流量
```

3. **Path 不匹配**
```bash
# 确保请求路径是 /instance/{user_id}/*
# 检查 Ingress path 配置
kubectl get ingress -n openclaw-{user_id} openclaw-{user_id} -o yaml | grep -A 5 "paths:"
```

### Connect 按钮无响应

```bash
# 1. 检查 status API 返回的 api_gateway_url
TOKEN=$(...)
curl -H "Authorization: Bearer $TOKEN" \
  "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/status/{user_id}" | jq .

# 预期输出应包含：
# {
#   "api_gateway_url": "https://0qu1ls4sf5.../prod/instance/{user_id}/"
# }

# 2. 检查浏览器 Console 是否有 JavaScript 错误

# 3. 检查 instance status
# status 必须是 "Running" 才会启用 Connect 按钮
```

---

## 清理资源

### 删除 API Gateway 路由和集成

```bash
API_ID="0qu1ls4sf5"
REGION="us-west-2"

# 1. 找到 OpenClaw 相关的 route
ROUTE_ID=$(aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
  --query 'Items[?contains(RouteKey, `instance`)].RouteId' --output text)

# 2. 删除 route
aws apigatewayv2 delete-route --api-id "$API_ID" --region "$REGION" --route-id "$ROUTE_ID"

# 3. 找到 integration（如果不再需要）
INTEGRATION_ID=$(aws apigatewayv2 get-integrations --api-id "$API_ID" --region "$REGION" \
  --query 'Items[?contains(IntegrationUri, `elb.amazonaws.com`)].IntegrationId' --output text)

# 4. 删除 integration
aws apigatewayv2 delete-integration --api-id "$API_ID" --region "$REGION" --integration-id "$INTEGRATION_ID"
```

### 删除 OpenClaw Instance

```bash
# 通过 Dashboard UI 删除（推荐）
# 或通过 API
kubectl delete openclawinstance openclaw-{user_id} -n openclaw-{user_id}
```

---

## 架构对比

### 旧架构（Internet-facing ALB + 域名）
```
优点：
- 可以使用自定义域名
- 可以在 ALB 层添加 WAF

缺点：
- 需要购买域名（成本）
- 需要申请 ACM 证书（时间）
- ALB 暴露公网（安全风险）
- 需要配置 Cognito 回调 URL（复杂）
```

### 新架构（API Gateway + Internal ALB）
```
优点：
- 复用现有 API Gateway（无额外成本）
- 复用现有 JWT 认证（无需配置）
- ALB 不暴露公网（更安全）
- 无需域名和证书（更简单）
- 统一访问入口（便于监控）

缺点：
- 无法使用自定义域名
- API Gateway 增加少量延迟（~10ms）
```

**推荐**：新架构适合大多数场景，特别是多租户 SaaS 平台。

---

## 监控和日志

### API Gateway 监控

```bash
# CloudWatch 指标
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApiGateway \
  --metric-name Count \
  --dimensions Name=ApiId,Value=0qu1ls4sf5 \
  --start-time 2026-03-02T00:00:00Z \
  --end-time 2026-03-02T23:59:59Z \
  --period 3600 \
  --statistics Sum

# 访问日志（需要启用）
aws logs tail /aws/apigateway/0qu1ls4sf5 --follow
```

### ALB 监控

```bash
# ALB 访问日志（需要启用 S3 logging）
# ALB CloudWatch 指标
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name TargetResponseTime \
  --start-time 2026-03-02T00:00:00Z \
  --end-time 2026-03-02T23:59:59Z \
  --period 300 \
  --statistics Average
```

---

## 环境变量

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `INGRESS_ENABLED` | `true` | 是否启用 Ingress |
| `INGRESS_CLASS` | `alb` | Ingress class |
| `INGRESS_SCHEME` | `internal` | ALB scheme（internal/internet-facing）|
| `INGRESS_GROUP_NAME` | `openclaw-instances` | ALB Ingress Group 名称 |
| `INGRESS_TARGET_TYPE` | `ip` | ALB target type |
| `API_GATEWAY_ENDPOINT` | `https://0qu1ls4sf5...` | API Gateway endpoint |
| `API_GATEWAY_STAGE` | `prod` | API Gateway stage |

---

## 成本估算

### 新架构成本
- **Internal ALB**: ~$22.50/月（固定）
- **VPC Link**: 已存在，无额外费用
- **API Gateway**: $1/百万请求 + $0.09/GB 数据传输
- **总成本（100个instances，1万请求/天）**: ~$30/月

### vs 旧架构成本（Internet-facing ALB）
- **Public ALB**: ~$22.50/月（固定）
- **域名**: ~$12/年
- **ACM 证书**: 免费
- **总成本**: ~$23.50/月 + 域名管理

**新架构略贵但更安全、更简单！** 🎉

---

**配置完成后，所有 OpenClaw instances 将通过 API Gateway + Internal ALB 安全访问！** 🔒
