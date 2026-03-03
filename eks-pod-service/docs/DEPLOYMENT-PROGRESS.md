# WebSocket 部署进度记录

**日期**: 2026-03-03
**状态**: 进行中 - API Gateway 集成调试阶段

---

## 🎯 部署目标

实现 OpenClaw 实例的 WebSocket 支持，通过统一的 API Gateway 入口访问：

- ✅ HTTP 请求支持
- 🔄 WebSocket 连接支持（进行中）
- ✅ 多租户隔离
- ✅ 成本优化（共享 ALB）
- ✅ 自动化配置

---

## ✅ 已完成的工作

### 1. Keeper Ingress 自动创建

**文件**: `app/k8s/ingress.py`

**功能**:
- Provisioning Service 启动时自动创建 `openclaw-instances-keeper` ingress
- 确保共享 ALB 永久存活，即使所有用户实例被删除
- 使用 group name: `openclaw-shared-instances`

**配置**:
```python
annotations={
    "alb.ingress.kubernetes.io/group.name": "openclaw-shared-instances",
    "alb.ingress.kubernetes.io/scheme": "internal",
    "alb.ingress.kubernetes.io/target-type": "ip",
    "alb.ingress.kubernetes.io/target-group-attributes": (
        "stickiness.enabled=true,"
        "stickiness.type=lb_cookie,"
        "stickiness.lb_cookie.duration_seconds=3600,"
        "deregistration_delay.timeout_seconds=60,"
        "load_balancing.algorithm.type=least_outstanding_requests"
    ),
}
```

**验证**:
```bash
kubectl get ingress openclaw-instances-keeper -n openclaw-provisioning
# NAME                        CLASS   HOSTS   ADDRESS                                           PORTS   AGE
# openclaw-instances-keeper   alb     *       internal-k8s-openclawsharedins-1304d94a5a-...   80      XX
```

---

### 2. 用户实例 Ingress WebSocket 优化

**文件**: `app/k8s/instance.py`

**功能**:
- 每个用户实例创建时自动配置 WebSocket 优化的 Target Group
- 通过 Ingress annotations 声明式配置（无需手动脚本）

**关键配置**:
- **Stickiness**: 1小时 cookie，确保 WebSocket 连接保持在同一 Pod
- **Deregistration delay**: 60秒，允许 WebSocket 优雅关闭
- **Load balancing**: least_outstanding_requests 算法，适合长连接

**验证**:
```bash
kubectl get ingress openclaw-<user_id> -n openclaw-<user_id> \
  -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/target-group-attributes}'
```

---

### 3. IAM 权限修复

**问题**: AWS Load Balancer Controller 缺少 `SetRulePriorities` 权限

**错误日志**:
```
User: arn:aws:sts::970547376847:assumed-role/eksctl-test-s4-addon-iamserviceaccount-kube-s-Role1-lW44L947ywT1/...
is not authorized to perform: elasticloadbalancing:SetRulePriorities
```

**解决方案**:
```bash
# 更新 IAM Policy: AWSLoadBalancerControllerIAMPolicy
# 添加权限: elasticloadbalancing:SetRulePriorities

# 已应用到策略版本 v4
```

**更新的 Policy Statement**:
```json
{
  "Effect": "Allow",
  "Action": [
    "elasticloadbalancing:CreateListener",
    "elasticloadbalancing:DeleteListener",
    "elasticloadbalancing:CreateRule",
    "elasticloadbalancing:DeleteRule",
    "elasticloadbalancing:SetRulePriorities",  // 新增
    "elasticloadbalancing:DescribeListenerAttributes",
    "elasticloadbalancing:DescribeTargetGroupAttributes"
  ],
  "Resource": "*"
}
```

**验证**:
```bash
# Ingress 创建成功，无权限错误
kubectl describe ingress openclaw-<user_id> -n openclaw-<user_id>
# Events:
#   Type    Reason                  Age   From     Message
#   ----    ------                  ----  ----     -------
#   Normal  SuccessfullyReconciled  XXs   ingress  Successfully reconciled
```

---

### 4. RBAC 权限配置

**文件**: `kubernetes/rbac.yaml`

**更新**: 添加 Ingress 管理权限给 Provisioning Service

```yaml
rules:
  # Ingress (for keeper ingress management)
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["create", "get", "list", "update", "patch"]
```

**应用**:
```bash
kubectl apply -f kubernetes/rbac.yaml
```

---

### 5. API Gateway WebSocket 集成

**集成 ID**: `p5a92ng`

**配置**:
```json
{
  "IntegrationType": "HTTP_PROXY",
  "IntegrationUri": "arn:aws:elasticloadbalancing:us-west-2:970547376847:listener/app/k8s-openclawsharedins-1304d94a5a/...",
  "ConnectionType": "VPC_LINK",
  "ConnectionId": "kn1heg",
  "PayloadFormatVersion": "1.0"
}
```

**路由配置**:
- `ANY /instance/{user_id}/{proxy+}` → Integration `p5a92ng`
- `ANY /instance/{user_id}` → Integration `p5a92ng` (新增，处理根路径)

---

### 6. 共享 ALB 配置

**ALB DNS**: `internal-k8s-openclawsharedins-1304d94a5a-1639559302.us-west-2.elb.amazonaws.com`

**Listener Rules**:
| Priority | Path Pattern | Target Group |
|----------|--------------|--------------|
| 1 | `/instance/416e0b5f` | openclaw-416e0b5f (Port 18790) |
| 2 | `/_alb_healthcheck` | openclaw-provisioning (Port 8080) |
| default | - | Fixed response 404 |

**Target Group 健康状态**:
```bash
# Target 172.31.0.32:18790 - healthy
```

---

### 7. 部署自动化脚本

**文件**: `scripts/setup-websocket-routing.sh`

**功能**:
- 自动获取共享 ALB Listener ARN
- 创建或重用 WebSocket integration
- 更新 API Gateway 路由
- 验证配置正确性

**使用**:
```bash
cd eks-pod-service/scripts
./setup-websocket-routing.sh
```

---

## 🔄 当前问题

### Issue #1: API Gateway → ALB 返回 404

**症状**:
```bash
curl "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/instance/416e0b5f/?token=..."
# {"message":"Internal Server Error"}  或  HTTP 404
```

**已验证正常的部分**:
1. ✅ **集群内访问 ALB**:
   ```bash
   curl "http://internal-k8s-openclawsharedins-1304d94a5a-..../instance/416e0b5f/?token=..."
   # 返回 OpenClaw HTML (正常)
   ```

2. ✅ **直接访问 OpenClaw Service**:
   ```bash
   curl "http://openclaw-416e0b5f.openclaw-416e0b5f.svc:18789/?token=..."
   # 返回 OpenClaw HTML (正常)
   ```

3. ✅ **VPC Link 状态**: `AVAILABLE`

4. ✅ **ALB Target 健康**: `healthy`

5. ✅ **API Gateway → Provisioning Service**:
   ```bash
   curl "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/health"
   # {"status":"healthy","k8s_api":"connected"} (正常)
   ```

**可能的原因**:

1. **路径匹配问题**:
   - API Gateway 路由: `ANY /instance/{user_id}/{proxy+}`
   - ALB Listener Rule: `/instance/416e0b5f` (PathType: Prefix)
   - 实际请求路径: `/instance/416e0b5f/`
   - 可能的不匹配导致 404

2. **集成配置问题**:
   - Integration Uri 指向正确的 Listener ARN?
   - PayloadFormatVersion 是否正确?
   - 是否需要特殊的 header 转发配置?

3. **网络/安全组问题**:
   - VPC Link Security Groups
   - ALB Security Groups
   - 可能只允许特定来源的流量?

**调试信息**:
```bash
# 测试 API Gateway 返回
curl -v "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/instance/416e0b5f/?token=..."
# < HTTP/2 404
# < server: awselb/2.0  ← 响应来自 ALB，说明网络通了
# < content-length: 0
```

这表明：
- ✅ API Gateway → VPC Link → ALB 的网络连接正常
- ❌ ALB 找不到匹配的 Listener Rule

---

## 📋 待办事项

### 高优先级

- [ ] **调试 API Gateway → ALB 路由问题**
  - 检查路径匹配规则
  - 验证 Integration 配置
  - 测试不同的路径格式

- [ ] **测试 WebSocket 连接**
  ```javascript
  const ws = new WebSocket("wss://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/instance/416e0b5f/?token=...");
  ```

- [ ] **验证 OpenClaw status 显示 online**

### 中优先级

- [ ] **创建第二个测试用户**
  - 验证多租户隔离
  - 确认共享 ALB 正常工作

- [ ] **性能测试**
  - WebSocket 连接稳定性
  - 长时间连接测试
  - 多用户并发测试

- [ ] **监控和告警**
  - CloudWatch 日志分析
  - ALB metrics
  - Target Group 健康检查

### 低优先级

- [ ] **文档完善**
  - 添加架构图
  - 更新故障排查指南
  - 编写运维手册

- [ ] **自动化改进**
  - 集成到 CI/CD
  - Terraform/CDK 配置
  - 自动化测试脚本

---

## 🔍 调试命令速查

### 检查 Ingress 状态
```bash
# Keeper ingress
kubectl get ingress openclaw-instances-keeper -n openclaw-provisioning
kubectl describe ingress openclaw-instances-keeper -n openclaw-provisioning

# 用户 ingress
kubectl get ingress openclaw-<user_id> -n openclaw-<user_id>
kubectl describe ingress openclaw-<user_id> -n openclaw-<user_id>
```

### 检查 ALB 配置
```bash
# 获取 ALB ARN
SHARED_ALB_DNS="internal-k8s-openclawsharedins-1304d94a5a-1639559302.us-west-2.elb.amazonaws.com"
SHARED_ALB_ARN=$(aws elbv2 describe-load-balancers --region us-west-2 \
  --query "LoadBalancers[?DNSName=='$SHARED_ALB_DNS'].LoadBalancerArn" --output text)

# 检查 Listener Rules
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$SHARED_ALB_ARN" \
  --region us-west-2 --query 'Listeners[0].ListenerArn' --output text)
aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" --region us-west-2

# 检查 Target 健康
TG_ARN="arn:aws:elasticloadbalancing:us-west-2:970547376847:targetgroup/k8s-openclaw-openclaw-94245ad9ec/ede2b9b392af980c"
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region us-west-2
```

### 检查 API Gateway 配置
```bash
# 查看所有路由
aws apigatewayv2 get-routes --api-id 0qu1ls4sf5 --region us-west-2

# 查看特定 integration
aws apigatewayv2 get-integration --api-id 0qu1ls4sf5 \
  --integration-id p5a92ng --region us-west-2

# 查看 VPC Link
aws apigatewayv2 get-vpc-link --vpc-link-id kn1heg --region us-west-2
```

### 测试连接
```bash
# 从集群内测试 ALB
kubectl run test-alb --rm -it --image=curlimages/curl:latest --restart=Never -- \
  curl "http://$SHARED_ALB_DNS/instance/416e0b5f/?token=..."

# 测试 API Gateway
curl "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/instance/416e0b5f/?token=..."

# 测试 OpenClaw Service
kubectl run test-svc --rm -it --image=curlimages/curl:latest --restart=Never -- \
  curl "http://openclaw-416e0b5f.openclaw-416e0b5f.svc:18789/?token=..."
```

### 查看日志
```bash
# Provisioning Service
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=100

# OpenClaw instance
kubectl logs -n openclaw-<user_id> openclaw-<user_id>-0 -c openclaw --tail=100

# ALB Controller
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=100
```

---

## 📊 架构总览

### 当前架构（部分工作）

```
用户浏览器
    ↓
API Gateway HTTP API (0qu1ls4sf5)
    ├─ /provision, /status, /delete → Provisioning Service ✅
    └─ /instance/{user_id}/* → Shared ALB ❌ (404)
        ↓
VPC Link (kn1heg) ✅
    ↓
Shared ALB (openclaw-shared-instances) ✅
    ├─ Listener Rule 1: /instance/416e0b5f → Target Group (healthy) ✅
    └─ Listener Rule 2: /_alb_healthcheck → Provisioning Service ✅
        ↓
OpenClaw Instance Service (18789 → 18790) ✅
    ↓
OpenClaw Pod (gateway-proxy + openclaw containers) ✅
```

### 工作的路径

```
✅ 集群内部访问:
   Pod → ALB → Target Group → OpenClaw Service → OpenClaw Pod

✅ API Gateway → Provisioning Service:
   Browser → API Gateway → VPC Link → Prov ALB → Provisioning Service
```

### 不工作的路径

```
❌ API Gateway → Instances ALB:
   Browser → API Gateway → VPC Link → Shared ALB → ??? (404)
```

---

## 💡 可能的解决方案

### 方案 A: 继续调试 API Gateway 集成（推荐）

**优点**:
- 最优架构（统一入口）
- 原生 WebSocket 支持
- 最低成本

**下一步**:
1. 对比 working integration (Provisioning) 和 non-working integration (Instances)
2. 检查路径转发配置
3. 测试不同的 Integration 参数
4. 查看 API Gateway 和 ALB 的详细日志

### 方案 B: 回退到 Provisioning Service Proxy

**优点**:
- 已有代码（`app/api/proxy.py`）
- 路径处理简单
- 快速恢复功能

**缺点**:
- ❌ Python requests 不支持 WebSocket
- 需要另找 WebSocket 解决方案

### 方案 C: 使用 Nginx Reverse Proxy

在 Provisioning Service 中添加 Nginx sidecar，专门处理 WebSocket：

**优点**:
- Nginx 原生支持 WebSocket
- 可以做路径重写
- 性能好

**缺点**:
- 增加复杂度
- 需要额外的容器

### 方案 D: 使用 NLB 代替 ALB

**优点**:
- NLB 支持 TCP 透传，WebSocket 无问题
- 更简单的路由

**缺点**:
- 失去 ALB 的路径路由能力
- 需要重新设计架构

---

## 📚 相关文档

- [WebSocket Setup Guide](./WEBSOCKET-SETUP.md) - WebSocket 配置完整指南
- [API Gateway Setup](./API-GATEWAY-SETUP.md) - API Gateway 一次性配置
- [Provisioning Service README](../README.md) - 项目总览

---

## 🔄 更新日志

| 日期 | 更新内容 | 作者 |
|------|----------|------|
| 2026-03-03 | 初始版本 - 记录部署进度和当前问题 | Claude Code |

---

**维护者**: OpenClaw Team
**最后更新**: 2026-03-03 12:50 UTC
