# OpenClaw ALB Ingress + Cognito 认证配置指南

## 架构说明

**双层认证架构**：
1. **ALB Cognito 认证**（第一层）- 用户访问任何 OpenClaw instance 前必须先登录
2. **OpenClaw Gateway Token**（第二层）- 应用层认证

**访问流程**：
```
用户 → ALB (检查 Cognito 登录) → 未登录则跳转到登录页
                                  → 已登录则转发到 OpenClaw instance
                                      → 再验证 gateway_token
```

---

## 已完成配置

### ✅ AWS 资源
- **AWS Account ID**: `111122223333`
- **Cognito User Pool**: `us-west-2_ExAmPlE`
- **Cognito Client ID**: `62csdgbfh62kqtekbhjpqhmlta`
- **Cognito Domain**: `openclaw-auth.auth.us-west-2.amazoncognito.com` ✨

### ✅ Kubernetes 资源
- **AWS Load Balancer Controller**: 已安装 (kube-system namespace)
- **IngressClass**: `alb` (已配置)

---

## 待完成配置

### 1. 准备域名和 ACM 证书

**选项 A：使用自定义域名**（推荐）
```bash
# 1. 在 Route 53 创建 Hosted Zone（如果还没有）
# 2. 申请 ACM 证书
aws acm request-certificate \
  --domain-name openclaw.yourdomain.com \
  --validation-method DNS \
  --region us-west-2

# 3. 在 Route 53 添加 DNS 验证记录（ACM 控制台会提供）
# 4. 等待证书验证通过（通常几分钟）
```

**选项 B：使用测试域名（临时方案）**
```bash
# 使用 ALB 自动生成的 DNS 名称（不需要证书）
# 仅用于测试，不安全（HTTP only）
```

### 2. 配置 Cognito App Client 回调 URL

```bash
# 获取 ALB DNS 名称（部署后会自动创建）
ALB_DNS=$(kubectl get ingress -A -l alb.ingress.kubernetes.io/group.name=openclaw-instances \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

# 更新 Cognito App Client 回调 URL
aws cognito-idp update-user-pool-client \
  --user-pool-id us-west-2_ExAmPlE \
  --client-id 62csdgbfh62kqtekbhjpqhmlta \
  --region us-west-2 \
  --callback-urls "[\"https://openclaw.yourdomain.com/oauth2/idpresponse\"]" \
  --allowed-o-auth-flows "code" \
  --allowed-o-auth-scopes "openid" \
  --allowed-o-auth-flows-user-pool-client
```

### 3. 更新 Deployment 环境变量

编辑 `eks-pod-service/kubernetes/deployment.yaml`：

```yaml
env:
# 现有配置...
- name: AWS_ACCOUNT_ID
  value: "111122223333"
- name: COGNITO_USER_POOL_DOMAIN
  value: "openclaw-auth.auth.us-west-2.amazoncognito.com"
- name: INGRESS_HOST
  value: "openclaw.yourdomain.com"  # 替换为你的域名
- name: INGRESS_CERTIFICATE_ARN
  value: "arn:aws:acm:us-west-2:111122223333:certificate/YOUR-CERT-ID"  # 替换为你的证书 ARN
```

或者使用 kubectl：

```bash
kubectl set env deployment/openclaw-provisioning -n openclaw-provisioning \
  AWS_ACCOUNT_ID=111122223333 \
  COGNITO_USER_POOL_DOMAIN=openclaw-auth.auth.us-west-2.amazoncognito.com \
  INGRESS_HOST=openclaw.yourdomain.com \
  INGRESS_CERTIFICATE_ARN=arn:aws:acm:us-west-2:111122223333:certificate/YOUR-CERT-ID

kubectl rollout restart deployment/openclaw-provisioning -n openclaw-provisioning
```

---

## 测试步骤

### 1. 重新部署 Operator 和 Provisioning Service

```bash
# 1. 部署 operator (支持 ALB provider)
cd /Users/pingxiao/aws-workspace/kata-open-claw/k8s-operator
git pull
make deploy

# 2. 构建并推送新镜像
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata/eks-pod-service
docker build -t 111122223333.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest .
docker push 111122223333.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest

# 3. 重启 deployment
kubectl rollout restart deployment/openclaw-provisioning -n openclaw-provisioning
```

### 2. 创建测试 Instance

访问：https://xxxxxxxxxx.execute-api.us-west-2.amazonaws.com/prod/dashboard

点击 "Create OpenClaw Instance"

### 3. 验证 Ingress 创建

```bash
# 检查 Ingress
kubectl get ingress -A -l alb.ingress.kubernetes.io/group.name=openclaw-instances

# 应该看到类似输出：
# NAMESPACE           NAME                 CLASS   HOSTS                    ADDRESS                                   PORTS
# openclaw-a744863d   openclaw-a744863d    alb     openclaw.yourdomain.com  xxx.elb.us-west-2.amazonaws.com          80, 443

# 检查 ALB
kubectl describe ingress -n openclaw-a744863d openclaw-a744863d
```

### 4. 测试访问

```bash
# 获取 ALB DNS
ALB_DNS=$(kubectl get ingress -A -l alb.ingress.kubernetes.io/group.name=openclaw-instances \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

echo "ALB DNS: $ALB_DNS"

# 访问（会跳转到 Cognito 登录）
https://openclaw.yourdomain.com/instance/a744863d/
```

**预期行为**：
1. 浏览器自动跳转到 Cognito 登录页
2. 登录成功后返回到 OpenClaw instance
3. OpenClaw 再要求输入 gateway_token（从 Secret 获取）

### 5. 获取 Gateway Token

```bash
USER_ID=a744863d  # 替换为你的 user_id

kubectl get secret openclaw-$USER_ID-gateway-token \
  -n openclaw-$USER_ID \
  -o jsonpath='{.data.token}' | base64 -d
```

---

## 安全特性

### ✅ 已实现
- **双层认证**：ALB Cognito + OpenClaw gateway_token
- **HTTPS 加密**：ALB 终止 SSL
- **Ingress Groups**：多个 instance 共享一个 ALB（降低成本）
- **路径隔离**：每个 user 有独立路径 `/instance/{user_id}`

### ✅ AWS 自动防护
- **DDoS 防护**：AWS Shield Standard（免费）
- **速率限制**：ALB 内置连接限制
- **IP 封禁**：可配置 Security Group

### 🔒 可选增强
- **WAF**：添加 AWS WAF 规则
- **VPC 限制**：仅允许特定 VPC 访问
- **IP 白名单**：限制特定 IP 范围

---

## 故障排查

### Ingress 未创建

```bash
# 检查 operator 日志
kubectl logs -n openclaw-operator-system deployment/openclaw-operator --tail=100

# 检查 OpenClawInstance
kubectl describe openclawinstance -n openclaw-$USER_ID openclaw-$USER_ID
```

### ALB 未创建

```bash
# 检查 AWS Load Balancer Controller 日志
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=100

# 检查 Ingress events
kubectl describe ingress -n openclaw-$USER_ID openclaw-$USER_ID
```

### Cognito 认证失败

```bash
# 检查回调 URL 配置
aws cognito-idp describe-user-pool-client \
  --user-pool-id us-west-2_ExAmPlE \
  --client-id 62csdgbfh62kqtekbhjpqhmlta \
  --region us-west-2 \
  --query 'UserPoolClient.CallbackURLs'
```

---

## 环境变量完整列表

| 变量名 | 默认值 | 说明 | 必需 |
|--------|--------|------|------|
| `AWS_ACCOUNT_ID` | - | AWS 账户 ID | ✅ |
| `COGNITO_USER_POOL_DOMAIN` | - | Cognito domain | ✅ |
| `INGRESS_HOST` | `openclaw.example.com` | Ingress 域名 | ✅ |
| `INGRESS_CERTIFICATE_ARN` | - | ACM 证书 ARN | ✅ (HTTPS) |
| `INGRESS_ENABLED` | `true` | 是否启用 Ingress | ❌ |
| `INGRESS_CLASS` | `alb` | Ingress class | ❌ |
| `INGRESS_GROUP_NAME` | `openclaw-instances` | ALB group 名称 | ❌ |
| `INGRESS_SCHEME` | `internet-facing` | ALB scheme | ❌ |

---

## 成本估算

**ALB Ingress Groups 共享方案**：
- **1 个 ALB**：~$22.50/月（固定成本）
- **数据传输**：$0.008/GB（变动成本）
- **支持无限个 OpenClaw instances**

vs **每个 instance 一个 ALB**：
- 10 个 instances = $225/月
- 100 个 instances = $2,250/月 😱

**节省 90% 成本！** 🎉

---

**配置完成后，所有 OpenClaw instances 将通过 HTTPS + Cognito 双重认证保护！** 🔒
