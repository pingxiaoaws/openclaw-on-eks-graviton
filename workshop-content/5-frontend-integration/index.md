---
title: "前端集成"
weight: 60
---

# CloudFront + Cognito + ALB 前端集成

## 架构说明

```
用户浏览器
  ↓ HTTPS
Amazon CloudFront (CDN + 缓存)
  ↓ Origin: ALB
Application Load Balancer (共享)
  ├── /login, /dashboard, /static → Provisioning Service
  └── /instance/{user_id}/*      → OpenClaw Instance Pods
```

## 创建 Cognito User Pool

```bash
# 创建 User Pool
USER_POOL_ID=$(aws cognito-idp create-user-pool \
  --pool-name openclaw-workshop \
  --auto-verified-attributes email \
  --username-attributes email \
  --policies '{"PasswordPolicy":{"MinimumLength":8,"RequireUppercase":true,"RequireLowercase":true,"RequireNumbers":true,"RequireSymbols":false}}' \
  --query 'UserPool.Id' --output text)

echo "User Pool ID: $USER_POOL_ID"

# 创建 App Client
CLIENT_ID=$(aws cognito-idp create-user-pool-client \
  --user-pool-id $USER_POOL_ID \
  --client-name openclaw-web \
  --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
  --query 'UserPoolClient.ClientId' --output text)

echo "Client ID: $CLIENT_ID"
```

## 配置共享 ALB (Ingress)

所有服务共享一个 ALB，通过路径路由区分：

```yaml
cat << 'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: openclaw-shared-alb
  namespace: openclaw-provisioning
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/group.name: openclaw-shared-instances
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/healthcheck-path: /health
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /login
            pathType: Prefix
            backend:
              service:
                name: openclaw-provisioning
                port:
                  number: 80
          - path: /dashboard
            pathType: Prefix
            backend:
              service:
                name: openclaw-provisioning
                port:
                  number: 80
          - path: /provision
            pathType: Prefix
            backend:
              service:
                name: openclaw-provisioning
                port:
                  number: 80
          - path: /static
            pathType: Prefix
            backend:
              service:
                name: openclaw-provisioning
                port:
                  number: 80
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: openclaw-provisioning
                port:
                  number: 80
EOF
```

```bash
# 等待 ALB 创建完成
kubectl get ingress -n openclaw-provisioning openclaw-shared-alb -w

# 获取 ALB DNS
ALB_DNS=$(kubectl get ingress -n openclaw-provisioning openclaw-shared-alb \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "ALB DNS: $ALB_DNS"
```

## 创建 CloudFront Distribution

```bash
# 创建 CloudFront Distribution（以 ALB 为 Origin）
DISTRIBUTION_ID=$(aws cloudfront create-distribution \
  --distribution-config "{
    \"CallerReference\": \"openclaw-$(date +%s)\",
    \"Origins\": {
      \"Quantity\": 1,
      \"Items\": [{
        \"Id\": \"openclaw-alb\",
        \"DomainName\": \"${ALB_DNS}\",
        \"CustomOriginConfig\": {
          \"HTTPPort\": 80,
          \"HTTPSPort\": 443,
          \"OriginProtocolPolicy\": \"https-only\"
        }
      }]
    },
    \"DefaultCacheBehavior\": {
      \"TargetOriginId\": \"openclaw-alb\",
      \"ViewerProtocolPolicy\": \"redirect-to-https\",
      \"AllowedMethods\": {\"Quantity\": 7, \"Items\": [\"GET\",\"HEAD\",\"OPTIONS\",\"PUT\",\"POST\",\"PATCH\",\"DELETE\"]},
      \"ForwardedValues\": {
        \"QueryString\": true,
        \"Cookies\": {\"Forward\": \"all\"},
        \"Headers\": {\"Quantity\": 3, \"Items\": [\"Authorization\", \"Host\", \"Origin\"]}
      },
      \"MinTTL\": 0,
      \"DefaultTTL\": 0,
      \"MaxTTL\": 0
    },
    \"Enabled\": true,
    \"Comment\": \"OpenClaw Workshop\"
  }" \
  --query 'Distribution.Id' --output text)

CLOUDFRONT_DOMAIN=$(aws cloudfront get-distribution --id $DISTRIBUTION_ID \
  --query 'Distribution.DomainName' --output text)

echo "CloudFront Distribution: $DISTRIBUTION_ID"
echo "CloudFront Domain: $CLOUDFRONT_DOMAIN"
```

{{% notice info %}}
CloudFront 部署需要 **5-10 分钟**。您可以继续下一步，稍后验证。
{{% /notice %}}

## 添加静态资源缓存

```bash
# 为 /static/* 路径添加缓存 Behavior
aws cloudfront create-cache-policy \
  --cache-policy-config '{
    "Name": "openclaw-static-cache",
    "DefaultTTL": 86400,
    "MaxTTL": 604800,
    "MinTTL": 0,
    "ParametersInCacheKeyAndForwardedToOrigin": {
      "EnableAcceptEncodingGzip": true,
      "HeadersConfig": {"HeaderBehavior": "none"},
      "CookiesConfig": {"CookieBehavior": "none"},
      "QueryStringsConfig": {"QueryStringBehavior": "none"}
    }
  }'
```

## 验证端到端访问

```bash
# 等待 CloudFront 部署完成
aws cloudfront wait distribution-deployed --id $DISTRIBUTION_ID

# 测试访问
curl -s https://${CLOUDFRONT_DOMAIN}/health
# 期望: {"status": "healthy"}

curl -s -o /dev/null -w "%{http_code}" https://${CLOUDFRONT_DOMAIN}/login
# 期望: 200

echo "✅ CloudFront + ALB + Provisioning 集成成功！"
echo "访问地址: https://${CLOUDFRONT_DOMAIN}/login"
```

## 下一步

前端接入已配置完成，接下来我们将探索运行时隔离方案。
