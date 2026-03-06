# CloudFront + Public ALB + Device Pairing Integration

## Overview

本文档描述了 OpenClaw Provisioning Service 的增强功能，整合了 CloudFront/ALB 和 Device Pairing 经验。

**实施日期**: 2026-03-06
**架构变更**: Internal ALB + API Gateway → **Public ALB + CloudFront** (推荐)

---

## 新增功能

### 1. CloudFront + Public ALB 支持

#### 架构演进

**旧架构** (Internal ALB):
```
User → API Gateway → VPC Link → Internal ALB → OpenClaw
```

**新架构** (Public ALB + CloudFront):
```
User → CloudFront (HTTPS) → Internet-Facing ALB → OpenClaw
```

#### 配置说明

**环境变量** (新增):

```yaml
# kubernetes/deployment.yaml 或 ConfigMap
env:
- name: USE_PUBLIC_ALB
  value: "true"  # 启用 Public ALB 模式

- name: CLOUDFRONT_DOMAIN
  value: "d3ik6njnl847zd.cloudfront.net"

- name: CLOUDFRONT_DISTRIBUTION_ID
  value: "E30KMUI0GGXXLY"

- name: PUBLIC_ALB_DNS
  value: "k8s-openclawsharedins-df8a132590-1940875357.us-west-2.elb.amazonaws.com"

- name: PUBLIC_ALB_GROUP_NAME
  value: "openclaw-shared-instances"

- name: PUBLIC_ALB_SUBNETS
  value: "subnet-08a07253e176e1909,subnet-05abc2d68c50fd8ae,subnet-0ddf028eca68fffa2,subnet-0ab9282c748d87511"

- name: GATEWAY_TRUSTED_PROXIES
  value: "0.0.0.0/0"  # 生产环境建议改为 VPC CIDR 或 CloudFront IP ranges
```

**效果**:
- 每个 OpenClawInstance 自动配置 `spec.config.raw.gateway.allowedOrigins` 包含 CloudFront 域名
- 每个 OpenClawInstance 自动配置 `spec.config.raw.gateway.trustedProxies`
- Ingress 使用 Internet-Facing ALB + 完整的 4 AZ 子网配置
- 通过 `https://d3ik6njnl847zd.cloudfront.net/instance/{user_id}/` 访问

#### Gateway 配置自动注入

**代码位置**: `app/k8s/instance.py`

```python
# 自动注入到 OpenClawInstance CRD
config_raw = {
    "gateway": {
        "controlUi": {
            "allowedOrigins": [
                "https://d3ik6njnl847zd.cloudfront.net",
                "http://k8s-openclawsharedins-df8a132590-1940875357.us-west-2.elb.amazonaws.com",
                "https://k8s-openclawsharedins-df8a132590-1940875357.us-west-2.elb.amazonaws.com"
            ]
        },
        "trustedProxies": ["0.0.0.0/0"]
    },
    "agents": { ... }
}
```

**验证**:

```bash
# 检查 OpenClawInstance 配置
kubectl get openclawinstance openclaw-{user_id} -n openclaw-{user_id} -o yaml | grep -A 10 gateway

# 应该看到:
#   gateway:
#     controlUi:
#       allowedOrigins:
#         - https://d3ik6njnl847zd.cloudfront.net
#         - ...
#     trustedProxies:
#       - 0.0.0.0/0
```

#### Ingress 配置自动生成

**代码位置**: `app/k8s/instance.py` → `_build_ingress_config()`

```python
# Public ALB 模式
annotations = {
    "alb.ingress.kubernetes.io/scheme": "internet-facing",
    "alb.ingress.kubernetes.io/target-type": "ip",
    "alb.ingress.kubernetes.io/group.name": "openclaw-shared-instances",
    "alb.ingress.kubernetes.io/subnets": "subnet-08a...,subnet-05a...,subnet-0dd...,subnet-0ab...",
    "alb.ingress.kubernetes.io/healthcheck-protocol": "HTTP",
    "alb.ingress.kubernetes.io/success-codes": "200,404",
    "alb.ingress.kubernetes.io/target-group-attributes": "..."
}

hosts = [{
    "host": "d3ik6njnl847zd.cloudfront.net",
    "paths": [{
        "path": f"/instance/{user_id}",
        "pathType": "Prefix"
    }]
}]
```

**验证**:

```bash
# 检查 Ingress
kubectl get ingress -n openclaw-{user_id} openclaw-{user_id} -o yaml

# 确认:
# 1. annotations 包含 scheme=internet-facing
# 2. annotations 包含正确的 4 AZ subnets
# 3. hosts[0].host = d3ik6njnl847zd.cloudfront.net
# 4. ALB 地址匹配 k8s-openclawsharedins-df8a132590-...
```

---

### 2. Device Pairing API

#### 新增 API 端点

**`POST /api/devices/approve`** - 批准设备配对

**认证**: JWT required (Authorization: Bearer token)
**授权**: 用户只能批准自己实例的设备

**Request**:
```json
{
  "user_id": "7ec7606c",
  "request_id": "d5fd3ea8-7c50-4fac-a074-83ebab0b5c0d"
}
```

**Response** (200 OK):
```json
{
  "success": true,
  "message": "Device approved successfully",
  "user_id": "7ec7606c",
  "request_id": "d5fd3ea8-7c50-4fac-a074-83ebab0b5c0d",
  "output": "Device approved"
}
```

**Error Responses**:
- `401 Unauthorized` - 无效或过期的 JWT token
- `403 Forbidden` - 尝试批准其他用户的设备
- `404 Not Found` - OpenClaw instance pod 不存在
- `500 Internal Server Error` - 执行失败

**实现**:
- 使用 Kubernetes `stream.connect_get_namespaced_pod_exec` API
- 执行命令: `openclaw devices approve <request_id>`
- 在 `openclaw-{user_id}` namespace 的 `openclaw-{user_id}-0` pod 中执行

**`GET /api/devices/list`** - 列出设备

**认证**: JWT required
**授权**: 用户只能列出自己实例的设备

**Query Parameters**:
- `user_id` (optional) - 默认使用认证用户的 user_id

**Response** (200 OK):
```json
{
  "success": true,
  "user_id": "7ec7606c",
  "output": "..."
}
```

#### 测试 Device Pairing API

```bash
# 1. 获取 JWT token
TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id f5qd2udi8508dd132d72qn7uc \
  --auth-parameters USERNAME=<email>,PASSWORD=<password> \
  --region us-west-2 \
  --query 'AuthenticationResult.IdToken' \
  --output text)

# 2. 获取 request_id (从 OpenClaw pod 日志)
kubectl logs -n openclaw-{user_id} openclaw-{user_id}-0 -c openclaw | grep "pairing request"

# 3. 批准设备
curl -X POST https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/api/devices/approve \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "7ec7606c",
    "request_id": "d5fd3ea8-7c50-4fac-a074-83ebab0b5c0d"
  }'

# 4. 列出设备
curl -X GET "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/api/devices/list?user_id=7ec7606c" \
  -H "Authorization: Bearer $TOKEN"
```

#### 前端集成示例

```javascript
// 自动 device pairing 流程
const ws = new WebSocket('wss://d3ik6njnl847zd.cloudfront.net/instance/416e0b5f?token=xxx');

ws.onmessage = (event) => {
    const data = JSON.parse(event.data);
    if (data.type === 'pairing_required') {
        // 自动调用后端 API 批准
        fetch('https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/api/devices/approve', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${localStorage.getItem('idToken')}`
            },
            body: JSON.stringify({
                user_id: currentUserId,
                request_id: data.requestId
            })
        }).then(() => {
            // 重新连接 WebSocket
            ws.close();
            reconnect();
        });
    }
};
```

---

## 文件变更清单

### 新增文件

1. **`app/utils/pod_exec.py`** - Kubernetes pod exec 工具
   - `exec_in_pod()` - 在 pod 中执行命令
   - `check_pod_exists()` - 检查 pod 是否存在

2. **`app/api/devices.py`** - Device pairing API
   - `POST /api/devices/approve` - 批准设备
   - `GET /api/devices/list` - 列出设备

3. **`CLOUDFRONT-INTEGRATION.md`** - 本文档

### 修改文件

4. **`app/config.py`** - 新增配置
   - `CLOUDFRONT_DOMAIN`, `CLOUDFRONT_DISTRIBUTION_ID`
   - `PUBLIC_ALB_DNS`, `PUBLIC_ALB_GROUP_NAME`, `PUBLIC_ALB_SUBNETS`
   - `GATEWAY_CONFIG` (allowedOrigins + trustedProxies)
   - `PUBLIC_ALB_INGRESS_ANNOTATIONS`
   - `USE_PUBLIC_ALB` (开关)

5. **`app/k8s/instance.py`** - 注入 gateway + ingress 配置
   - `create_openclaw_instance()` - 添加 `config.raw.gateway`
   - `_build_ingress_config()` - 支持 Public ALB 模式

6. **`app/api/__init__.py`** - 注册 `devices_bp`

7. **`app/main.py`** - 注册 `devices_bp` blueprint

8. **`kubernetes/rbac.yaml`** - 添加 `pods/exec` 权限

---

## 部署步骤

### 1. 更新 RBAC (一次性操作)

```bash
kubectl apply -f kubernetes/rbac.yaml

# 验证 pods/exec 权限
kubectl auth can-i create pods/exec \
  --as=system:serviceaccount:openclaw-provisioning:openclaw-provisioner \
  --namespace=openclaw-test
```

### 2. 重新构建和部署镜像

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata/eks-pod-service

# Login to ECR
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin \
  970547376847.dkr.ecr.us-west-2.amazonaws.com

# Build multi-arch image (支持 ARM64 + AMD64)
docker buildx build --platform linux/arm64,linux/amd64 \
  -t 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest \
  --push .

# 或仅 ARM64 (如果集群只有 Graviton 节点)
docker build -t 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest .
docker push 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest
```

### 3. 更新 Deployment 环境变量 (可选)

如果需要覆盖默认配置:

```bash
kubectl edit deployment openclaw-provisioning -n openclaw-provisioning

# 添加/修改 env:
spec:
  template:
    spec:
      containers:
      - name: provisioning
        env:
        - name: USE_PUBLIC_ALB
          value: "true"
        - name: CLOUDFRONT_DOMAIN
          value: "d3ik6njnl847zd.cloudfront.net"
        - name: PUBLIC_ALB_DNS
          value: "k8s-openclawsharedins-df8a132590-1940875357.us-west-2.elb.amazonaws.com"
        # ... 其他配置
```

### 4. 重启 Deployment

```bash
# 触发滚动更新
kubectl rollout restart deployment openclaw-provisioning -n openclaw-provisioning

# 等待就绪
kubectl rollout status deployment openclaw-provisioning -n openclaw-provisioning

# 检查日志
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning -f | grep -E "(CloudFront|Public ALB|gateway)"
```

### 5. 验证新功能

#### 5.1 验证 CloudFront + Gateway 配置

```bash
# 创建测试实例
curl -X POST https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/provision \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json"

# 等待实例创建
kubectl wait --for=condition=ready pod -n openclaw-{user_id} -l app.kubernetes.io/name=openclaw --timeout=300s

# 检查 gateway 配置
kubectl get openclawinstance openclaw-{user_id} -n openclaw-{user_id} -o yaml | grep -A 10 gateway

# 检查 Ingress
kubectl get ingress -n openclaw-{user_id}
kubectl describe ingress openclaw-{user_id} -n openclaw-{user_id}

# 确认 ALB 地址
kubectl get ingress -n openclaw-{user_id} openclaw-{user_id} \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# 应该是: k8s-openclawsharedins-df8a132590-...
```

#### 5.2 验证 Device Pairing API

```bash
# 测试批准设备 (替换为实际的 request_id)
curl -X POST https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/api/devices/approve \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "7ec7606c",
    "request_id": "test-request-id"
  }'

# 测试列出设备
curl -X GET "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/api/devices/list" \
  -H "Authorization: Bearer $TOKEN"
```

#### 5.3 端到端 WebSocket 测试

```bash
# 使用 wscat 测试 CloudFront endpoint
wscat -c "wss://d3ik6njnl847zd.cloudfront.net/instance/{user_id}?token=xxx"

# 或使用 HTML 测试页面
# 创建 test.html 包含 WebSocket 连接代码
```

---

## 故障排查

### CloudFront 配置问题

**症状**: WebSocket 连接失败，显示 "Forbidden" 或 CORS 错误

**检查**:

```bash
# 1. 验证 gateway allowedOrigins
kubectl get openclawinstance -n openclaw-{user_id} -o yaml | grep allowedOrigins -A 5

# 2. 验证 ALB Security Group 规则
aws elbv2 describe-load-balancers \
  --names k8s-openclawsharedins-df8a132590 \
  --region us-west-2 \
  --query 'LoadBalancers[0].SecurityGroups'

# Security Group 应该允许:
# - CloudFront Prefix List (com.amazonaws.global.cloudfront.origin-facing)
# - 或 0.0.0.0/0 (开发环境)

# 3. 测试 ALB 直接访问
curl -I http://k8s-openclawsharedins-df8a132590-1940875357.us-west-2.elb.amazonaws.com/instance/{user_id}/
```

**解决方案**:

```bash
# 如果 ALB Security Group 缺少规则，添加:
SG_ID=$(aws elbv2 describe-load-balancers \
  --names k8s-openclawsharedins-df8a132590 \
  --region us-west-2 \
  --query 'LoadBalancers[0].SecurityGroups[0]' \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 80 \
  --source-prefix-list-id pl-82a045eb \
  --region us-west-2
```

### Device Pairing 执行失败

**症状**: `POST /api/devices/approve` 返回 500 错误

**检查**:

```bash
# 1. 检查 RBAC 权限
kubectl auth can-i create pods/exec \
  --as=system:serviceaccount:openclaw-provisioning:openclaw-provisioner \
  --namespace=openclaw-{user_id}

# 2. 检查 pod 是否存在
kubectl get pod -n openclaw-{user_id} openclaw-{user_id}-0

# 3. 手动测试 exec
kubectl exec -n openclaw-{user_id} openclaw-{user_id}-0 -c openclaw -- \
  openclaw devices list

# 4. 检查 provisioning service 日志
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning | grep "exec"
```

**解决方案**:

```bash
# 如果 RBAC 权限缺失
kubectl apply -f kubernetes/rbac.yaml

# 如果 pod 不存在
kubectl get openclawinstance -n openclaw-{user_id}
# 检查 OpenClawInstance 状态和 Operator 日志
```

---

## 配置最佳实践

### 生产环境配置

```yaml
# kubernetes/deployment.yaml 或 ConfigMap
env:
- name: USE_PUBLIC_ALB
  value: "true"

- name: CLOUDFRONT_DOMAIN
  value: "your-cloudfront.cloudfront.net"

- name: PUBLIC_ALB_DNS
  value: "k8s-your-alb-xxx.us-west-2.elb.amazonaws.com"

# 安全性: 限制 trustedProxies 为 VPC CIDR 或 CloudFront IP ranges
- name: GATEWAY_TRUSTED_PROXIES
  value: "172.31.0.0/16"  # VPC CIDR

# 或使用 CloudFront Prefix List
- name: GATEWAY_TRUSTED_PROXIES
  value: "pl-82a045eb"  # com.amazonaws.global.cloudfront.origin-facing
```

### 成本优化

| 组件 | 成本 | 说明 |
|------|------|------|
| CloudFront | $20/月 | 共享分发 (所有用户) |
| Internet-Facing ALB | $16/月 | 共享 ALB (所有用户) |
| Provisioning Service | $5/月 | 2 replica Pods |
| **每用户边际成本** | **$0** | 共享基础设施 |

**对比 API Gateway + Internal ALB**:
- API Gateway: $1.00/百万请求 + VPC Link $72/月
- CloudFront: $0.085/GB (更便宜)

---

## 后续优化

1. **自动 Device Pairing** - 前端自动调用 `/api/devices/approve`
2. **独立域名支持** - 每用户一个 CloudFront Distribution
3. **WAF 集成** - 在 CloudFront 层添加 Web Application Firewall
4. **CloudFront Origin 管理** - 动态更新 CloudFront 配置 (如果采用每用户独立 Distribution)
5. **Device Pairing 通知** - WebSocket 推送 pairing 事件到前端

---

## 参考资料

- 相关部署文档: `../CLOUDFRONT-DEPLOYMENT-COMPLETE.md`
- 正确的 WebSocket 配置: `../CLOUDFRONT-WEBSOCKET-CORRECT-OPTIONS.md`
- Device Pairing 解决方案: `../PAIRING-SOLUTION.md`
- CloudFront Distribution ID: `E30KMUI0GGXXLY`
- Public ALB: `k8s-openclawsharedins-df8a132590-1940875357.us-west-2.elb.amazonaws.com`

---

**最后更新**: 2026-03-06
**维护者**: Claude Code
**状态**: 实施完成，待测试
