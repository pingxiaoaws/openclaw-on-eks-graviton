# China Region - Bedrock API Key Setup Guide

## Overview

从 China Region (cn-north-1/cn-northwest-1) 的 EKS 集群通过 **Bedrock API Key** 调用 Global Region (us-east-1) 的 Bedrock 模型。

**关键限制**:
- China Region 无法直接访问 Docker Hub (`docker.io`) - 需要镜像同步到 China ECR
- Anthropic Claude 模型从 China IP 调用会被 Anthropic 地域限制拦截
- 可用模型: Amazon Nova, MiniMax, DeepSeek, Qwen, Meta Llama 等非 Anthropic 模型

**认证方式对比**:

| 方式 | 凭证 | 轮换 | 适用场景 |
|------|------|------|---------|
| Pod Identity | IAM Role (自动) | 自动 | 同 Region 生产环境 |
| Bedrock API Key | AWS_BEARER_TOKEN_BEDROCK | 手动 | 跨 Region / China Region |
| AK/SK | AWS_ACCESS_KEY_ID + SK | 手动 | 不推荐 |

**架构**:

```
China Region (cn-north-1)                    Global Region (us-east-1)
┌─────────────────────────────┐              ┌──────────────────────────────┐
│ EKS Cluster (openclaw-prod) │              │ Bedrock Runtime API          │
│                             │              │ bedrock-runtime.us-east-1.   │
│  K8s Secret                 │              │   amazonaws.com              │
│   AWS_BEARER_TOKEN_BEDROCK  │              │                              │
│        │                    │              │  Models:                     │
│        v                    │   HTTPS      │  - amazon.nova-pro-v1:0      │
│  OpenClaw Pod ──────────────┼─────────────>│  - minimax.minimax-m2.1      │
│   model: bedrock/minimax..  │  Bearer Auth │  - deepseek.r1-v1:0          │
│   AWS_REGION=us-east-1      │              │  - qwen.qwen3-32b-v1:0       │
│                             │              │  - meta.llama4-...            │
└─────────────────────────────┘              └──────────────────────────────┘
```

---

## Prerequisites

- Global Region AWS Account (e.g. us-east-1, account 970547376847) with Bedrock access
- China Region EKS cluster with kubectl access
- 一台可以访问 Docker Hub 的 EC2 (用于镜像同步)
- AWS CLI v2, kubectl, jq

---

## Step 1: Generate Bedrock API Key (Global Region)

Bedrock API Key 是 IAM Service-Specific Credential, 无过期时间, 需手动删除。

```bash
# 配置 Global Region 凭证
export AWS_ACCESS_KEY_ID=<global-ak>
export AWS_SECRET_ACCESS_KEY=<global-sk>
export AWS_DEFAULT_REGION=us-east-1

# 1.1 创建 IAM 用户
IAM_USER_NAME="bedrock-api-user"
aws iam create-user --user-name "$IAM_USER_NAME"

# 1.2 附加 Bedrock 策略
aws iam attach-user-policy \
  --user-name "$IAM_USER_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"

# 1.3 生成 API Key (secret 只显示一次!)
CRED_JSON=$(aws iam create-service-specific-credential \
  --user-name "$IAM_USER_NAME" \
  --service-name bedrock.amazonaws.com \
  --output json)

CRED_SECRET=$(echo "$CRED_JSON" | jq -r '.ServiceSpecificCredential.ServiceCredentialSecret')
CRED_ID=$(echo "$CRED_JSON" | jq -r '.ServiceSpecificCredential.ServiceSpecificCredentialId')

echo "Credential ID: $CRED_ID"
echo "API Key (SAVE THIS): $CRED_SECRET"

# 1.4 验证 API Key
curl -s -o /dev/null -w "HTTP %{http_code}" -X POST \
  "https://bedrock-runtime.us-east-1.amazonaws.com/model/amazon.nova-pro-v1:0/converse" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CRED_SECRET" \
  -d '{"messages":[{"role":"user","content":[{"text":"hi"}]}]}'
# Expected: HTTP 200
```

**管理 API Key**:

```bash
# 列出现有 credentials
aws iam list-service-specific-credentials \
  --user-name bedrock-api-user \
  --service-name bedrock.amazonaws.com

# 禁用 (不删除)
aws iam update-service-specific-credential \
  --user-name bedrock-api-user \
  --service-specific-credential-id <cred-id> \
  --status Inactive

# 删除
aws iam delete-service-specific-credential \
  --user-name bedrock-api-user \
  --service-specific-credential-id <cred-id>

# 限制: 每用户每服务最多 2 个 credential
```

---

## Step 2: Query Available Models

使用 API Key 查询所有可用模型:

```bash
# 列出所有模型 ID
curl -s -X GET \
  "https://bedrock.us-east-1.amazonaws.com/foundation-models" \
  -H "Authorization: Bearer $CRED_SECRET" \
  | jq -r '.modelSummaries[].modelId' | sort

# 测试特定模型是否可调用
curl -s -o /dev/null -w "HTTP %{http_code}" -X POST \
  "https://bedrock-runtime.us-east-1.amazonaws.com/model/<model-id>/converse" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CRED_SECRET" \
  -d '{"messages":[{"role":"user","content":[{"text":"hi"}]}]}'
```

**China Region 验证可用的模型** (从 cn-north-1 Pod 内测试通过):

| Model ID | 状态 | 说明 |
|----------|------|------|
| `amazon.nova-pro-v1:0` | OK | Amazon Nova Pro |
| `amazon.nova-lite-v1:0` | OK | Amazon Nova Lite (轻量) |
| `minimax.minimax-m2.1` | OK | MiniMax M2.1 (支持 reasoning) |
| `minimax.minimax-m2` | OK | MiniMax M2 |
| `anthropic.claude-*` | BLOCKED | Anthropic 地域限制, China IP 不可用 |
| `us.anthropic.claude-*` | BLOCKED | 同上 (cross-region inference profile) |

> **注意**: 需要从 China Pod 内部测试, 本地 (非 China) curl 结果不代表实际可用性。
> 从 Pod 内测试:
> ```bash
> kubectl exec <pod> -c openclaw -- curl -s -o /dev/null -w "%{http_code}" -X POST \
>   "https://bedrock-runtime.us-east-1.amazonaws.com/model/<model-id>/converse" \
>   -H "Authorization: Bearer <api-key>" \
>   -H "Content-Type: application/json" \
>   -d '{"messages":[{"role":"user","content":[{"text":"hi"}]}]}'
> ```

---

## Step 3: Sync Docker Images to China ECR

China EKS 节点无法访问 Docker Hub。OpenClaw operator 硬编码了以下镜像:

| 镜像 | 用途 | 来源 |
|------|------|------|
| `busybox:1.37` | init container (配置拷贝) | docker.io |
| `nginx:1.27-alpine` | gateway-proxy sidecar | docker.io |
| `<ecr>/openclaw:<tag>` | 主容器 | Global Region ECR |

需要通过一台可访问 Docker Hub 的机器 (如 Global Region EC2) 中转推送到 China ECR。

```bash
# === 在 China Region 创建 ECR 仓库 ===
export AWS_ACCESS_KEY_ID=<china-ak>
export AWS_SECRET_ACCESS_KEY=<china-sk>
export AWS_DEFAULT_REGION=cn-north-1
export AWS_STS_REGIONAL_ENDPOINTS=regional

CHINA_ACCOUNT=274436715293  # 替换为你的 China account ID
CHINA_ECR="${CHINA_ACCOUNT}.dkr.ecr.cn-north-1.amazonaws.com.cn"

aws ecr create-repository --repository-name busybox --region cn-north-1
aws ecr create-repository --repository-name nginx --region cn-north-1
aws ecr create-repository --repository-name openclaw --region cn-north-1

# === 在可访问 Docker Hub 的 EC2 上执行 ===
ssh -i <key.pem> ec2-user@<ec2-ip>

# 拉取 ARM64 镜像 (China EKS 节点为 Graviton ARM64)
docker pull --platform linux/arm64 busybox:1.37
docker pull --platform linux/arm64 nginx:1.27-alpine

# 从 Global Region ECR 拉取 OpenClaw
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin 970547376847.dkr.ecr.us-west-2.amazonaws.com
docker pull 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw:2026.3.14

# 登录 China ECR
export AWS_ACCESS_KEY_ID=<china-ak>
export AWS_SECRET_ACCESS_KEY=<china-sk>
export AWS_DEFAULT_REGION=cn-north-1
export AWS_STS_REGIONAL_ENDPOINTS=regional
aws ecr get-login-password --region cn-north-1 \
  --endpoint-url https://api.ecr.cn-north-1.amazonaws.com.cn | \
  docker login --username AWS --password-stdin $CHINA_ECR

# Tag 并 push
docker tag busybox:1.37 ${CHINA_ECR}/busybox:1.37
docker tag nginx:1.27-alpine ${CHINA_ECR}/nginx:1.27-alpine
docker tag 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw:2026.3.14 \
  ${CHINA_ECR}/openclaw:2026.3.14

docker push ${CHINA_ECR}/busybox:1.37
docker push ${CHINA_ECR}/nginx:1.27-alpine
docker push ${CHINA_ECR}/openclaw:2026.3.14
```

---

## Step 4: Install OpenClaw Operator

```bash
# 配置 China Region kubectl
export AWS_ACCESS_KEY_ID=<china-ak>
export AWS_SECRET_ACCESS_KEY=<china-sk>
export AWS_DEFAULT_REGION=cn-north-1
export AWS_STS_REGIONAL_ENDPOINTS=regional

# Operator 镜像 (ghcr.io 在 China 可访问)
cd <path-to>/openclaw-operator
helm upgrade --install openclaw-operator charts/openclaw-operator \
  --namespace openclaw-operator-system \
  --create-namespace \
  --wait --timeout 120s

# 验证
kubectl get deployment -n openclaw-operator-system
kubectl get crd openclawinstances.openclaw.rocks
```

---

## Step 5: Create K8s Resources

### 5.1 Namespace

```bash
kubectl create namespace openclaw-test-apikey
```

### 5.2 Secret (Bedrock API Key)

```bash
kubectl create secret generic bedrock-api-key \
  -n openclaw-test-apikey \
  --from-literal=AWS_BEARER_TOKEN_BEDROCK="<your-bedrock-api-key>"
```

> `AWS_BEARER_TOKEN_BEDROCK` 是 AWS SDK (boto3) 识别的环境变量。
> 设置后, SDK 自动使用 Bearer token 认证代替 SigV4。
> OpenClaw 的 `bedrock/` provider 内部使用 AWS SDK, 因此透明支持。

### 5.3 OpenClawInstance

```yaml
# openclaw-china-bedrock.yaml
apiVersion: openclaw.rocks/v1alpha1
kind: OpenClawInstance
metadata:
  name: openclaw-apikey-test
  namespace: openclaw-test-apikey
spec:
  image:
    # 使用 China ECR 镜像
    repository: <china-account>.dkr.ecr.cn-north-1.amazonaws.com.cn/openclaw
    tag: "2026.3.14"
    pullPolicy: IfNotPresent
  config:
    raw:
      gateway:
        controlUi:
          allowedOrigins:
            - "http://localhost:18789"
            - "http://127.0.0.1:18789"
        trustedProxies:
          - "0.0.0.0/0"
      agents:
        defaults:
          model:
            # 使用 China 可用的模型 (非 Anthropic)
            primary: "bedrock/minimax.minimax-m2.1"
  envFrom:
    - secretRef:
        name: bedrock-api-key       # 注入 AWS_BEARER_TOKEN_BEDROCK
  env:
    - name: AWS_REGION
      value: "us-east-1"            # Bedrock 所在 Region
    - name: AWS_DEFAULT_REGION
      value: "us-east-1"
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "2"
      memory: "4Gi"
  storage:
    persistence:
      enabled: true
      size: 10Gi
      storageClass: gp2             # China Region 可用的 StorageClass
      accessModes:
        - ReadWriteOnce
  networking:
    service:
      type: ClusterIP
  security:
    podSecurityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
      runAsNonRoot: true
    containerSecurityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: false
      capabilities:
        drop:
          - ALL
    networkPolicy:
      enabled: true
      allowDNS: true
    rbac:
      createServiceAccount: true
  selfConfigure:
    enabled: true
  observability:
    metrics:
      enabled: true
      port: 9090
    logging:
      level: info
      format: json
```

```bash
kubectl apply -f openclaw-china-bedrock.yaml
```

---

## Step 6: Patch Images (Operator Workaround)

Operator 硬编码了 `busybox:1.37` 和 `nginx:1.27-alpine` (docker.io), China 无法拉取。
需要先让 operator 创建资源, 然后停止 operator, patch 镜像地址。

```bash
CHINA_ECR="<china-account>.dkr.ecr.cn-north-1.amazonaws.com.cn"
NAMESPACE="openclaw-test-apikey"
INSTANCE="openclaw-apikey-test"

# 等待 operator 创建 StatefulSet
sleep 5

# 停止 operator (防止 reconcile 覆盖 patch)
kubectl scale deployment openclaw-operator -n openclaw-operator-system --replicas=0

# Patch init container 和 sidecar 镜像
kubectl patch statefulset $INSTANCE -n $NAMESPACE --type='json' -p="[
  {\"op\": \"replace\", \"path\": \"/spec/template/spec/initContainers/0/image\", \"value\": \"${CHINA_ECR}/busybox:1.37\"},
  {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/1/image\", \"value\": \"${CHINA_ECR}/nginx:1.27-alpine\"}
]"

# 删除卡住的 Pod, 触发重建
kubectl delete pod ${INSTANCE}-0 -n $NAMESPACE

# 等待 Pod Ready
kubectl wait --for=condition=ready pod/${INSTANCE}-0 -n $NAMESPACE --timeout=120s
```

> **注意**: Operator 停止后不再 reconcile。如需恢复: `kubectl scale deployment openclaw-operator -n openclaw-operator-system --replicas=1`
> 恢复后 operator 会将镜像恢复为 docker.io 地址, Pod 会再次 ImagePullBackOff。

---

## Step 7: Verify & Access

```bash
# 检查 Pod 状态
kubectl get pods -n openclaw-test-apikey
# Expected: 2/2 Running

# 检查环境变量注入
kubectl exec ${INSTANCE}-0 -n $NAMESPACE -c openclaw -- \
  env | grep -E "AWS_BEARER_TOKEN_BEDROCK|AWS_REGION"

# 获取 Gateway Token
kubectl get secret ${INSTANCE}-gateway-token -n $NAMESPACE \
  -o jsonpath='{.data.token}' | base64 -d
echo ""

# Approve device pairing
kubectl exec ${INSTANCE}-0 -n $NAMESPACE -c openclaw -- openclaw devices approve

# Port-forward
kubectl port-forward pod/${INSTANCE}-0 -n $NAMESPACE 18789:18789

# 打开浏览器: http://localhost:18789
# 输入 Gateway Token 连接
```

---

## Debugging

### 模型不可用 (Unknown model)

```bash
# 检查 OpenClaw 识别的模型
kubectl exec ${INSTANCE}-0 -n $NAMESPACE -c openclaw -- openclaw models

# 常见原因:
# 1. OpenClaw 内部模型注册表不包含该模型
#    - Nova 系列: OpenClaw 可能不认识, 报 "Unknown model"
#    - MiniMax: 同上
# 2. 解决: 使用 OpenClaw 已知的模型, 或等待 OpenClaw 更新支持
```

### 认证失败 (Missing auth)

```bash
# 检查 env var 是否注入
kubectl exec ${INSTANCE}-0 -n $NAMESPACE -c openclaw -- \
  env | grep AWS_BEARER_TOKEN_BEDROCK

# 检查 Secret 是否存在
kubectl get secret bedrock-api-key -n $NAMESPACE -o yaml

# 从 Pod 内部直接测试 API Key
kubectl exec ${INSTANCE}-0 -n $NAMESPACE -c openclaw -- \
  curl -s -o /dev/null -w "%{http_code}" -X POST \
  "https://bedrock-runtime.us-east-1.amazonaws.com/model/amazon.nova-pro-v1:0/converse" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <api-key>" \
  -d '{"messages":[{"role":"user","content":[{"text":"hi"}]}]}'
# Expected: 200
```

### 镜像拉取失败 (ImagePullBackOff)

```bash
# 查看具体错误
kubectl describe pod ${INSTANCE}-0 -n $NAMESPACE | tail -20

# 常见原因:
# 1. docker.io 不可达 (busybox, nginx) -> 需要 Step 6 patch
# 2. China ECR 认证失败 -> 检查节点 IAM Role 有 ecr:GetAuthorizationToken
# 3. 镜像架构不匹配 -> 确保推送的是 ARM64 镜像
```

### Claude 模型被拦截

```bash
# 从 Pod 内测试 Claude
kubectl exec ${INSTANCE}-0 -n $NAMESPACE -c openclaw -- \
  curl -s -X POST \
  "https://bedrock-runtime.us-east-1.amazonaws.com/model/us.anthropic.claude-sonnet-4-5-20250929-v1:0/converse" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <api-key>" \
  -d '{"messages":[{"role":"user","content":[{"text":"hi"}]}]}'
# Expected error: "Access to Anthropic models is not allowed from unsupported countries..."
# 解决: 使用非 Anthropic 模型 (Nova, MiniMax, DeepSeek, Qwen, Llama 等)
```

### 网络连通性

```bash
# 测试 China Pod -> Global Bedrock 连通性
kubectl exec ${INSTANCE}-0 -n $NAMESPACE -c openclaw -- \
  curl -s -o /dev/null -w "%{http_code}" \
  "https://bedrock-runtime.us-east-1.amazonaws.com/"
# Expected: 403 (reachable but no auth) -- 说明网络通

# 如果 timeout, 检查:
# 1. NetworkPolicy 是否允许 egress
# 2. Security Group 是否允许出站 HTTPS
# 3. NAT Gateway 是否正常
```

### 更换模型

```bash
# 修改 ConfigMap 中的模型配置
kubectl get configmap ${INSTANCE}-config -n $NAMESPACE -o json | \
  python3 -c "
import json, sys
cm = json.load(sys.stdin)
config = json.loads(cm['data']['openclaw.json'])
config['agents']['defaults']['model']['primary'] = 'bedrock/<new-model-id>'
cm['data']['openclaw.json'] = json.dumps(config, indent=2)
json.dump(cm, sys.stdout)
" | kubectl apply -f -

# 重启 Pod 生效
kubectl delete pod ${INSTANCE}-0 -n $NAMESPACE
```

---

## Cleanup

```bash
# 删除 OpenClaw instance
kubectl delete openclawinstance openclaw-apikey-test -n openclaw-test-apikey

# 删除 namespace (包含所有资源)
kubectl delete namespace openclaw-test-apikey

# 恢复 operator
kubectl scale deployment openclaw-operator -n openclaw-operator-system --replicas=1

# (可选) 删除 China ECR 仓库
aws ecr delete-repository --repository-name busybox --region cn-north-1 --force
aws ecr delete-repository --repository-name nginx --region cn-north-1 --force
aws ecr delete-repository --repository-name openclaw --region cn-north-1 --force

# (Global Region) 删除 API Key
aws iam delete-service-specific-credential \
  --user-name bedrock-api-user \
  --service-specific-credential-id <cred-id>
aws iam detach-user-policy \
  --user-name bedrock-api-user \
  --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess
aws iam delete-user --user-name bedrock-api-user
```

---

**Last Updated**: 2026-03-18
