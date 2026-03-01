# OpenClaw Multi-Tenant Architecture

## 整体架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Internet Users                                  │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │
                                 │ HTTPS
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Amazon API Gateway                                  │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  Cognito User Pool Authorizer                                        │   │
│  │  - 验证 JWT Token                                                     │   │
│  │  - 提取 user attributes (email, sub)                                 │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  API 端点:                                                                   │
│  - POST   /provision        (创建实例)                                       │
│  - GET    /status/{user_id} (查询状态)                                       │
│  - DELETE /delete/{user_id} (删除实例)                                       │
│                                                                              │
│  请求增强 (Mapping Template):                                                │
│  - Headers: X-User-Email    = $context.authorizer.claims.email             │
│  - Headers: X-Cognito-Sub   = $context.authorizer.claims.sub               │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │
                                 │ HTTP + Headers
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      AWS Network Load Balancer (NLB)                        │
│                   或 Application Load Balancer (ALB)                         │
│                                                                              │
│  选择建议:                                                                   │
│  - ALB: 推荐，支持 HTTP headers, path routing                               │
│  - NLB: 性能更好，但不支持 HTTP layer                                        │
│                                                                              │
│  DNS: openclaw-provisioning-lb-xxx.us-west-2.elb.amazonaws.com             │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │
                                 │ 负载均衡
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           EKS Cluster (test-s4)                             │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────┐    │
│  │           Namespace: openclaw-provisioning                         │    │
│  │                                                                    │    │
│  │  ┌──────────────────────────────────────────────────────────┐     │    │
│  │  │  Provisioning Service Deployment (2 replicas)            │     │    │
│  │  │  - Flask REST API                                        │     │    │
│  │  │  - 运行在 Graviton nodes (ARM64)                         │     │    │
│  │  │                                                          │     │    │
│  │  │  逻辑:                                                    │     │    │
│  │  │  1. 从 Headers 读取 X-User-Email / X-Cognito-Sub        │     │    │
│  │  │  2. 生成 user_id = SHA256(email.lower())[:8]            │     │    │
│  │  │  3. 创建 K8s 资源:                                       │     │    │
│  │  │     - Namespace: openclaw-{user_id}                     │     │    │
│  │  │     - ResourceQuota                                     │     │    │
│  │  │     - NetworkPolicy                                     │     │    │
│  │  │     - OpenClawInstance CRD                              │     │    │
│  │  │  4. 返回 gateway_endpoint                               │     │    │
│  │  └──────────────────────────────────────────────────────────┘     │    │
│  │                                                                    │    │
│  │  Service: openclaw-provisioning-lb (LoadBalancer)                 │    │
│  │  - Port 80 → Pod 8080                                             │    │
│  └────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│                                 │                                            │
│                                 │ K8s API                                    │
│                                 ▼                                            │
│  ┌────────────────────────────────────────────────────────────────────┐    │
│  │           Namespace: openclaw-operator-system                      │    │
│  │                                                                    │    │
│  │  ┌──────────────────────────────────────────────────────────┐     │    │
│  │  │  OpenClaw Operator                                       │     │    │
│  │  │  - 监听 OpenClawInstance CRD                              │     │    │
│  │  │  - 创建 StatefulSet, Service, PVC, ConfigMap, etc.       │     │    │
│  │  │  - 运行在 Graviton nodes (ARM64)                         │     │    │
│  │  └──────────────────────────────────────────────────────────┘     │    │
│  └────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│                                 │                                            │
│                                 │ 创建资源                                    │
│                                 ▼                                            │
│  ┌────────────────────────────────────────────────────────────────────┐    │
│  │   Per-User Namespaces: openclaw-{user_id}                         │    │
│  │                                                                    │    │
│  │   User 1: openclaw-a744863d                                       │    │
│  │   ├── StatefulSet: openclaw-a744863d-0                            │    │
│  │   │   └── Runtime: runc (标准容器)                                 │    │
│  │   ├── Service: openclaw-a744863d:18789 (Gateway)                  │    │
│  │   ├── PVC: openclaw-a744863d-data (10Gi gp3)                      │    │
│  │   └── ConfigMap, Secrets, NetworkPolicy                           │    │
│  │                                                                    │    │
│  │   User 2: openclaw-66944be4                                       │    │
│  │   ├── StatefulSet: openclaw-66944be4-0                            │    │
│  │   ├── Service: openclaw-66944be4:18789                            │    │
│  │   └── ...                                                         │    │
│  │                                                                    │    │
│  │   User N: openclaw-xxxxxxxx                                       │    │
│  │   └── ...                                                         │    │
│  └────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                 │
                                 │ Bedrock API Calls
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Amazon Bedrock Service                              │
│                                                                              │
│  Model: us.anthropic.claude-sonnet-4-5-20250929-v1:0                        │
│  认证: AWS Credentials (Secret: aws-credentials)                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 关键组件说明

### 1. **API Gateway + Cognito**

**功能：**
- 用户认证和授权
- JWT token 验证
- 提取 user attributes 注入 headers
- 限流、监控、日志

**配置：**
```yaml
Cognito User Pool:
  - User attributes: email, sub
  - JWT 有效期: 1 hour

API Gateway:
  - Authorizer: Cognito User Pool
  - Request Mapping:
      Headers:
        X-User-Email: $context.authorizer.claims.email
        X-Cognito-Sub: $context.authorizer.claims.sub
```

### 2. **Load Balancer**

**推荐方案：ALB (Application Load Balancer)**

**原因：**
- ✅ 支持 HTTP headers (X-User-Email, X-Cognito-Sub)
- ✅ 支持 path-based routing
- ✅ 支持健康检查 (GET /health)
- ✅ 集成 API Gateway

**替代方案：NLB (Network Load Balancer)**
- ✅ 性能更好 (Layer 4)
- ❌ 不支持 HTTP headers
- ❌ 需要 API Gateway 直接连接 Pod IP (复杂)

**配置：**
```yaml
Service Type: LoadBalancer
Annotations:
  - aws-load-balancer-type: external
  - aws-load-balancer-nlb-target-type: ip
  - aws-load-balancer-healthcheck-path: /health
```

### 3. **Provisioning Service**

**部署：**
- Namespace: `openclaw-provisioning`
- Replicas: 2 (高可用)
- 节点: Graviton (ARM64) via Karpenter
- 镜像: 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest

**API 端点：**
| 方法 | 路径 | 功能 | 认证 |
|------|------|------|------|
| POST | /provision | 创建 OpenClaw 实例 | Cognito (via API Gateway) |
| GET | /status/{user_id} | 查询实例状态 | Cognito |
| DELETE | /delete/{user_id} | 删除实例 | Cognito |
| GET | /health | 健康检查 | 无需认证 |

**请求流程：**
1. 从 Headers 读取 `X-User-Email` 和 `X-Cognito-Sub`
2. 生成 `user_id = SHA256(email.lower())[:8]`
3. 创建 Namespace `openclaw-{user_id}`
4. 创建 ResourceQuota, NetworkPolicy
5. 创建 OpenClawInstance CRD
6. 返回 `gateway_endpoint`

### 4. **OpenClaw Operator**

**功能：**
- 监听 OpenClawInstance CRD 变化
- 创建 StatefulSet, Service, PVC, ConfigMap, Secrets
- 管理 OpenClaw 生命周期

**部署：**
- Namespace: `openclaw-operator-system`
- Replicas: 1
- 节点: Graviton (ARM64)

### 5. **Per-User OpenClaw Instances**

**隔离：**
- 每个用户独立 Namespace: `openclaw-{user_id}`
- 独立 ResourceQuota (CPU, Memory, Storage)
- 独立 NetworkPolicy (只允许必要流量)

**资源配置：**
```yaml
Resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 2
    memory: 4Gi

Storage:
  - PVC: openclaw-{user_id}-data
  - Size: 10Gi
  - StorageClass: gp3

Runtime:
  - runtimeClassName: null (runc, 标准容器)
  - nodeSelector: {} (任意节点)
```

## 数据流

### 创建实例流程

```
1. 用户登录 Cognito
   ↓ JWT Token

2. 调用 API Gateway
   POST https://api.example.com/provision
   Authorization: Bearer <token>
   ↓

3. API Gateway 验证 Token
   ↓ 提取 email, sub
   ↓ 注入 Headers:
     X-User-Email: user@example.com
     X-Cognito-Sub: xxx-xxx-xxx

4. 转发到 ALB
   ↓ 负载均衡

5. Provisioning Service 处理
   ↓ 生成 user_id = a744863d
   ↓ 创建 K8s 资源:
     - Namespace: openclaw-a744863d
     - ResourceQuota
     - NetworkPolicy
     - OpenClawInstance CRD

6. OpenClaw Operator 响应
   ↓ 创建实际资源:
     - StatefulSet: openclaw-a744863d-0
     - Service: openclaw-a744863d:18789
     - PVC: openclaw-a744863d-data
     - ConfigMap, Secrets

7. 返回响应
   {
     "status": "created",
     "user_id": "a744863d",
     "gateway_endpoint": "openclaw-a744863d.openclaw-a744863d.svc:18789"
   }
```

### 查询状态流程

```
1. 用户调用 API Gateway
   GET https://api.example.com/status/{user_id}
   Authorization: Bearer <token>
   ↓

2. API Gateway 验证 Token
   ↓ 转发到 ALB → Provisioning Service

3. Provisioning Service 查询 K8s
   ↓ 获取 OpenClawInstance CRD status
   ↓ 获取 Pod 状态

4. 返回响应
   {
     "user_id": "a744863d",
     "namespace": "openclaw-a744863d",
     "status": {
       "phase": "Running",
       "conditions": [...]
     },
     "pods": [...]
   }
```

## 安全性

### 1. **认证和授权**
- ✅ Cognito User Pool 管理用户
- ✅ API Gateway Authorizer 验证 JWT
- ✅ Provisioning Service 从可信 headers 读取用户信息

### 2. **网络隔离**
- ✅ 每个用户独立 Namespace
- ✅ NetworkPolicy 限制跨 Namespace 通信
- ✅ 只开放必要端口 (Gateway: 18789)

### 3. **资源隔离**
- ✅ ResourceQuota 限制每用户资源
- ✅ PodSecurityContext (runAsNonRoot)
- ✅ 容器 SecurityContext (drop ALL capabilities)

### 4. **数据隔离**
- ✅ 独立 PVC per user
- ✅ 独立 ConfigMap, Secrets
- ✅ OpenClaw 数据存储在独立 PV

## 扩展性

### 当前配置 (测试环境)
- Provisioning Service: 2 replicas
- 预期用户数: < 100
- 每用户资源: 500m CPU, 1Gi Memory

### 生产环境建议 (15万用户)
- Provisioning Service: 10+ replicas (HPA)
- 分层架构:
  - **Hot tier** (20%): Kata Containers on c6g.metal
  - **Warm tier** (30%): runc on standard nodes
  - **Cold tier** (50%): Fargate (按需启动)

参考：[LARGE-SCALE-ARCHITECTURE.md](../../api-gateway-solution/LARGE-SCALE-ARCHITECTURE.md)

## 监控和日志

### CloudWatch Metrics
- API Gateway: Request count, Latency, 4xx/5xx errors
- ALB: Target health, Request count, Response time
- Provisioning Service: Health check status
- OpenClaw Instances: Pod metrics (CPU, Memory)

### 日志
- API Gateway → CloudWatch Logs
- ALB Access Logs → S3
- Provisioning Service → JSON logs → CloudWatch
- OpenClaw Pods → JSON logs → CloudWatch (Fluent Bit)

## 成本估算 (测试环境)

| 组件 | 配置 | 月成本 (USD) |
|------|------|--------------|
| API Gateway | 100K requests/month | $3.50 |
| NLB/ALB | 1 instance | $16-23 |
| EKS Control Plane | 1 cluster | $73 |
| Provisioning Service | 2x t4g.medium | ~$30 |
| OpenClaw Instances | 10 users @ t4g.small | ~$150 |
| EBS gp3 | 100Gi total | $8 |
| **Total** | | **~$280-290/月** |

## 部署清单

### 已完成 ✅
- [x] EKS Cluster (test-s4)
- [x] OpenClaw Operator
- [x] Provisioning Service (Flask API)
- [x] Karpenter Graviton NodePool
- [x] RBAC, Deployment, Service, HPA

### 待完成 ⏳
- [ ] LoadBalancer Service (ALB)
- [ ] Cognito User Pool
- [ ] API Gateway + Cognito Authorizer
- [ ] Provisioning Service 支持 Header 认证
- [ ] 集成测试 (multi-tenant)
- [ ] 监控和告警

## 下一步

1. 部署 LoadBalancer (ALB)
2. 创建 Cognito User Pool
3. 配置 API Gateway
4. 修改 Provisioning Service 支持 Headers
5. 端到端测试

---

**维护者**: Claude Code
**最后更新**: 2026-03-01
