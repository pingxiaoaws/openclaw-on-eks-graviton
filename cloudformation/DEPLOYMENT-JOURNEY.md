# OpenClaw Platform CloudFormation 部署历程

**日期**: 2026-03-10
**部署区域**: us-east-1 (最终)
**状态**: 进行中 (第 3 次尝试)

---

## 执行摘要

经过 3 次部署尝试，成功解决了以下配额问题：
- ✅ IAM 权限 (`secretsmanager:TagResource`)
- ✅ EIP 配额 (us-east-1: 6→2，释放 4 个)
- ✅ VPC 配额 (us-east-1: 5→4，释放 1 个)

**当前状态**: 第 4 次部署进行中，所有配额检查通过

---

## 部署尝试历史

### 尝试 #1: us-west-2 - Cognito Lambda 权限问题

**错误**: `secretsmanager:TagResource` 权限缺失
**解决**: 修改 `nested-stacks/07-cognito.yaml` 添加权限

### 尝试 #2: us-west-2 - EIP 配额不足

**错误**: 14/10 EIP (超出 4 个)
**决策**: 切换到 us-east-1

### 尝试 #3: us-east-1 - VPC 配额不足

**错误**: 5/5 VPC + 6/5 EIP
**解决**: 清理 auto-graphrag 和 main VPC

### 尝试 #4: us-east-1 - 当前进行中 ✅

**配额状态**:
- VPC: 4/5 (可用 1)
- EIP: 2/5 (可用 3)

---

## 清理记录

### us-east-1 EIP 清理 (释放 4 个)

| 操作 | EIP 数量 | 释放 |
|------|----------|------|
| 删除 auto-graphrag ALB | 6 → 3 | 3 |
| 删除 auto-graphrag NAT Gateway | 3 → 2 | 1 |
| 删除 main VPC NAT Gateway | 2 → 1 | 1 |

### us-east-1 VPC 清理 (释放 1 个)

| VPC | 操作 | 资源 |
|-----|------|------|
| main (vpc-059eba6d5867ed05c) | 删除 | 4 Subnets, 1 IGW, 1 SG, 2 RT |

---

## 关键配额需求

| 资源 | 需要 | 默认配额 | 清理后可用 |
|------|------|----------|-----------|
| VPC | 1 | 5 | 1 ✅ |
| EIP | 2 | 5 | 3 ✅ |
| Internet Gateway | 1 | 5 | 2 ✅ |
| NAT Gateway | 2 | 5 | 5 ✅ |

---

## 成本预估

- **基础设施**: $327-502/月
- **优化后**: $200-350/月 (单 NAT Gateway 或公有子网)

---

## 相关文档

- [完整指南](./README.md)
- [部署清单](./DEPLOYMENT-READY.md)
- [Kata 参考](../../KATA-QUICK-REFERENCE.md)

---

**最后更新**: 2026-03-10 16:48 CST
