# OpenClaw API Gateway + Internal ALB 测试计划

## 测试目标

验证 API Gateway + Internal ALB 架构的完整端到端功能。

## 测试范围

### 功能测试
- ✅ Operator 支持 ALB provider
- ✅ Provisioning Service 创建 Internal ALB Ingress
- ✅ Internal ALB 正确创建和配置
- ✅ API Gateway 路由正确转发到 Internal ALB
- ✅ JWT 认证正常工作
- ✅ OpenClaw instance 可通过浏览器访问
- ✅ Dashboard Connect 按钮正常跳转

### 非功能测试
- ⚠️ 性能测试（可选）
- ⚠️ 负载测试（可选）
- ⚠️ 安全测试（可选）

---

## 测试环境

- **EKS Cluster**: test-s4 (us-west-2)
- **Kubernetes版本**: 1.34
- **API Gateway**: 0qu1ls4sf5
- **VPC Link**: kn1heg
- **测试用户**: testuser@example.com

---

## 测试执行方式

### 方式 1: 自动化脚本（推荐）

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata
chmod +x scripts/test-plan.sh
./scripts/test-plan.sh
```

**脚本功能**：
- 自动检查所有前置条件
- 逐步执行部署和测试
- 在关键步骤暂停等待确认
- 收集并展示测试结果
- 提供详细的错误信息

### 方式 2: 手动测试

按照下面的详细步骤逐步执行。

---

## 详细测试步骤

### 阶段 0: 前置条件检查 ✅

**目标**: 确保环境满足测试要求

**检查项**:
```bash
# 1. kubectl 连接正常
kubectl cluster-info

# 2. AWS 凭证有效
aws sts get-caller-identity

# 3. AWS Load Balancer Controller 已安装
kubectl get deployment -n kube-system aws-load-balancer-controller

# 4. API Gateway 存在
aws apigatewayv2 get-api --api-id 0qu1ls4sf5 --region us-west-2

# 5. VPC Link 可用
aws apigatewayv2 get-vpc-link --vpc-link-id kn1heg --region us-west-2 | jq .VpcLinkStatus
# 预期: "AVAILABLE"
```

**预期结果**: 所有检查项通过

---

### 阶段 1: 清理现有资源（可选） 🧹

**目标**: 从干净状态开始测试

```bash
# 查看现有 instances
kubectl get openclawinstance -A

# 删除所有测试 instances（如果需要）
kubectl get openclawinstance -A -o json | \
  jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | \
  while read ns name; do
    kubectl delete openclawinstance $name -n $ns
  done

# 等待资源清理
sleep 30
```

**预期结果**: 无残留资源

---

### 阶段 2: 重新部署 Operator 🔄

**目标**: 部署支持 Internal ALB 的 operator

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata/openclaw-operator

# 1. 更新 CRD
make install

# 2. 部署 operator
kubectl delete deployment openclaw-operator -n openclaw-operator-system --ignore-not-found
make deploy

# 3. 等待就绪
kubectl wait --for=condition=available deployment/openclaw-operator \
  -n openclaw-operator-system --timeout=120s

# 4. 验证
kubectl get deployment -n openclaw-operator-system
kubectl logs -n openclaw-operator-system deployment/openclaw-operator --tail=20
```

**预期结果**:
- Operator pod 状态 Running
- 无错误日志

---

### 阶段 3: 重新部署 Provisioning Service 🚀

**目标**: 部署支持 Internal ALB 的 provisioning service

**在远程机器执行**:
```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata

# 1. 拉取最新代码
git pull

# 2. 构建镜像
cd eks-pod-service
docker build -t 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest .

# 3. 推送镜像
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin \
  970547376847.dkr.ecr.us-west-2.amazonaws.com

docker push 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest
```

**在本地执行**:
```bash
# 重启 deployment
kubectl rollout restart deployment/openclaw-provisioning -n openclaw-provisioning
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning

# 验证
kubectl get pods -n openclaw-provisioning
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=20
```

**预期结果**:
- 新 pods 状态 Running
- 日志中包含 "Internal ALB Ingress configured"

---

### 阶段 4: 创建测试 Instance 📦

**目标**: 创建第一个 OpenClaw instance，触发 Internal ALB 创建

**方法 A: 通过 Dashboard UI（推荐）**
```bash
# 1. 访问
open https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/dashboard

# 2. 登录
# Email: testuser@example.com
# Password: TestPass123!

# 3. 点击 "Create OpenClaw Instance"

# 4. 观察创建过程
```

**方法 B: 通过 API**
```bash
# 1. 获取 JWT token
TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id 62csdgbfh62kqtekbhjpqhmlta \
  --auth-parameters USERNAME=testuser@example.com,PASSWORD=TestPass123! \
  --region us-west-2 \
  --query 'AuthenticationResult.IdToken' \
  --output text)

# 2. 创建 instance
curl -X POST \
  "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/provision" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}' | jq .

# 3. 记录 user_id
USER_ID="<从响应中获取>"
```

**预期结果**:
```json
{
  "user_id": "a744863d",
  "namespace": "openclaw-a744863d",
  "instance_name": "openclaw-a744863d",
  "gateway_endpoint": "openclaw-a744863d.openclaw-a744863d.svc:18789",
  "status": "created"
}
```

---

### 阶段 5: 等待 Internal ALB 创建 ⏳

**目标**: 验证 Internal ALB 成功创建

```bash
# 监控 Ingress 创建（需要 2-3 分钟）
watch kubectl get ingress -n openclaw-$USER_ID

# 预期输出：
# NAME                CLASS   HOSTS   ADDRESS                                          PORTS
# openclaw-a744863d   alb     *       internal-k8s-openc-xxx.us-west-2.elb.amazonaws.com   80
```

**详细检查**:
```bash
# 1. 检查 Ingress 配置
kubectl get ingress openclaw-$USER_ID -n openclaw-$USER_ID -o yaml

# 验证关键注解：
# - alb.ingress.kubernetes.io/scheme: internal
# - alb.ingress.kubernetes.io/group.name: openclaw-instances
# - alb.ingress.kubernetes.io/target-type: ip

# 2. 检查 events
kubectl describe ingress openclaw-$USER_ID -n openclaw-$USER_ID | grep -A 20 "Events:"

# 3. 获取 ALB DNS
ALB_DNS=$(kubectl get ingress openclaw-$USER_ID -n openclaw-$USER_ID \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Internal ALB DNS: $ALB_DNS"
```

**预期结果**:
- Ingress 状态有 ADDRESS 字段
- ALB DNS 格式: `internal-k8s-openc-*.us-west-2.elb.amazonaws.com`
- Events 无错误信息

**常见问题**:
- **Ingress 无 ADDRESS**: 检查 AWS Load Balancer Controller 日志
- **Timeout**: 检查 operator 是否正确创建 Ingress

---

### 阶段 6: 配置 API Gateway 路由 🔗

**目标**: 创建 API Gateway 到 Internal ALB 的路由

```bash
# 运行配置脚本
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata
./scripts/setup-api-gateway-routes.sh
```

**脚本执行流程**:
1. 获取 Internal ALB DNS
2. 创建 Integration（HTTP_PROXY 到 ALB via VPC Link）
3. 创建 Route（`ANY /instance/{user_id}/{proxy+}`）
4. 验证配置

**预期输出**:
```
✅ Internal ALB DNS: internal-k8s-openc-xxx.us-west-2.elb.amazonaws.com
✅ Integration created: xyz123
✅ Route created: abc456

🎉 OpenClaw instances are now accessible via:
   https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/instance/{user_id}/
```

**手动验证**:
```bash
# 检查 API Gateway 路由
aws apigatewayv2 get-routes --api-id 0qu1ls4sf5 --region us-west-2 \
  --query 'Items[?contains(RouteKey, `instance`)].{RouteKey:RouteKey,Target:Target}' \
  --output table

# 预期输出：
# RouteKey: ANY /instance/{user_id}/{proxy+}
# Target: integrations/xyz123
```

---

### 阶段 7: 测试访问 🧪

#### 测试 7.1: 通过 curl 测试

```bash
# 获取新 token（如果之前的过期）
TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id 62csdgbfh62kqtekbhjpqhmlta \
  --auth-parameters USERNAME=testuser@example.com,PASSWORD=TestPass123! \
  --region us-west-2 \
  --query 'AuthenticationResult.IdToken' \
  --output text)

# 构建 URL
API_GATEWAY_URL="https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/instance/$USER_ID/"

# 测试访问
curl -v -H "Authorization: Bearer $TOKEN" "$API_GATEWAY_URL"
```

**预期响应**:
- **HTTP 200-299**: 访问成功（如果 OpenClaw 不需要额外认证）
- **HTTP 401**: OpenClaw gateway_token 认证（正常行为，OpenClaw 需要 token）
- **HTTP 502**: ALB 健康检查失败（需要排查）

#### 测试 7.2: 验证 status API

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/status/$USER_ID" | jq .
```

**预期响应**:
```json
{
  "user_id": "a744863d",
  "status": "Running",
  "api_gateway_url": "https://0qu1ls4sf5.../prod/instance/a744863d/",
  "gateway_endpoint": "openclaw-a744863d.openclaw-a744863d.svc:18789",
  "created_at": "2026-03-03T...",
  ...
}
```

**验证点**:
- ✅ `api_gateway_url` 字段存在且正确
- ✅ `status` 为 "Running"

#### 测试 7.3: Dashboard UI 测试

```bash
# 1. 访问 Dashboard
open https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/dashboard

# 2. 登录
# Email: testuser@example.com
# Password: TestPass123!

# 3. 验证 Dashboard 显示
```

**预期界面**:
- ✅ 显示 instance 信息（user_id, namespace, status）
- ✅ Status badge 显示 "Running"（绿色）
- ✅ Gateway Endpoint 显示
- ✅ "Connect to Gateway" 按钮可点击（不是灰色）

#### 测试 7.4: Connect 按钮测试

```bash
# 在 Dashboard 中点击 "Connect to Gateway" 按钮
```

**预期行为**:
1. 新标签页自动打开
2. URL 为: `https://0qu1ls4sf5.../prod/instance/{user_id}/`
3. 页面显示 OpenClaw 界面或要求 gateway_token

**如果显示 401/403**:
```bash
# 获取 gateway_token
kubectl get secret openclaw-$USER_ID-gateway-token \
  -n openclaw-$USER_ID \
  -o jsonpath='{.data.token}' | base64 -d

# 在 OpenClaw UI 中输入 token
```

---

## 测试结果验证

### 成功标准

✅ **阶段 0-3**: 所有前置条件和部署成功
✅ **阶段 4**: Instance 创建成功，OpenClawInstance CRD 存在
✅ **阶段 5**: Internal ALB 创建，Ingress 有 ADDRESS
✅ **阶段 6**: API Gateway 路由配置成功
✅ **阶段 7.1**: curl 测试返回 200 或 401（OpenClaw auth）
✅ **阶段 7.2**: status API 返回 `api_gateway_url`
✅ **阶段 7.3**: Dashboard 正确显示 instance
✅ **阶段 7.4**: Connect 按钮打开新标签页

### 性能基准（可选）

```bash
# 测试响应时间
time curl -s -H "Authorization: Bearer $TOKEN" "$API_GATEWAY_URL" > /dev/null

# 预期: < 500ms（首次可能较慢due to cold start）
```

---

## 故障排查

### 问题 1: Ingress 无 ADDRESS

**症状**:
```bash
kubectl get ingress -n openclaw-$USER_ID
# ADDRESS 列为空，长时间无变化
```

**排查步骤**:
```bash
# 1. 检查 events
kubectl describe ingress openclaw-$USER_ID -n openclaw-$USER_ID

# 2. 检查 AWS Load Balancer Controller
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=100 | grep openclaw

# 3. 检查 Ingress 注解
kubectl get ingress openclaw-$USER_ID -n openclaw-$USER_ID -o yaml | grep annotations: -A 10
```

**常见原因**:
- IAM 权限不足（Load Balancer Controller 无法创建 ALB）
- Subnet 配置错误
- Security Group 限制

---

### 问题 2: 502 Bad Gateway

**症状**:
```bash
curl -H "Authorization: Bearer $TOKEN" "$API_GATEWAY_URL"
# 返回 502
```

**排查步骤**:
```bash
# 1. 检查 Pod 状态
kubectl get pods -n openclaw-$USER_ID
kubectl logs -n openclaw-$USER_ID openclaw-$USER_ID-0 -c openclaw --tail=50

# 2. 检查 Service
kubectl get svc -n openclaw-$USER_ID
kubectl describe svc openclaw-$USER_ID -n openclaw-$USER_ID

# 3. 检查 ALB target health
# 需要在 AWS Console 查看 ALB target group 健康状态

# 4. 测试从节点访问 Pod
POD_IP=$(kubectl get pod openclaw-$USER_ID-0 -n openclaw-$USER_ID -o jsonpath='{.status.podIP}')
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- curl http://$POD_IP:18789/
```

**常见原因**:
- Pod 未就绪（健康检查失败）
- Service selector 不匹配
- ALB 健康检查路径错误
- Security Group 阻止流量

---

### 问题 3: Connect 按钮无响应

**症状**: 点击按钮无任何反应

**排查步骤**:
```bash
# 1. 检查浏览器 Console（F12）
# 查看是否有 JavaScript 错误

# 2. 检查 status API 响应
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/status/$USER_ID" | \
  jq '{status, api_gateway_url}'

# 3. 检查前端脚本加载
# 在浏览器 Network 标签查看 api.js, dashboard.js 是否加载
```

**常见原因**:
- `api_gateway_url` 为 null（instance 未 Running）
- JavaScript 错误阻止事件监听器
- 浏览器弹窗被阻止

---

## 回滚计划

如果测试失败，需要回滚：

### 回滚 API Gateway 配置

```bash
# 1. 删除 OpenClaw 路由
ROUTE_ID=$(aws apigatewayv2 get-routes --api-id 0qu1ls4sf5 --region us-west-2 \
  --query 'Items[?contains(RouteKey, `instance`)].RouteId' --output text)

aws apigatewayv2 delete-route \
  --api-id 0qu1ls4sf5 \
  --region us-west-2 \
  --route-id $ROUTE_ID

# 2. 删除 Integration（可选）
INTEGRATION_ID=$(aws apigatewayv2 get-integrations --api-id 0qu1ls4sf5 --region us-west-2 \
  --query 'Items[?contains(IntegrationUri, `elb.amazonaws.com`)].IntegrationId' --output text)

aws apigatewayv2 delete-integration \
  --api-id 0qu1ls4sf5 \
  --region us-west-2 \
  --integration-id $INTEGRATION_ID
```

### 回滚 Provisioning Service

```bash
# 使用上一个稳定版本的镜像
# 或者回滚 deployment
kubectl rollout undo deployment/openclaw-provisioning -n openclaw-provisioning
```

### 清理测试资源

```bash
# 删除测试 instance
kubectl delete openclawinstance openclaw-$USER_ID -n openclaw-$USER_ID

# 等待资源清理
sleep 30

# 验证清理完成
kubectl get ingress -A -l alb.ingress.kubernetes.io/group.name=openclaw-instances
# 预期: 无结果（如果这是唯一的 instance）
```

---

## 测试报告模板

```markdown
# OpenClaw API Gateway + Internal ALB 测试报告

## 测试环境
- 日期: 2026-03-03
- 执行人: [姓名]
- EKS Cluster: test-s4
- Operator 版本: [commit hash]
- Provisioning Service 版本: [镜像 digest]

## 测试结果

| 阶段 | 测试项 | 结果 | 备注 |
|------|--------|------|------|
| 0 | 前置条件检查 | ✅/❌ | |
| 1 | 资源清理 | ✅/❌ | |
| 2 | Operator 部署 | ✅/❌ | |
| 3 | Provisioning Service 部署 | ✅/❌ | |
| 4 | Instance 创建 | ✅/❌ | User ID: xxx |
| 5 | Internal ALB 创建 | ✅/❌ | ALB DNS: xxx |
| 6 | API Gateway 配置 | ✅/❌ | Route ID: xxx |
| 7.1 | curl 访问测试 | ✅/❌ | HTTP Status: xxx |
| 7.2 | status API 测试 | ✅/❌ | |
| 7.3 | Dashboard UI 测试 | ✅/❌ | |
| 7.4 | Connect 按钮测试 | ✅/❌ | |

## 遇到的问题
[列出问题和解决方案]

## 性能数据
- Instance 创建时间: XX 秒
- ALB 创建时间: XX 分钟
- API 响应时间: XX ms

## 建议
[改进建议]

## 结论
✅ 通过 / ❌ 失败 / ⚠️ 部分通过
```

---

## 下一步

测试通过后：
1. ✅ 创建更多 instances 测试多租户场景
2. ✅ 监控 ALB 性能和健康状态
3. ✅ 配置 CloudWatch 告警
4. ✅ 编写用户文档
5. ✅ 准备生产环境部署

---

**测试计划版本**: v1.0
**创建日期**: 2026-03-03
**维护者**: Claude Code
