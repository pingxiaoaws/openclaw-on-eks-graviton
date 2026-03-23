# OpenClaw Multi-Tenant 安全架构

## 🔒 安全架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Internet (公网)                             │
└────────────────────────────┬────────────────────────────────────────┘
                             │ HTTPS
                             │ 唯一公网入口
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Amazon API Gateway                             │
│  - Type: REST API                                                   │
│  - Endpoint: Regional                                               │
│  - Cognito User Pool Authorizer (JWT 验证)                          │
│  - Throttling: 10K req/sec (可调)                                   │
│  - WAF: 可选 (DDoS 防护)                                            │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             │ VPC Link (私有连接)
                             │ ⚠️ 不经过公网
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│                           AWS VPC                                   │
│                                                                     │
│  ┌────────────────────────────────────────────────────────────┐   │
│  │              VPC Link (Managed by AWS)                     │   │
│  │  - Type: VPC_LINK                                          │   │
│  │  - Target: NLB ARN                                         │   │
│  │  - 连接: API Gateway → Private Subnets                     │   │
│  └────────────────────────────────────────────────────────────┘   │
│                             │                                       │
│                             ▼                                       │
│  ┌────────────────────────────────────────────────────────────┐   │
│  │         Private Subnets (172.31.0.0/20)                    │   │
│  │                                                            │   │
│  │  ┌──────────────────────────────────────────────────┐     │   │
│  │  │  Network Load Balancer (NLB)                     │     │   │
│  │  │  - Scheme: internal ⚠️ 关键：不暴露公网           │     │   │
│  │  │  - Type: network (Layer 4)                       │     │   │
│  │  │  - Target Type: IP (EKS Pod IPs)                 │     │   │
│  │  │                                                  │     │   │
│  │  │  Security Group: nlb-provisioning-sg             │     │   │
│  │  │  Inbound Rules:                                  │     │   │
│  │  │  - Port 80 from VPC CIDR (172.31.0.0/16)        │     │   │
│  │  │  - Port 443 from VPC CIDR (可选，HTTPS)          │     │   │
│  │  │                                                  │     │   │
│  │  │  Outbound Rules:                                 │     │   │
│  │  │  - Port 8080 to provisioning-pod-sg              │     │   │
│  │  └──────────────────────────────────────────────────┘     │   │
│  │                             │                              │   │
│  └─────────────────────────────┼──────────────────────────────┘   │
│                                │                                   │
│  ┌─────────────────────────────┼──────────────────────────────┐   │
│  │         EKS Cluster (test-s4)                              │   │
│  │                             │                              │   │
│  │  Namespace: openclaw-provisioning                          │   │
│  │                             │                              │   │
│  │  ┌──────────────────────────▼────────────────────────┐    │   │
│  │  │  Provisioning Service Pods                       │    │   │
│  │  │  - 2 replicas                                    │    │   │
│  │  │  - Port: 8080                                    │    │   │
│  │  │                                                  │    │   │
│  │  │  Security Group: provisioning-pod-sg             │    │   │
│  │  │  Inbound Rules:                                  │    │   │
│  │  │  - Port 8080 from nlb-provisioning-sg            │    │   │
│  │  │  - Port 8080 from eks-control-plane-sg (健康检查) │    │   │
│  │  │                                                  │    │   │
│  │  │  Outbound Rules:                                 │    │   │
│  │  │  - Port 443 to EKS API Server                    │    │   │
│  │  │  - Port 443 to AWS API (Bedrock, etc.)          │    │   │
│  │  └──────────────────────────────────────────────────┘    │   │
│  │                             │                              │   │
│  │                             │ K8s API                      │   │
│  │                             ▼                              │   │
│  │  ┌──────────────────────────────────────────────────┐    │   │
│  │  │  OpenClaw Operator & Per-User Instances         │    │   │
│  │  │                                                  │    │   │
│  │  │  Security Group: openclaw-pod-sg                 │    │   │
│  │  │  Inbound Rules:                                  │    │   │
│  │  │  - Port 18789 from provisioning-pod-sg (Gateway) │    │   │
│  │  │  - 同 namespace 内 Pod 互访                       │    │   │
│  │  │                                                  │    │   │
│  │  │  Outbound Rules:                                 │    │   │
│  │  │  - Port 443 to AWS API (Bedrock)                │    │   │
│  │  │  - Port 443 to Internet (model downloads)       │    │   │
│  │  └──────────────────────────────────────────────────┘    │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## 🔐 安全策略

### 1. 网络安全

#### 1.1 分层防护

```
Layer 1: API Gateway (公网入口)
  ✅ Cognito 认证
  ✅ JWT 验证
  ✅ Rate limiting
  ✅ WAF (可选)
  ⚠️ 唯一暴露到公网的组件

Layer 2: VPC Link (私有连接)
  ✅ AWS 托管的私有连接
  ✅ 不经过公网
  ✅ 加密传输

Layer 3: NLB (内网负载均衡)
  ✅ internal scheme (不暴露公网)
  ✅ 私有子网部署
  ✅ 安全组限制访问源

Layer 4: EKS Pods (应用层)
  ✅ Security Groups 限制
  ✅ NetworkPolicy 隔离
  ✅ RBAC 权限控制
```

#### 1.2 安全组配置

**安全组 1: nlb-provisioning-sg**
```yaml
Name: nlb-provisioning-sg
Description: Security group for Provisioning Service NLB (internal)

Inbound Rules:
  - Type: Custom TCP
    Port: 80
    Source: 172.31.0.0/16 (VPC CIDR)
    Description: Allow HTTP from VPC (VPC Link traffic)

  - Type: Custom TCP
    Port: 443
    Source: 172.31.0.0/16
    Description: Allow HTTPS from VPC (optional)

Outbound Rules:
  - Type: Custom TCP
    Port: 8080
    Destination: provisioning-pod-sg
    Description: Forward to Provisioning Service Pods
```

**安全组 2: provisioning-pod-sg**
```yaml
Name: provisioning-pod-sg
Description: Security group for Provisioning Service Pods

Inbound Rules:
  - Type: Custom TCP
    Port: 8080
    Source: nlb-provisioning-sg
    Description: Accept traffic from NLB

  - Type: Custom TCP
    Port: 8080
    Source: eks-control-plane-sg
    Description: Health checks from EKS

Outbound Rules:
  - Type: HTTPS (443)
    Destination: 0.0.0.0/0
    Description: EKS API Server, AWS APIs (Bedrock, ECR, etc.)

  - Type: Custom TCP
    Port: 443
    Destination: eks-cluster-sg
    Description: K8s API Server
```

**安全组 3: openclaw-pod-sg**
```yaml
Name: openclaw-pod-sg
Description: Security group for OpenClaw Instance Pods

Inbound Rules:
  - Type: Custom TCP
    Port: 18789
    Source: provisioning-pod-sg
    Description: Gateway port from Provisioning Service

  - Type: All traffic
    Source: self (openclaw-pod-sg)
    Description: Allow communication within same namespace

Outbound Rules:
  - Type: HTTPS (443)
    Destination: 0.0.0.0/0
    Description: AWS APIs (Bedrock, S3, etc.)
```

### 2. 认证和授权

#### 2.1 Cognito User Pool

```yaml
User Pool Configuration:
  MFA: Optional (推荐开启)
  Password Policy:
    - Minimum length: 12
    - Require uppercase: Yes
    - Require lowercase: Yes
    - Require numbers: Yes
    - Require symbols: Yes

  User Attributes:
    - email (required, verified)
    - sub (unique identifier)
    - custom:organization (optional)

  JWT Token:
    - ID Token TTL: 1 hour
    - Access Token TTL: 1 hour
    - Refresh Token TTL: 30 days
```

#### 2.2 API Gateway Authorizer

```yaml
Authorizer Type: COGNITO_USER_POOLS
Token Source: Authorization header
Token Validation:
  - Signature verification
  - Token expiration check
  - Issuer validation

Authorization Scopes:
  - openid
  - email
  - profile

Request Mapping:
  Headers:
    X-User-Email: $context.authorizer.claims.email
    X-Cognito-Sub: $context.authorizer.claims.sub
```

### 3. 数据安全

#### 3.1 传输加密

```
✅ Internet → API Gateway: HTTPS (TLS 1.2+)
✅ API Gateway → VPC Link: AWS PrivateLink (加密)
⚠️ VPC Link → NLB → Pods: HTTP (内网，可选 HTTPS)
✅ Pods → AWS APIs: HTTPS (Bedrock, etc.)
```

**建议：** 生产环境中 NLB → Pods 也使用 HTTPS

#### 3.2 存储加密

```yaml
PersistentVolumes:
  - StorageClass: gp3
  - Encryption: EBS 加密 (AWS KMS)
  - Key: aws/ebs (默认) 或自定义 KMS key

Secrets:
  - aws-credentials: 存储在 K8s Secrets
  - Encryption at rest: EKS 集群 KMS 加密
```

### 4. Kubernetes 安全

#### 4.1 RBAC

```yaml
ServiceAccount: openclaw-provisioner
Permissions:
  - Namespaces: create, get, list, delete
  - ResourceQuotas: create, get
  - NetworkPolicies: create, get
  - OpenClawInstances (CRD): create, get, list, update, delete

⚠️ 最小权限原则：只授予必要权限
```

#### 4.2 NetworkPolicy

```yaml
# Per-user namespace isolation
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: openclaw-{user_id}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress

  ingress:
    # 只允许来自 Provisioning Service 的流量
    - from:
      - namespaceSelector:
          matchLabels:
            name: openclaw-provisioning
      ports:
      - protocol: TCP
        port: 18789

  egress:
    # 允许访问 AWS APIs
    - to:
      - namespaceSelector: {}
      ports:
      - protocol: TCP
        port: 443

    # 允许 DNS
    - to:
      - namespaceSelector: {}
      ports:
      - protocol: UDP
        port: 53
```

#### 4.3 Pod Security

```yaml
PodSecurityContext:
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault

ContainerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: false  # OpenClaw needs write access
  capabilities:
    drop:
      - ALL
```

## 📋 部署检查清单

### Phase 1: 网络和安全组

- [ ] 确认 VPC 和子网配置
- [ ] 创建安全组:
  - [ ] nlb-provisioning-sg
  - [ ] provisioning-pod-sg
  - [ ] openclaw-pod-sg
- [ ] 配置安全组规则（见上文）
- [ ] 验证安全组关联

### Phase 2: 负载均衡器

- [ ] 部署 NLB Service (internal scheme)
  ```bash
  kubectl apply -f kubernetes/service-lb.yaml
  ```
- [ ] 等待 NLB 创建完成
  ```bash
  kubectl get svc -n openclaw-provisioning -w
  ```
- [ ] 记录 NLB DNS 和 ARN
- [ ] 验证 Target Health
  ```bash
  aws elbv2 describe-target-health \
    --target-group-arn <arn>
  ```

### Phase 3: Cognito

- [ ] 创建 Cognito User Pool
- [ ] 配置密码策略
- [ ] 配置 MFA (可选)
- [ ] 创建测试用户
- [ ] 记录 User Pool ID 和 Client ID

### Phase 4: API Gateway

- [ ] 创建 VPC Link
  - Target: NLB ARN
  - Subnets: Private subnets
- [ ] 等待 VPC Link 可用 (5-10分钟)
- [ ] 创建 REST API
- [ ] 配置 Cognito Authorizer
- [ ] 创建资源和方法:
  - POST /provision
  - GET /status/{user_id}
  - DELETE /delete/{user_id}
- [ ] 配置集成 (VPC Link → NLB)
- [ ] 配置 Request Mapping (注入 Headers)
- [ ] 部署 API (创建 Stage)
- [ ] 测试 API

### Phase 5: Provisioning Service 更新

- [ ] 修改代码支持 Header 认证
  - 读取 X-User-Email
  - 读取 X-Cognito-Sub
  - 验证 Headers 存在
- [ ] 重新构建镜像
- [ ] 推送到 ECR
- [ ] 重启 Deployment

### Phase 6: 端到端测试

- [ ] 用户登录 Cognito
- [ ] 获取 JWT token
- [ ] 调用 API Gateway /provision
- [ ] 验证实例创建
- [ ] 调用 /status 查询状态
- [ ] 验证安全隔离
- [ ] 删除测试实例

## 🚨 AWS Violation 预防

### 避免的配置

❌ **错误**: NLB scheme = internet-facing
```yaml
service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
```

✅ **正确**: NLB scheme = internal
```yaml
service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
```

### 合规检查

1. **NLB 不能有公网 IP**
   ```bash
   # 验证 NLB 是否为 internal
   aws elbv2 describe-load-balancers \
     --names openclaw-provisioning-lb \
     --query 'LoadBalancers[0].Scheme'
   # 期望输出: "internal"
   ```

2. **安全组不能开放 0.0.0.0/0 (除了 Outbound HTTPS)**
   ```bash
   # 检查安全组规则
   aws ec2 describe-security-groups \
     --group-names nlb-provisioning-sg \
     --query 'SecurityGroups[0].IpPermissions'
   ```

3. **Pods 不能直接暴露 LoadBalancer (internet-facing)**
   - 只有 API Gateway 可以暴露公网
   - 所有内部服务必须 internal

## 📊 安全监控

### CloudWatch Alarms

```yaml
Alarms:
  - API Gateway 4xx > 1000/5min
  - API Gateway 5xx > 100/5min
  - NLB Unhealthy Target Count > 0
  - Provisioning Service Pod Restarts > 3/10min
  - Unauthorized Access Attempts > 10/5min
```

### GuardDuty

- 监控异常 API 调用
- 检测未授权访问尝试
- 监控数据泄露风险

### AWS Security Hub

- 集成 GuardDuty, Inspector, Macie
- 持续合规检查
- 自动化修复建议

## 📝 安全最佳实践

1. ✅ **最小权限原则**: RBAC, Security Groups, IAM Roles
2. ✅ **深度防护**: 多层安全控制
3. ✅ **加密传输**: HTTPS everywhere
4. ✅ **加密存储**: EBS encryption, Secrets encryption
5. ✅ **网络隔离**: Private subnets, NetworkPolicy
6. ✅ **审计日志**: CloudTrail, API Gateway logs, EKS logs
7. ✅ **定期更新**: Patch management, CVE monitoring
8. ✅ **安全扫描**: ECR image scanning, Trivy

## 🔗 参考资料

- [AWS VPC Link Documentation](https://docs.aws.amazon.com/apigateway/latest/developerguide/set-up-private-integration.html)
- [EKS Security Best Practices](https://aws.github.io/aws-eks-best-practices/security/docs/)
- [Kubernetes Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

---

**维护者**: Claude Code
**最后更新**: 2026-03-01
