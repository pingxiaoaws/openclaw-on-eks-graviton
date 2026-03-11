# CloudFront 集成 Provisioning Service 完整指南

## 概述

将 Provisioning Service 从 API Gateway + Internal ALB 迁移到 CloudFront + 共享 Public ALB，实现：

- ✅ **降低成本**: 节省 $72/月 (VPC Link) + API Gateway 请求费用
- ✅ **架构统一**: 与 OpenClaw instances 使用相同的 ALB
- ✅ **性能提升**: 减少一跳延迟 (去掉 API Gateway)
- ✅ **保留备份**: API Gateway 保持在线，可快速回滚

## 架构对比

### 旧架构（当前）
```
User → API Gateway (xxxxxxxxxx)
     ↓ VPC Link ($72/月)
     → Internal ALB
     → Provisioning Pod
```

### 新架构（目标）
```
User → CloudFront (EXXXXXXXXXXXXX)
     → 共享 Public ALB (k8s-openclawsharedins-df8a132590)
     → Provisioning Pod

备份: API Gateway → Internal ALB → Provisioning Pod (保留)
```

## 实施步骤

### Phase 1: ALB 集成 ✅

**目标**: 将 Provisioning Service 加入共享 Public ALB

**执行**:
```bash
cd open-claw-operator-on-EKS-kata/eks-pod-service

# 1. 应用新的 Ingress 配置
kubectl apply -f kubernetes/ingress-public-alb.yaml

# 2. 验证集成
bash scripts/verify-phase1-alb.sh
```

**验证要点**:
- ✅ Ingress 创建成功，加入 `openclaw-shared-instances` ALB group
- ✅ ALB 自动添加 Provisioning Service 路由规则
- ✅ Target Groups 健康检查通过
- ✅ ALB 直连测试成功（带 Host header）
- ✅ OpenClaw instance 路由不受影响

**已完成**: 2026-03-07

---

### Phase 2: CloudFront 配置更新

**目标**: 为 Provisioning Service 添加 CloudFront Cache Behaviors

**准备**:
1. 确认 Phase 1 测试通过
2. 备份当前 CloudFront 配置（脚本自动完成）

**执行**:
```bash
cd open-claw-operator-on-EKS-kata/eks-pod-service

# 更新 CloudFront Distribution
bash scripts/update-cloudfront-phase2.sh
```

**添加的 Cache Behaviors** (按优先级):

| 优先级 | PathPattern | 缓存策略 | 说明 |
|--------|-------------|----------|------|
| 1 | `/static/*` | Caching Optimized | 静态资源，缓存 1 天 |
| 2 | `/login*` | Caching Disabled | 登录页面，不缓存，转发 cookies |
| 3 | `/dashboard*` | Caching Disabled | Dashboard，不缓存，转发 cookies |
| 4 | `/provision*` | Caching Disabled | API，不缓存，转发 Authorization header |
| 5 | `/status/*` | Caching Disabled | API，不缓存，转发 Authorization header |
| 6 | `/delete/*` | Caching Disabled | API，不缓存，转发 Authorization header |
| 7 | `/api/*` | Caching Disabled | API，不缓存，转发 Authorization header |

**部署时间**: 5-10 分钟

**监控部署**:
```bash
# 实时监控
watch -n 10 'aws cloudfront get-distribution --id EXXXXXXXXXXXXX --query Distribution.Status --output text'

# 或等待完成
aws cloudfront wait distribution-deployed --id EXXXXXXXXXXXXX
```

---

### Phase 3: 功能测试

**目标**: 验证 CloudFront 集成功能正常

**前提**: Phase 2 部署完成（Status = Deployed）

**执行**:
```bash
cd open-claw-operator-on-EKS-kata/eks-pod-service

# 综合测试
bash scripts/test-cloudfront-phase3.sh
```

**测试覆盖**:
1. ✅ 静态资源缓存（`X-Cache: Hit from cloudfront`）
2. ✅ 登录/Dashboard 页面可访问
3. ✅ API 端点正确拒绝未认证请求（401/403）
4. ✅ OpenClaw instance 路由正常
5. ✅ CloudFront 响应头正确

**端到端测试** (需要真实 JWT token):
```bash
# 1. 获取 Cognito JWT token
TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id xxxxxxxxxxxxxxxxxxxxxxxxxx \
  --auth-parameters USERNAME=<email>,PASSWORD=<password> \
  --region us-west-2 \
  --query 'AuthenticationResult.IdToken' \
  --output text)

# 2. 测试 provision
curl -X POST https://dxxxexample.cloudfront.net/provision \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json"

# 3. 检查 instance 状态
curl https://dxxxexample.cloudfront.net/status/<user_id> \
  -H "Authorization: Bearer $TOKEN"

# 4. 删除 instance
curl -X DELETE https://dxxxexample.cloudfront.net/delete/<user_id> \
  -H "Authorization: Bearer $TOKEN"
```

---

### Phase 4: 监控和对比

**CloudFront 指标监控**:
```bash
# 查看 CloudFront 指标
aws cloudwatch get-metric-statistics \
  --namespace AWS/CloudFront \
  --metric-name Requests \
  --dimensions Name=DistributionId,Value=EXXXXXXXXXXXXX \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 3600 \
  --statistics Sum \
  --region us-east-1  # CloudFront 指标在 us-east-1
```

**性能对比**:

| 指标 | API Gateway | CloudFront | 改善 |
|------|-------------|------------|------|
| 延迟 (p50) | ~200ms | ~60-80ms | 2.5-3x ⬆ |
| 延迟 (p99) | ~800ms | ~150-200ms | 4-5x ⬆ |
| 成本 (VPC Link) | $72/月 | $0 | 节省 100% |
| 成本 (请求) | $1/百万 | $0 (共享) | 节省 100% |

**Cache Hit Rate** (静态资源):
- 目标: > 80%
- 实际监控: CloudWatch → CacheHitRate 指标

---

### Phase 5: 切换流量（可选）

**前提**: Phase 3 测试通过，稳定运行 1-2 天

**前端 URL 更新** (如果需要):
```javascript
// eks-pod-service/app/static/js/auth.js
// 修改 API_BASE_URL
const API_BASE_URL = 'https://dxxxexample.cloudfront.net';
```

**重新构建镜像**:
```bash
cd eks-pod-service

# Build and push
docker build -t 111122223333.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest .
docker push 111122223333.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest

# Restart deployment
kubectl rollout restart deployment openclaw-provisioning -n openclaw-provisioning
```

**渐进式切换**:
1. 先在 Dashboard 页面切换（低风险）
2. 观察 1 天，监控错误率
3. 切换 API 端点（provision/status/delete）
4. 全部切换后观察 1 周

---

## 回滚计划

### 快速回滚（Phase 2/3 出问题）

**恢复到 API Gateway**:
```bash
# 前端 URL 改回 API Gateway（如果已修改）
# eks-pod-service/app/static/js/auth.js
const API_BASE_URL = 'https://xxxxxxxxxx.execute-api.us-west-2.amazonaws.com/prod';

# 重新部署
kubectl rollout restart deployment openclaw-provisioning -n openclaw-provisioning
```

**说明**: API Gateway 和 Internal ALB 一直在线，无需额外配置

### 恢复 CloudFront 配置

```bash
# 使用备份文件恢复
BACKUP_FILE="/tmp/cloudfront-config-backup-<timestamp>.json"
ETAG=$(jq -r '.ETag' "$BACKUP_FILE")

aws cloudfront update-distribution \
  --id EXXXXXXXXXXXXX \
  --distribution-config "file://<(jq '.DistributionConfig' $BACKUP_FILE)" \
  --if-match "$ETAG"
```

---

## 清理旧资源（未来）

**前提**: CloudFront 稳定运行 2-4 周，确认无问题

**删除 API Gateway**:
```bash
# 1. 删除 API Gateway
aws apigatewayv2 delete-api --api-id xxxxxxxxxx --region us-west-2

# 2. 删除 VPC Link
VPC_LINK_ID=$(aws apigatewayv2 get-vpc-links --region us-west-2 \
  --query 'Items[?Name==`openclaw-provisioning-vpclink`].VpcLinkId' \
  --output text)
aws apigatewayv2 delete-vpc-link --vpc-link-id "$VPC_LINK_ID" --region us-west-2

# 3. 删除 Internal ALB Ingress
kubectl delete ingress openclaw-provisioning-ingress -n openclaw-provisioning
```

**成本节省**: ~$75-80/月

---

## 故障排查

### 问题 1: CloudFront 返回 403 Forbidden

**症状**:
```bash
curl https://dxxxexample.cloudfront.net/login
# HTTP 403, X-Cache: Error from cloudfront
```

**诊断**:
```bash
# 检查 Cache Behavior 配置
aws cloudfront get-distribution-config --id EXXXXXXXXXXXXX \
  --query 'DistributionConfig.CacheBehaviors.Items[].PathPattern'

# 检查 ALB 规则
aws elbv2 describe-rules --region us-west-2 \
  --listener-arn <listener-arn> | grep -A 5 "/login"
```

**可能原因**:
- Cache Behavior 未配置 `/login*` 路径
- Origin 配置错误
- CloudFront 部署未完成

**解决**:
- 重新执行 Phase 2 脚本
- 等待 CloudFront 部署完成

### 问题 2: ALB 返回 503 Service Unavailable

**症状**:
```bash
curl -H "Host: dxxxexample.cloudfront.net" http://<alb-dns>/health
# HTTP 503
```

**诊断**:
```bash
# 检查 Target Health
bash scripts/verify-phase1-alb.sh
```

**可能原因**:
- Provisioning Service Pod 不健康
- Target Group 注册失败

**解决**:
```bash
# 检查 Pod 状态
kubectl get pod -n openclaw-provisioning

# 重启 deployment
kubectl rollout restart deployment openclaw-provisioning -n openclaw-provisioning
```

### 问题 3: Instance 路由被影响

**症状**: `/instance/<user_id>/` 路由不工作

**诊断**:
```bash
# 检查 ALB 规则优先级
aws elbv2 describe-rules --region us-west-2 \
  --listener-arn <listener-arn> | grep -E "Priority|PathPattern"
```

**可能原因**: ALB 规则优先级冲突

**解决**: Instance 路由应该有更高优先级（更小的数字）

---

## 配置文件清单

| 文件 | 说明 |
|------|------|
| `kubernetes/ingress-public-alb.yaml` | Public ALB Ingress (共享 group) |
| `kubernetes/ingress.yaml` | Internal ALB Ingress (备份) |
| `scripts/verify-phase1-alb.sh` | Phase 1 验证脚本 |
| `scripts/update-cloudfront-phase2.sh` | Phase 2 更新脚本 |
| `scripts/test-cloudfront-phase3.sh` | Phase 3 测试脚本 |

---

## 关键资源 ID

| 资源 | ID/Name |
|------|---------|
| CloudFront Distribution | `EXXXXXXXXXXXXX` |
| CloudFront Domain | `dxxxexample.cloudfront.net` |
| 共享 ALB | `k8s-openclawsharedins-df8a132590` |
| ALB Group Name | `openclaw-shared-instances` |
| API Gateway (备份) | `xxxxxxxxxx` |
| Cognito User Pool | `us-west-2_ExAmPlE` |

---

## 总结

**Phase 1 (已完成)**:
- ✅ Provisioning Service 已加入共享 Public ALB
- ✅ ALB 规则自动配置
- ✅ Target Groups 健康检查通过
- ✅ 直连测试通过

**Phase 2 (待执行)**:
- 更新 CloudFront Cache Behaviors
- 等待部署完成（5-10 分钟）

**Phase 3 (待执行)**:
- 功能测试
- 端到端验证
- 性能监控

**预期效果**:
- 成本节省: $75-80/月
- 延迟改善: 2.5-3x
- 架构简化: 统一使用 CloudFront + ALB

---

**最后更新**: 2026-03-07
**状态**: Phase 1 完成，Phase 2/3 待执行
