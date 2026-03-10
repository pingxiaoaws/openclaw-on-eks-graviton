---
title: "Provisioning Service"
weight: 50
---

# 部署多租户 Provisioning Service

## 设计思路

Provisioning Service 是多租户平台的核心业务层，负责：

1. 接收用户请求（从 Cognito JWT 中提取身份）
2. 为每个用户创建独立的 Kubernetes Namespace
3. 配置 ResourceQuota 和 NetworkPolicy
4. 创建 OpenClawInstance CRD
5. 设置 EKS Pod Identity（Bedrock 访问权限）

## 创建 IAM Roles

### Provisioning Service Role

```bash
# 创建信任策略
cat << 'EOF' > provisioning-trust.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }
  ]
}
EOF

# 创建 IAM Role
aws iam create-role \
  --role-name openclaw-provisioning-service \
  --assume-role-policy-document file://provisioning-trust.json

# 附加策略（管理 Pod Identity Associations）
cat << 'EOF' > provisioning-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManagePodIdentityAssociations",
      "Effect": "Allow",
      "Action": [
        "eks:CreatePodIdentityAssociation",
        "eks:DeletePodIdentityAssociation",
        "eks:ListPodIdentityAssociations",
        "eks:DescribePodIdentityAssociation"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name openclaw-provisioning-service \
  --policy-name OpenClawProvisioningPolicy \
  --policy-document file://provisioning-policy.json
```

### Shared Bedrock Role（供所有 OpenClaw 实例共享）

```bash
# 创建共享 Bedrock Role
aws iam create-role \
  --role-name openclaw-bedrock-shared \
  --assume-role-policy-document file://provisioning-trust.json

# 附加 Bedrock 访问策略
cat << 'EOF' > bedrock-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockModelAccess",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": "arn:aws:bedrock:*::foundation-model/*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name openclaw-bedrock-shared \
  --policy-name OpenClawBedrockAccess \
  --policy-document file://bedrock-policy.json
```

{{% notice info %}}
**为什么使用共享 Role？** 传统方案为每个用户创建独立的 IAM Role，N 个用户需要 N 个 Role。共享 Role 架构中，所有用户的 Pod 通过各自的 ServiceAccount 绑定同一个 Role，IAM Role 数量从 O(n) 降为 O(1)。
{{% /notice %}}

## 部署 Provisioning Service

### 创建 Namespace 和 ServiceAccount

```bash
kubectl create namespace openclaw-provisioning

# 创建 ServiceAccount
kubectl create serviceaccount openclaw-provisioner -n openclaw-provisioning

# 创建 Pod Identity Association
aws eks create-pod-identity-association \
  --cluster-name ${CLUSTER_NAME} \
  --namespace openclaw-provisioning \
  --service-account openclaw-provisioner \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/openclaw-provisioning-service
```

### 构建并推送镜像

```bash
# 创建 ECR 仓库
aws ecr create-repository --repository-name openclaw-provisioning --region ${AWS_REGION}

# 登录 ECR
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

# 构建镜像（ARM64）
cd open-claw-operator-on-EKS-kata/eks-pod-service
docker buildx build --platform linux/arm64 \
  -t ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/openclaw-provisioning:latest \
  --push .
```

### 部署到 EKS

```yaml
cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openclaw-provisioning
  namespace: openclaw-provisioning
spec:
  replicas: 2
  selector:
    matchLabels:
      app: openclaw-provisioning
  template:
    metadata:
      labels:
        app: openclaw-provisioning
    spec:
      serviceAccountName: openclaw-provisioner
      nodeSelector:
        kubernetes.io/arch: arm64
      containers:
        - name: provisioning
          image: ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/openclaw-provisioning:latest
          ports:
            - containerPort: 5000
          env:
            - name: EKS_CLUSTER_NAME
              value: "${CLUSTER_NAME}"
            - name: AWS_REGION
              value: "${AWS_REGION}"
            - name: SHARED_BEDROCK_ROLE_ARN
              value: "arn:aws:iam::${ACCOUNT_ID}:role/openclaw-bedrock-shared"
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: openclaw-provisioning
  namespace: openclaw-provisioning
spec:
  selector:
    app: openclaw-provisioning
  ports:
    - port: 80
      targetPort: 5000
EOF
```

## 验证部署

```bash
# 检查 Pod 状态
kubectl get pods -n openclaw-provisioning
# 期望: 2 个 Pod Running

# 检查日志
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=10

# 测试 Health Check
kubectl exec -n openclaw-provisioning deployment/openclaw-provisioning -- curl -s localhost:5000/health
# 期望: {"status": "healthy"}
```

## 授权流程图

```
用户请求 (JWT Token)
  ↓
Provisioning Service (SA: openclaw-provisioner)
  ↓ Pod Identity → IAM Role: openclaw-provisioning-service
  ↓ eks:CreatePodIdentityAssociation
  ↓
创建用户 Namespace + SA + Pod Identity Association
  ↓
用户 Pod (SA: openclaw-{user_id})
  ↓ Pod Identity → IAM Role: openclaw-bedrock-shared
  ↓ bedrock:InvokeModel
  ↓
Amazon Bedrock (Claude Sonnet/Opus)
```

## 下一步

Provisioning Service 已部署，接下来配置 CloudFront + Cognito 前端接入。
