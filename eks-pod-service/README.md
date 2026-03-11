# OpenClaw Provisioning Service

EKS Pod 服务，用于自动创建和管理 OpenClaw 实例。

## 架构

```
Cognito User Pool
   ↓
Lambda / API Gateway
   ↓
Provisioning Service (EKS Pod)
   ├─> 创建 Namespace
   ├─> 创建 ResourceQuota
   ├─> 创建 NetworkPolicy
   └─> 创建 OpenClawInstance CRD
   ↓
OpenClaw Operator
   └─> 创建 StatefulSet + Service + PVC
```

## 功能特性

- ✅ **自动化实例创建**: 根据用户信息自动创建 OpenClaw 实例
- ✅ **幂等性**: 多次调用相同请求返回相同结果
- ✅ **原生 K8s**: 使用 ServiceAccount，无需管理外部凭证
- ✅ **高可用**: 多副本 + HPA + PDB
- ✅ **可观测性**: 结构化日志 + 健康检查

## 项目结构

```
eks-pod-service/
├── app/
│   ├── __init__.py
│   ├── main.py              # Flask 应用入口
│   ├── config.py            # 配置管理
│   ├── api/                 # API 端点
│   │   ├── provision.py     # POST /provision
│   │   ├── status.py        # GET /status/<user_id>
│   │   ├── delete.py        # DELETE /delete/<user_id>
│   │   └── health.py        # GET /health
│   ├── k8s/                 # Kubernetes 操作
│   │   ├── client.py        # K8s 客户端封装
│   │   ├── namespace.py
│   │   ├── quota.py
│   │   ├── netpol.py
│   │   └── instance.py
│   ├── utils/               # 工具函数
│   │   ├── user_id.py
│   │   └── validator.py
│   └── middleware/          # 中间件
│       ├── logging.py
│       └── error_handler.py
├── kubernetes/              # K8s 部署文件
│   ├── rbac.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── hpa.yaml
│   └── pdb.yaml
├── Dockerfile
├── requirements.txt
├── gunicorn.conf.py
└── README.md
```

## API 文档

### 1. 创建实例

**POST /provision**

Request:
```json
{
  "email": "user@example.com",
  "cognito_sub": "xxx-xxx-xxx",
  "config": {
    "resources": {
      "requests": {"cpu": "1", "memory": "2Gi"}
    }
  }
}
```

Response (201 Created):
```json
{
  "status": "created",
  "user_id": "7ec7606c",
  "namespace": "openclaw-7ec7606c",
  "instance_name": "openclaw-7ec7606c",
  "gateway_endpoint": "openclaw-7ec7606c.openclaw-7ec7606c.svc:18789",
  "message": "Instance created successfully"
}
```

### 2. 查询状态

**GET /status/<user_id>**

Response (200 OK):
```json
{
  "user_id": "7ec7606c",
  "namespace": "openclaw-7ec7606c",
  "instance_name": "openclaw-7ec7606c",
  "status": {
    "phase": "Running",
    "ready": true
  }
}
```

### 3. 删除实例

**DELETE /delete/<user_id>**

Response (200 OK):
```json
{
  "status": "deleted",
  "user_id": "7ec7606c",
  "message": "Instance deleted successfully"
}
```

### 4. 健康检查

**GET /health**

Response (200 OK):
```json
{
  "status": "healthy",
  "k8s_api": "connected"
}
```

## 部署指南

### 前置条件

1. EKS 集群 (已配置 Kata Containers)
2. kubectl 配置正确
3. AWS ECR 仓库
4. OpenClaw Operator 已部署

### 步骤 1: 构建镜像

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata/eks-pod-service

# 登录 ECR
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin 111122223333.dkr.ecr.us-west-2.amazonaws.com

# 创建 ECR 仓库
aws ecr create-repository \
  --repository-name openclaw-provisioning \
  --region us-west-2

# 构建镜像（多架构）
docker buildx build --platform linux/amd64,linux/arm64 \
  -t 111122223333.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest \
  --push .

# 或单架构构建
docker build -t openclaw-provisioning .
docker tag openclaw-provisioning:latest \
  111122223333.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest
docker push 111122223333.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest
```

### 步骤 2: 更新部署配置

编辑 `kubernetes/deployment.yaml`，替换镜像地址：

```yaml
image: 111122223333.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest
```

### 步骤 3: 部署到 EKS

```bash
# 应用 RBAC
kubectl apply -f kubernetes/rbac.yaml

# 部署应用
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml
kubectl apply -f kubernetes/hpa.yaml
kubectl apply -f kubernetes/pdb.yaml

# 验证部署
kubectl get all -n openclaw-provisioning
```

### 步骤 4: 测试

```bash
# 端口转发（本地测试）
kubectl port-forward -n openclaw-provisioning svc/openclaw-provisioning 8080:80

# 测试健康检查
curl http://localhost:8080/health

# 测试创建实例
curl -X POST http://localhost:8080/provision \
  -H "Content-Type: application/json" \
  -d '{
    "email": "testuser@example.com",
    "cognito_sub": "test-sub-123"
  }'

# 查询状态
USER_ID=$(echo -n "testuser@example.com" | md5sum | cut -c1-8)
curl http://localhost:8080/status/$USER_ID
```

## 本地开发

### 运行服务

```bash
# 安装依赖
pip install -r requirements.txt

# 运行服务（需要配置 kubectl）
python -m app.main

# 或使用 Gunicorn
gunicorn -c gunicorn.conf.py app.main:app
```

### 测试

```bash
# 单元测试（TODO）
pytest tests/

# 集成测试
./test_integration.sh
```

## 监控

### 日志

```bash
# 查看日志
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning -f

# 查看特定 Pod
kubectl logs -n openclaw-provisioning openclaw-provisioning-xxx -f
```

### 指标

```bash
# Pod 资源使用
kubectl top pod -n openclaw-provisioning

# HPA 状态
kubectl get hpa -n openclaw-provisioning -w
```

## 故障排查

### 问题 1: Pod 无法启动

```bash
# 查看 Pod 事件
kubectl describe pod -n openclaw-provisioning openclaw-provisioning-xxx

# 查看日志
kubectl logs -n openclaw-provisioning openclaw-provisioning-xxx
```

### 问题 2: 无法连接 K8s API

```bash
# 验证 ServiceAccount
kubectl get sa openclaw-provisioner -n openclaw-provisioning

# 验证 RBAC
kubectl auth can-i create namespace \
  --as=system:serviceaccount:openclaw-provisioning:openclaw-provisioner
```

### 问题 3: 实例创建失败

```bash
# 查看 Provisioning Service 日志
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=100

# 检查 OpenClaw Operator
kubectl get deployment -n openclaw-operator-system
kubectl logs -n openclaw-operator-system deployment/openclaw-operator
```

## 配置

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `LOG_LEVEL` | 日志级别 | `INFO` |
| `DEBUG` | Debug 模式 | `false` |
| `SECRET_KEY` | Flask 密钥 | 自动生成 |

### OpenClaw 默认配置

在 `app/config.py` 中修改 `OPENCLAW_DEFAULTS`:

```python
OPENCLAW_DEFAULTS = {
    'runtime_class': 'kata-fc',
    'node_selector': {'workload-type': 'kata'},
    'resources': {
        'requests': {'cpu': '600m', 'memory': '1.2Gi'},
        'limits': {'cpu': '2', 'memory': '4Gi'}
    },
    'storage_size': '10Gi',
    'storage_class': 'gp3',
    'model': 'bedrock/us.anthropic.claude-opus-4-6-v1:0'
}
```

## 安全

### RBAC 权限

Provisioning Service 具有以下权限：

- ✅ 创建 Namespace
- ✅ 创建 ResourceQuota、NetworkPolicy
- ✅ 创建 OpenClawInstance CRD
- ✅ 查询 Pod 状态（只读）
- ❌ 不能删除集群级资源
- ❌ 不能修改其他 Namespace

### 网络安全

- Pod 运行为非 root 用户
- 只读根文件系统（可选）
- NetworkPolicy 限制流量

## 集成 Cognito

### Lambda Trigger 方式

```python
# cognito_trigger_lambda.py
import requests
import os

PROVISIONING_ENDPOINT = os.environ['PROVISIONING_ENDPOINT']

def lambda_handler(event, context):
    user_email = event['request']['userAttributes']['email']
    cognito_sub = event['request']['userAttributes']['sub']

    response = requests.post(
        f"{PROVISIONING_ENDPOINT}/provision",
        json={
            "email": user_email,
            "cognito_sub": cognito_sub
        },
        timeout=30
    )

    print(f"Provisioning result: {response.status_code}")
    return event
```

### API Gateway 方式

配置 API Gateway HTTP API，使用 Cognito Authorizer，VPC Link 连接到 Provisioning Service。

## 许可证

MIT

## 联系方式

Claude Code - OpenClaw Provisioning Service
