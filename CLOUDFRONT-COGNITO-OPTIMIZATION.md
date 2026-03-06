# CloudFront + Cognito 架构优化方案

**文档版本**: v1.0
**创建日期**: 2026-03-06
**作者**: Claude Code

---

## 目录

1. [当前架构分析](#当前架构分析)
2. [优化方案对比](#优化方案对比)
3. [方案 1：CloudFront 缓存优化（短期）](#方案-1cloudfront-缓存优化短期)
4. [方案 2：共享 ALB 架构（中期）](#方案-2共享-alb-架构中期)
5. [方案 3：Lambda@Edge 认证（长期）](#方案-3lambdaedge-认证长期)
6. [方案 4：ALB OIDC 集成（可选）](#方案-4alb-oidc-集成可选)
7. [成本对比分析](#成本对比分析)
8. [实施路线图](#实施路线图)

---

## 当前架构分析

### Provisioning Service 架构

```
User → API Gateway (JWT auth) → VPC Link → Internal ALB → EKS
     (no CloudFront)
```

**问题**：
- ❌ 静态资源（login.html, dashboard.html, JS/CSS）每次都经过 API Gateway
- ❌ API Gateway 按请求计费（$3.50/百万请求）
- ❌ 无全球加速
- ❌ 无静态资源缓存

### OpenClaw Instance 架构 (per-user)

```
User → CloudFront → Public ALB → EKS (openclaw-{user_id})
     (每个用户独立)
```

**问题**：
- ❌ 100 用户 = 100 个 ALB ($16/月 × 100 = $1,600/月)
- ❌ 100 用户 = 100 个 CloudFront distribution
- ❌ 管理复杂度高

---

## 优化方案对比

| 维度 | 方案 1: CF缓存 | 方案 2: 共享ALB | 方案 3: Lambda@Edge | 方案 4: ALB OIDC |
|------|---------------|----------------|-------------------|-----------------|
| **实施难度** | ⭐ 简单 | ⭐⭐ 中等 | ⭐⭐⭐ 复杂 | ⭐⭐ 中等 |
| **实施时间** | 1 天 | 2-3 周 | 2 周 | 1 周 |
| **成本节省** | 90% (静态) | 90% (总体) | 83% (请求) | 80% |
| **扩展性** | 中 | 优秀 | 优秀 | 优秀 |
| **自定义登录** | ✅ | ✅ | ✅ | ❌ |
| **风险** | 低 | 中 | 中 | 低 |
| **推荐优先级** | P0 | P1 | P2 | P3 |

---

## 方案 1：CloudFront 缓存优化（短期）

### 架构图

```
┌─────────────────────────────────────────────────────────┐
│  CloudFront (provisioning.openclaw.rocks)               │
│  - Origin: API Gateway                                   │
│  - Cache: /static/*, /dashboard, /login (static)        │
│  - No Cache: /api/* (dynamic, forward to API GW)        │
└───────────────────────┬─────────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────────┐
│  API Gateway (JWT auth, rate limiting)                  │
└───────────────────────┬─────────────────────────────────┘
                        │ VPC Link
┌───────────────────────▼─────────────────────────────────┐
│  Internal ALB → Provisioning Service                    │
└─────────────────────────────────────────────────────────┘
```

### 实施步骤

#### 1. 创建 CloudFront Distribution

```bash
# cache-behaviors.json
cat > /tmp/cloudfront-cache-config.json << 'EOF'
{
  "Items": [
    {
      "PathPattern": "/static/*",
      "TargetOriginId": "api-gateway-origin",
      "ViewerProtocolPolicy": "redirect-to-https",
      "AllowedMethods": {
        "Quantity": 2,
        "Items": ["GET", "HEAD"],
        "CachedMethods": {
          "Quantity": 2,
          "Items": ["GET", "HEAD"]
        }
      },
      "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
      "Compress": true,
      "MinTTL": 86400,
      "DefaultTTL": 86400,
      "MaxTTL": 31536000
    },
    {
      "PathPattern": "/dashboard",
      "TargetOriginId": "api-gateway-origin",
      "ViewerProtocolPolicy": "redirect-to-https",
      "AllowedMethods": {
        "Quantity": 2,
        "Items": ["GET", "HEAD"]
      },
      "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
      "MinTTL": 0,
      "DefaultTTL": 3600,
      "MaxTTL": 86400
    },
    {
      "PathPattern": "/login",
      "TargetOriginId": "api-gateway-origin",
      "ViewerProtocolPolicy": "redirect-to-https",
      "AllowedMethods": {
        "Quantity": 2,
        "Items": ["GET", "HEAD"]
      },
      "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
      "MinTTL": 0,
      "DefaultTTL": 3600,
      "MaxTTL": 86400
    }
  ]
}
EOF

# 创建 distribution
aws cloudfront create-distribution \
  --origin-domain-name 0qu1ls4sf5.execute-api.us-west-2.amazonaws.com \
  --origin-path /prod \
  --default-root-object dashboard \
  --enabled \
  --price-class PriceClass_All \
  --viewer-protocol-policy redirect-to-https \
  --comment "OpenClaw Provisioning Service - Optimized" \
  --aliases provisioning.openclaw.rocks \
  --viewer-certificate CloudFrontDefaultCertificate=true
```

#### 2. 配置 Cache Policies

```bash
# Static Assets - Aggressive caching
aws cloudfront create-cache-policy --cache-policy-config '{
  "Name": "OpenClaw-StaticAssets",
  "Comment": "1 year cache for JS/CSS/images",
  "DefaultTTL": 86400,
  "MaxTTL": 31536000,
  "MinTTL": 86400,
  "ParametersInCacheKeyAndForwardedToOrigin": {
    "EnableAcceptEncodingGzip": true,
    "EnableAcceptEncodingBrotli": true,
    "HeadersConfig": {
      "HeaderBehavior": "none"
    },
    "CookiesConfig": {
      "CookieBehavior": "none"
    },
    "QueryStringsConfig": {
      "QueryStringBehavior": "none"
    }
  }
}'

# HTML Pages - Short cache
aws cloudfront create-cache-policy --cache-policy-config '{
  "Name": "OpenClaw-HTMLPages",
  "Comment": "1 hour cache for HTML pages",
  "DefaultTTL": 3600,
  "MaxTTL": 86400,
  "MinTTL": 0,
  "ParametersInCacheKeyAndForwardedToOrigin": {
    "EnableAcceptEncodingGzip": true,
    "EnableAcceptEncodingBrotli": true,
    "HeadersConfig": {
      "HeaderBehavior": "whitelist",
      "Headers": {
        "Quantity": 1,
        "Items": ["Accept-Language"]
      }
    },
    "CookiesConfig": {
      "CookieBehavior": "none"
    },
    "QueryStringsConfig": {
      "QueryStringBehavior": "none"
    }
  }
}'

# API Endpoints - No cache
aws cloudfront create-cache-policy --cache-policy-config '{
  "Name": "OpenClaw-API",
  "Comment": "No cache for API endpoints",
  "DefaultTTL": 0,
  "MaxTTL": 0,
  "MinTTL": 0,
  "ParametersInCacheKeyAndForwardedToOrigin": {
    "EnableAcceptEncodingGzip": false,
    "HeadersConfig": {
      "HeaderBehavior": "whitelist",
      "Headers": {
        "Quantity": 2,
        "Items": ["Authorization", "Content-Type"]
      }
    },
    "CookiesConfig": {
      "CookieBehavior": "all"
    },
    "QueryStringsConfig": {
      "QueryStringBehavior": "all"
    }
  }
}'
```

#### 3. 更新 DNS

```bash
# Route53 CNAME record
aws route53 change-resource-record-sets --hosted-zone-id Z1234567890ABC --change-batch '{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "provisioning.openclaw.rocks",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{"Value": "d3ik6njnl847zd.cloudfront.net"}]
    }
  }]
}'
```

### 预期收益

| 指标 | 当前 | 优化后 | 提升 |
|------|------|--------|------|
| **静态资源延迟** | 100-200ms | 10-50ms | 75%↓ |
| **API Gateway 请求** | 100% | 10% | 90%↓ |
| **月成本 (100 用户)** | $150 | $15 | 90%↓ |
| **全球访问** | Region only | Edge locations | ✅ |

---

## 方案 2：共享 ALB 架构（中期）

### 架构图

```
┌──────────────────────────────────────────────────────────┐
│  CloudFront Distribution (single, shared)                │
│  - gateway.openclaw.rocks                                │
│  - Origin: Shared Public ALB                             │
└───────────────────────┬──────────────────────────────────┘
                        │
┌───────────────────────▼──────────────────────────────────┐
│  Shared Public ALB (openclaw-shared-alb)                 │
│                                                            │
│  Path-based routing:                                     │
│  - /api/provision      → provisioning-service            │
│  - /api/status/*       → provisioning-service            │
│  - /api/delete/*       → provisioning-service            │
│  - /api/devices/*      → provisioning-service            │
│  - /dashboard          → provisioning-service            │
│  - /login              → provisioning-service            │
│  - /static/*           → provisioning-service            │
│  - /gateway/{user_id}  → openclaw-{user_id} service      │
│  - /ws/{user_id}       → openclaw-{user_id} (WebSocket)  │
└───────────────────────┬──────────────────────────────────┘
                        │
┌───────────────────────▼──────────────────────────────────┐
│  EKS Cluster                                             │
│  - Namespace: openclaw-provisioning                      │
│  - Namespace: openclaw-{user_id} (per user)             │
└──────────────────────────────────────────────────────────┘
```

### 实施步骤

#### 1. 创建共享 Public ALB

```bash
# 创建 ALB
aws elbv2 create-load-balancer \
  --name openclaw-shared-alb \
  --subnets subnet-08a07253e176e1909 subnet-05abc2d68c50fd8ae \
  --security-groups sg-0dd3a5ac049f8f148 \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --tags Key=Environment,Value=production Key=Service,Value=openclaw

# 创建 Target Groups
# 1. Provisioning service
aws elbv2 create-target-group \
  --name openclaw-provisioning-tg \
  --protocol HTTP \
  --port 80 \
  --vpc-id vpc-0123456789abcdef0 \
  --target-type ip \
  --health-check-path /health

# 2. Dynamic target groups for user instances (created by operator)
```

#### 2. 更新 Kubernetes Ingress

```yaml
# shared-alb-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: openclaw-shared-ingress
  namespace: openclaw-system
  annotations:
    alb.ingress.kubernetes.io/load-balancer-name: openclaw-shared-alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-west-2:xxx:certificate/xxx
spec:
  ingressClassName: alb
  rules:
  - host: gateway.openclaw.rocks
    http:
      paths:
      # Provisioning service routes
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80

      - path: /dashboard
        pathType: Exact
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80

      - path: /login
        pathType: Exact
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

      # User instance routes (dynamic)
      # Note: Requires external-dns or manual DNS updates
      - path: /gateway
        pathType: Prefix
        backend:
          service:
            name: openclaw-gateway-router
            port:
              number: 80
```

#### 3. 创建 Gateway Router Service

```python
# gateway-router-service/app.py
from flask import Flask, request, redirect
import re

app = Flask(__name__)

@app.route('/gateway/<user_id>', defaults={'path': ''})
@app.route('/gateway/<user_id>/<path:path>')
def route_to_user_instance(user_id, path):
    """
    路由请求到对应用户的 OpenClaw instance
    """
    # 验证 user_id 格式 (8 位 hex)
    if not re.match(r'^[a-f0-9]{8}$', user_id):
        return {'error': 'Invalid user_id'}, 400

    # 转发到用户的 Service
    # Kubernetes Service DNS: openclaw-{user_id}.openclaw-{user_id}.svc.cluster.local
    target_url = f'http://openclaw-{user_id}.openclaw-{user_id}.svc.cluster.local:18789/{path}'

    # 使用 X-Forwarded-* headers 保留原始请求信息
    headers = {
        'X-Forwarded-For': request.remote_addr,
        'X-Forwarded-Proto': request.scheme,
        'X-Forwarded-Host': request.host,
        'X-Original-Path': request.path
    }

    # Proxy request
    import requests
    response = requests.request(
        method=request.method,
        url=target_url,
        headers=headers,
        data=request.get_data(),
        cookies=request.cookies,
        allow_redirects=False
    )

    return response.content, response.status_code, response.headers.items()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)
```

#### 4. 更新 OpenClaw Operator

修改 operator 创建 Service 时的 annotation：

```go
// internal/resources/service.go
func BuildService(instance *openclawv1alpha1.OpenClawInstance) *corev1.Service {
    return &corev1.Service{
        ObjectMeta: metav1.ObjectMeta{
            Name:      instance.Name,
            Namespace: instance.Namespace,
            Annotations: map[string]string{
                // 新增：注册到共享 ALB
                "alb.ingress.kubernetes.io/target-group-arn": getSharedALBTargetGroup(instance),
                "external-dns.alpha.kubernetes.io/hostname": fmt.Sprintf("gateway.openclaw.rocks/gateway/%s", instance.Spec.UserID),
            },
        },
        Spec: corev1.ServiceSpec{
            Type: corev1.ServiceTypeClusterIP,  // 不再创建独立 ALB
            Ports: []corev1.ServicePort{
                {
                    Name:       "http",
                    Port:       18789,
                    TargetPort: intstr.FromInt(18789),
                },
            },
            Selector: map[string]string{
                "app.kubernetes.io/name":     "openclaw",
                "app.kubernetes.io/instance": instance.Name,
            },
        },
    }
}
```

#### 5. 更新前端 URL 生成

```python
# eks-pod-service/app/api/provision.py
def generate_gateway_url(user_id):
    """生成用户 gateway URL"""
    # 旧: https://{user_id}.cloudfront.net
    # 新: https://gateway.openclaw.rocks/gateway/{user_id}
    return f"https://gateway.openclaw.rocks/gateway/{user_id}"
```

```javascript
// eks-pod-service/app/static/js/dashboard.js
async handleConnectInstance() {
    const gatewayUrl = this.currentInstance.cloudfront_http_url;
    // cloudfront_http_url = "https://gateway.openclaw.rocks/gateway/416e0b5f"
    window.open(gatewayUrl, '_blank');
}
```

### 预期收益

| 指标 | 当前 (100 用户) | 优化后 | 节省 |
|------|----------------|--------|------|
| **ALB 成本** | $1,600/月 (100×) | $16/月 (1×) | 99%↓ |
| **CloudFront 成本** | $300/月 (100×) | $35/月 (1×) | 88%↓ |
| **管理复杂度** | 100 resources | 1 resource | 99%↓ |
| **扩展上限** | ~200 用户 | 10,000+ 用户 | 50x↑ |

---

## 方案 3：Lambda@Edge 认证（长期）

### 架构图

```
┌────────────────────────────────────────────────────────────────┐
│  User Browser                                                  │
│  1. Login → Cognito (auth.js already implemented)             │
│  2. Get idToken, store in localStorage                        │
│  3. Send Authorization: Bearer {token}                        │
└───────────────────────────┬────────────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────────────┐
│  CloudFront Distribution                                       │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │  Lambda@Edge (Viewer Request)                            │ │
│  │  Region: us-east-1 (replicated to all edges)             │ │
│  │                                                            │ │
│  │  Logic:                                                   │ │
│  │  1. Extract JWT from Authorization header                │ │
│  │  2. Verify JWT signature with Cognito JWKS (cached)      │ │
│  │  3. Return 401 if invalid/expired                        │ │
│  │  4. Forward to origin with X-User-Email, X-Cognito-Sub   │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                                 │
│  Cache Behaviors:                                              │
│  - /static/*      → Cache, no auth                            │
│  - /api/*         → No cache, auth required                   │
│  - /login         → Cache, no auth (public)                   │
│  - /dashboard     → Cache 1h, auth required                   │
└───────────────────────────┬────────────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────────────┐
│  Shared ALB                                                    │
│  - Security Group: Only CloudFront IPs                        │
│  - Custom header: X-CloudFront-Secret (origin verification)   │
└───────────────────────────┬────────────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────────────┐
│  Provisioning Service (Flask)                                  │
│  - No JWT verification needed (Lambda@Edge already verified)  │
│  - Trusts X-User-Email, X-Cognito-Sub from CloudFront        │
└────────────────────────────────────────────────────────────────┘
```

### Lambda@Edge 实现

#### 1. 创建 Lambda 函数

```python
# lambda_edge_auth/index.py
import json
import jwt
import requests
from functools import lru_cache
import time
import base64

# Cognito 配置
COGNITO_REGION = 'us-west-2'
USER_POOL_ID = 'us-west-2_gvOCTiLQE'
CLIENT_ID = 'f5qd2udi8508dd132d72qn7uc'
COGNITO_JWKS_URL = f'https://cognito-idp.{COGNITO_REGION}.amazonaws.com/{USER_POOL_ID}/.well-known/jwks.json'

# Lambda@Edge 内存缓存 (容器复用时有效)
_jwks_cache = None
_jwks_cache_time = 0
JWKS_CACHE_TTL = 3600  # 1 hour

def get_jwks():
    """获取并缓存 JWKS"""
    global _jwks_cache, _jwks_cache_time

    now = time.time()
    if _jwks_cache and (now - _jwks_cache_time) < JWKS_CACHE_TTL:
        return _jwks_cache

    response = requests.get(COGNITO_JWKS_URL, timeout=2)
    _jwks_cache = response.json()
    _jwks_cache_time = now
    return _jwks_cache

def get_public_key(token):
    """从 JWKS 获取公钥"""
    jwks = get_jwks()

    # 获取 token header
    unverified_header = jwt.get_unverified_header(token)
    kid = unverified_header['kid']

    # 查找匹配的公钥
    for key in jwks['keys']:
        if key['kid'] == kid:
            return jwt.algorithms.RSAAlgorithm.from_jwk(json.dumps(key))

    raise ValueError(f'Public key not found for kid: {kid}')

def verify_token(token):
    """验证 JWT token"""
    try:
        public_key = get_public_key(token)

        # 验证 token
        claims = jwt.decode(
            token,
            public_key,
            algorithms=['RS256'],
            audience=CLIENT_ID,
            issuer=f'https://cognito-idp.{COGNITO_REGION}.amazonaws.com/{USER_POOL_ID}'
        )

        return {
            'valid': True,
            'claims': claims
        }

    except jwt.ExpiredSignatureError:
        return {'valid': False, 'error': 'Token expired'}
    except jwt.InvalidTokenError as e:
        return {'valid': False, 'error': f'Invalid token: {str(e)}'}
    except Exception as e:
        return {'valid': False, 'error': f'Verification failed: {str(e)}'}

def extract_token(request):
    """从请求中提取 JWT token"""
    headers = request.get('headers', {})

    # 优先：Authorization header
    auth_header = headers.get('authorization', [{}])[0].get('value', '')
    if auth_header.startswith('Bearer '):
        return auth_header[7:]

    # 备选：Cookie
    cookie_header = headers.get('cookie', [{}])[0].get('value', '')
    for cookie in cookie_header.split(';'):
        if 'idToken=' in cookie:
            return cookie.split('idToken=')[1].split(';')[0]

    return None

def is_public_path(uri):
    """判断是否是公开路径（不需要认证）"""
    public_paths = ['/login', '/health', '/static/']
    return any(uri.startswith(path) for path in public_paths)

def create_error_response(status, message):
    """创建错误响应"""
    return {
        'status': str(status),
        'statusDescription': 'Unauthorized' if status == 401 else 'Forbidden',
        'body': json.dumps({'error': message}),
        'headers': {
            'content-type': [{'key': 'Content-Type', 'value': 'application/json'}],
            'cache-control': [{'key': 'Cache-Control', 'value': 'no-store'}]
        }
    }

def lambda_handler(event, context):
    """Lambda@Edge 主函数"""
    request = event['Records'][0]['cf']['request']
    uri = request['uri']

    # 公开路径：直接放行
    if is_public_path(uri):
        return request

    # 提取 token
    token = extract_token(request)
    if not token:
        return create_error_response(401, 'Missing authentication token')

    # 验证 token
    result = verify_token(token)
    if not result['valid']:
        return create_error_response(401, result['error'])

    # 验证成功：添加用户信息到 headers
    claims = result['claims']
    request['headers']['x-user-email'] = [{
        'key': 'X-User-Email',
        'value': claims.get('email', '')
    }]
    request['headers']['x-cognito-sub'] = [{
        'key': 'X-Cognito-Sub',
        'value': claims.get('sub', '')
    }]
    request['headers']['x-cognito-username'] = [{
        'key': 'X-Cognito-Username',
        'value': claims.get('cognito:username', '')
    }]

    return request
```

#### 2. 部署 Lambda@Edge

```bash
# 打包依赖
cd lambda_edge_auth
pip install -t . pyjwt requests cryptography
zip -r lambda_edge_auth.zip .

# 创建 Lambda 函数 (必须在 us-east-1)
aws lambda create-function \
  --region us-east-1 \
  --function-name openclaw-cloudfront-auth \
  --runtime python3.11 \
  --role arn:aws:iam::970547376847:role/lambda-edge-execution-role \
  --handler index.lambda_handler \
  --zip-file fileb://lambda_edge_auth.zip \
  --timeout 5 \
  --memory-size 128 \
  --publish

# 获取版本 ARN
LAMBDA_VERSION_ARN=$(aws lambda list-versions-by-function \
  --region us-east-1 \
  --function-name openclaw-cloudfront-auth \
  --query 'Versions[-1].FunctionArn' \
  --output text)

echo "Lambda Version ARN: $LAMBDA_VERSION_ARN"
```

#### 3. 关联到 CloudFront

```bash
# 更新 CloudFront distribution
aws cloudfront update-distribution --id E1234567890ABC --distribution-config '{
  "Comment": "OpenClaw Gateway with Lambda@Edge Auth",
  "DefaultCacheBehavior": {
    "TargetOriginId": "shared-alb-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 7,
      "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    },
    "LambdaFunctionAssociations": {
      "Quantity": 1,
      "Items": [{
        "LambdaFunctionARN": "'$LAMBDA_VERSION_ARN'",
        "EventType": "viewer-request",
        "IncludeBody": false
      }]
    }
  }
}'
```

#### 4. 更新后端（移除 JWT 验证）

```python
# eks-pod-service/app/utils/cloudfront_auth.py
from flask import request

def get_user_from_cloudfront_headers():
    """
    从 CloudFront 转发的 headers 中获取用户信息
    Lambda@Edge 已经验证过 JWT，这里直接信任
    """
    return {
        'user_email': request.headers.get('X-User-Email'),
        'cognito_sub': request.headers.get('X-Cognito-Sub'),
        'cognito_username': request.headers.get('X-Cognito-Username')
    }

def require_cloudfront_auth(f):
    """
    装饰器：验证请求来自 CloudFront（通过 secret header）
    """
    def decorated_function(*args, **kwargs):
        # 验证 CloudFront secret header
        secret = request.headers.get('X-CloudFront-Secret')
        if secret != os.environ.get('CLOUDFRONT_SECRET'):
            return jsonify({'error': 'Forbidden'}), 403

        # 获取用户信息
        user_info = get_user_from_cloudfront_headers()
        if not user_info['user_email']:
            return jsonify({'error': 'Missing user information'}), 401

        return f(user_info=user_info, *args, **kwargs)

    return decorated_function
```

```python
# eks-pod-service/app/api/provision.py
from app.utils.cloudfront_auth import require_cloudfront_auth, get_user_from_cloudfront_headers

@provision_bp.route('/api/provision', methods=['POST'])
@require_cloudfront_auth
def provision_instance(user_info):
    """Create OpenClaw instance - authenticated by Lambda@Edge"""
    user_email = user_info['user_email']
    # ... 创建逻辑
```

### 性能和成本对比

| 指标 | API Gateway | Lambda@Edge | 改善 |
|------|-------------|-------------|------|
| **认证延迟** | 100-150ms (region) | 20-50ms (edge) | 66%↓ |
| **请求成本 (百万)** | $3.50 | $0.60 | 83%↓ |
| **全球覆盖** | Single region | 400+ edges | ✅ |
| **JWKS 查询** | 每次 | 缓存 1h | 99%↓ |

---

## 方案 4：ALB OIDC 集成（可选）

### 架构图

```
┌────────────────────────────────────────────────────────────────┐
│  User Browser                                                  │
│  - Access URL → 302 redirect to Cognito Hosted UI            │
└───────────────────────────┬────────────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────────────┐
│  CloudFront Distribution                                       │
│  - Simple pass-through                                         │
└───────────────────────────┬────────────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────────────┐
│  ALB with OIDC Authentication                                  │
│                                                                 │
│  Listener Rule:                                                │
│  - Type: authenticate-oidc                                     │
│  - Issuer: cognito-idp.us-west-2.amazonaws.com/...            │
│  - ClientId: f5qd2udi8508dd132d72qn7uc                        │
│  - OnUnauthenticatedRequest: authenticate                     │
│  - SessionCookieName: AWSELBAuthSessionCookie                 │
│  - SessionTimeout: 86400                                       │
│                                                                 │
│  Flow:                                                          │
│  1. User not authenticated → 302 to Cognito                   │
│  2. User logs in → Cognito callback to ALB                    │
│  3. ALB validates → Sets session cookie → Forward to target   │
└───────────────────────────┬────────────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────────────┐
│  EKS Provisioning Service                                      │
│  - Receives X-Amzn-Oidc-Data header (user info JWT)          │
│  - No verification needed (ALB already verified)               │
└────────────────────────────────────────────────────────────────┘
```

### 实施步骤

#### 1. 配置 ALB OIDC

```bash
# 创建 OIDC 认证 action
aws elbv2 create-rule \
  --listener-arn arn:aws:elasticloadbalancing:us-west-2:970547376847:listener/app/openclaw-shared-alb/xxx/xxx \
  --priority 1 \
  --conditions Field=path-pattern,Values='/*' \
  --actions \
    Type=authenticate-oidc,Order=1,AuthenticateOidcConfig='{
      Issuer=https://cognito-idp.us-west-2.amazonaws.com/us-west-2_gvOCTiLQE,
      AuthorizationEndpoint=https://openclaw.auth.us-west-2.amazoncognito.com/oauth2/authorize,
      TokenEndpoint=https://openclaw.auth.us-west-2.amazoncognito.com/oauth2/token,
      UserInfoEndpoint=https://openclaw.auth.us-west-2.amazoncognito.com/oauth2/userInfo,
      ClientId=f5qd2udi8508dd132d72qn7uc,
      ClientSecret=<from-cognito>,
      SessionCookieName=AWSELBAuthSessionCookie,
      SessionTimeout=86400,
      Scope=openid email profile,
      OnUnauthenticatedRequest=authenticate,
      UseExistingClientSecret=true
    }' \
    Type=forward,Order=2,TargetGroupArn=arn:aws:elasticloadbalancing:us-west-2:970547376847:targetgroup/openclaw-provisioning/xxx
```

#### 2. 更新 Cognito App Client

```bash
# 添加 ALB callback URL
aws cognito-idp update-user-pool-client \
  --user-pool-id us-west-2_gvOCTiLQE \
  --client-id f5qd2udi8508dd132d72qn7uc \
  --callback-urls \
    "https://gateway.openclaw.rocks/oauth2/idpresponse" \
    "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/login" \
  --allowed-o-auth-flows authorization_code \
  --allowed-o-auth-scopes openid email profile \
  --supported-identity-providers COGNITO
```

#### 3. 后端处理 OIDC Headers

```python
# eks-pod-service/app/utils/alb_oidc.py
import json
import base64
from flask import request

def get_user_from_alb_oidc():
    """
    从 ALB OIDC headers 提取用户信息
    ALB 已经验证了 token，这里直接解码 payload
    """
    oidc_data = request.headers.get('X-Amzn-Oidc-Data')
    if not oidc_data:
        return None

    # ALB 传递的是 JWT: header.payload.signature
    try:
        parts = oidc_data.split('.')
        if len(parts) != 3:
            return None

        # 解码 payload (base64url)
        payload = parts[1]
        # 添加 padding
        payload += '=' * (4 - len(payload) % 4)
        decoded = base64.urlsafe_b64decode(payload)
        claims = json.loads(decoded)

        return {
            'user_email': claims.get('email'),
            'cognito_sub': claims.get('sub'),
            'cognito_username': claims.get('cognito:username')
        }
    except Exception as e:
        print(f"Error decoding OIDC data: {e}")
        return None

def require_alb_oidc(f):
    """装饰器：从 ALB OIDC 获取用户信息"""
    def decorated_function(*args, **kwargs):
        user_info = get_user_from_alb_oidc()
        if not user_info:
            return jsonify({'error': 'Unauthorized'}), 401

        return f(user_info=user_info, *args, **kwargs)

    return decorated_function
```

```python
# eks-pod-service/app/api/provision.py
from app.utils.alb_oidc import require_alb_oidc

@provision_bp.route('/api/provision', methods=['POST'])
@require_alb_oidc
def provision_instance(user_info):
    """Create OpenClaw instance - authenticated by ALB OIDC"""
    user_email = user_info['user_email']
    # ... 创建逻辑
```

### 优势和限制

**优势**：
- ✅ **零代码认证**：完全由 ALB 管理
- ✅ **AWS 原生集成**：稳定可靠
- ✅ **自动 session 管理**：Cookie 自动刷新
- ✅ **无 Lambda 成本**

**限制**：
- ❌ **必须用 Cognito Hosted UI**：无法自定义登录页面
- ❌ **Session cookie 限制**：最大 16KB
- ❌ **CloudFront 缓存限制**：带 cookie 的请求难以缓存
- ❌ **重定向流程**：每次登录都会跳转到 Cognito UI

---

## 成本对比分析

### 假设：100 用户，每用户 100 请求/天

| 成本项 | 当前架构 | 方案 1 | 方案 2 | 方案 3 | 方案 4 |
|--------|---------|--------|--------|--------|--------|
| **API Gateway** | $150/月 | $15/月 | $0 | $0 | $0 |
| **ALB** | $1,600/月<br>(100×$16) | $1,600/月 | $16/月<br>(1×) | $16/月 | $16/月 |
| **CloudFront** | $300/月<br>(100×) | $335/月<br>(100+1) | $35/月<br>(1×) | $35/月 | $35/月 |
| **Lambda@Edge** | $0 | $0 | $0 | $18/月 | $0 |
| **数据传输** | $100/月 | $100/月 | $50/月 | $50/月 | $50/月 |
| **总计** | **$2,150/月** | **$2,050/月** | **$101/月** | **$119/月** | **$101/月** |
| **节省** | - | 5% | **95%** | **94%** | **95%** |

### 扩展到 1000 用户

| 成本项 | 当前架构 | 方案 2 | 方案 3 |
|--------|---------|--------|--------|
| **ALB** | $16,000/月 | $16/月 | $16/月 |
| **CloudFront** | $3,000/月 | $350/月 | $350/月 |
| **API Gateway** | $1,500/月 | $0 | $0 |
| **Lambda@Edge** | $0 | $0 | $180/月 |
| **总计** | **$20,500/月** | **$1,366/月** | **$1,546/月** |
| **节省** | - | **93%** | **92%** |

---

## 实施路线图

### Phase 1: 快速优化（1 周）

**目标**: 降低 90% 静态资源成本

**任务**:
1. ✅ 创建 CloudFront distribution (origin: API Gateway)
2. ✅ 配置缓存策略 (/static/* 缓存 1 天)
3. ✅ 更新 DNS (provisioning subdomain)
4. ✅ 监控和验证

**风险**: 低
**收益**: API Gateway 请求降低 90%

---

### Phase 2: 架构重构（3-6 周）

**目标**: 统一 ALB + CloudFront，支持 1000+ 用户

**Week 1-2: 基础设施**
- [ ] 创建共享 Public ALB
- [ ] 配置 Security Group (只允许 CloudFront)
- [ ] 创建 Target Groups
- [ ] 部署 Gateway Router Service

**Week 3-4: Operator 改造**
- [ ] 修改 Service 创建逻辑（使用共享 ALB）
- [ ] 更新 Ingress 配置
- [ ] 测试动态路由

**Week 5-6: 前端和灰度**
- [ ] 更新前端 URL 生成逻辑
- [ ] 灰度迁移（新用户用新架构）
- [ ] 监控和调优
- [ ] 完全切换

**风险**: 中
**收益**: 成本降低 90%+，扩展性提升 50x

---

### Phase 3: Lambda@Edge 认证（可选，3-4 周）

**目标**: 移除 API Gateway，进一步降低成本和延迟

**Week 1-2: Lambda@Edge 开发**
- [ ] 开发 JWT 验证逻辑
- [ ] 测试 JWKS 缓存
- [ ] 部署到 us-east-1
- [ ] 关联到 CloudFront

**Week 3: 后端改造**
- [ ] 移除 JWT 验证代码
- [ ] 信任 CloudFront headers
- [ ] 添加 CloudFront Secret 验证

**Week 4: 切换和监控**
- [ ] 灰度切换流量
- [ ] 监控 Lambda 性能和成本
- [ ] 完全移除 API Gateway

**风险**: 中
**收益**: 成本再降 15%，延迟降低 50%

---

## 监控和告警

### 关键指标

```yaml
CloudWatch Metrics:
  API Gateway:
    - Count (请求数)
    - IntegrationLatency (后端延迟)
    - Latency (总延迟)
    - 4XXError, 5XXError

  CloudFront:
    - Requests (请求数)
    - BytesDownloaded (流量)
    - CacheHitRate (缓存命中率)
    - 4xxErrorRate, 5xxErrorRate

  ALB:
    - RequestCount
    - TargetResponseTime
    - HTTPCode_Target_4XX_Count
    - HealthyHostCount

  Lambda@Edge (if applicable):
    - Invocations
    - Duration
    - Errors
    - Throttles

Alarms:
  - CloudFront CacheHitRate < 80%
  - ALB TargetResponseTime > 1000ms
  - Lambda@Edge Errors > 1%
  - API Gateway 5XXError > 0.1%
```

### 成本监控

```bash
# 每日成本报告
aws ce get-cost-and-usage \
  --time-period Start=2026-03-01,End=2026-03-02 \
  --granularity DAILY \
  --metrics BlendedCost \
  --group-by Type=SERVICE \
  --filter file://cost-filter.json

# cost-filter.json
{
  "Tags": {
    "Key": "Service",
    "Values": ["openclaw"]
  }
}
```

---

## 总结

### 推荐实施顺序

1. **立即实施 (本周)**:
   方案 1 - CloudFront 缓存优化
   - 1 天工作量
   - 零风险
   - 立即节省 90% 静态资源成本

2. **3 个月内**:
   方案 2 - 共享 ALB 架构
   - **最关键的优化**
   - 成本从 $2,150 降到 $101 (节省 95%)
   - 支持 10,000+ 用户

3. **6 个月后评估**:
   方案 3 - Lambda@Edge 认证
   - 如果用户量 > 1000，考虑实施
   - 进一步降低成本和延迟

4. **特殊场景**:
   方案 4 - ALB OIDC
   - 仅当可以接受 Cognito Hosted UI
   - 最简单但最受限

### 关键决策点

| 决策 | 推荐 | 原因 |
|------|------|------|
| **自定义登录 UI?** | 是 | 品牌一致性 |
| → 选择 | 方案 1/2/3 | 支持自定义 |
| **预期用户数?** | 1000+ | 规模化需求 |
| → 选择 | 方案 2 | 共享 ALB |
| **预算敏感?** | 高 | 成本优化优先 |
| → 选择 | 方案 2 + 3 | 最低成本 |
| **快速上线?** | 是 | 1 周内见效 |
| → 选择 | 方案 1 | 零风险 |

---

**下一步行动**: 需要我帮你实施方案 1 吗？

**预计时间**: 2 小时
**预计成本节省**: 立即降低 90% 静态资源成本

---

*文档维护者: Claude Code*
*最后更新: 2026-03-06*
