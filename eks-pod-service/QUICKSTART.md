# CloudFront 集成快速执行指南

## 当前状态

✅ **Phase 1 已完成** (2026-03-07)
- Provisioning Service 已成功加入共享 Public ALB
- ALB 规则配置正确
- 所有测试通过

## 快速执行

### Phase 2: 更新 CloudFront（预计 15 分钟）

```bash
cd open-claw-operator-on-EKS-kata/eks-pod-service

# 执行更新脚本（会提示确认）
bash scripts/update-cloudfront-phase2.sh
```

**脚本功能**:
- ✅ 自动备份当前配置
- ✅ 添加 7 个新 Cache Behaviors (provisioning service 路由)
- ✅ 预览变更并确认
- ✅ 应用更新
- ✅ 监控部署状态

**部署时间**: 5-10 分钟

**等待部署完成**:
```bash
# 实时监控
watch -n 10 'aws cloudfront get-distribution --id EXXXXXXXXXXXXX --query Distribution.Status --output text'

# 或一次性等待
aws cloudfront wait distribution-deployed --id EXXXXXXXXXXXXX
```

---

### Phase 3: 测试验证（预计 5 分钟）

**等待 CloudFront Status = Deployed 后执行**:

```bash
cd open-claw-operator-on-EKS-kata/eks-pod-service

# 执行测试脚本
bash scripts/test-cloudfront-phase3.sh
```

**测试覆盖**:
- ✅ 静态资源缓存
- ✅ 登录/Dashboard 页面
- ✅ API 端点路由
- ✅ OpenClaw instance 路由
- ✅ CloudFront 响应头

---

## 预期效果

| 指标 | API Gateway | CloudFront | 改善 |
|------|-------------|------------|------|
| 延迟 (p50) | ~200ms | ~60-80ms | **2.5-3x** ⬆ |
| 成本 (月) | ~$75 | $0 | **节省 100%** |
| 架构复杂度 | 高 (双 ALB) | 低 (统一 ALB) | **简化** |

---

**详细文档**: [CLOUDFRONT-PROVISIONING-INTEGRATION.md](./CLOUDFRONT-PROVISIONING-INTEGRATION.md)

**脚本位置**: `scripts/`
- `verify-phase1-alb.sh` - Phase 1 验证（已完成）
- `update-cloudfront-phase2.sh` - Phase 2 更新
- `test-cloudfront-phase3.sh` - Phase 3 测试
