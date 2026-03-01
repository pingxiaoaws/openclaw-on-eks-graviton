# 快速开始指南

## 🚀 5 分钟部署

### 前置条件

- ✅ EKS 集群 (test-s4) 已配置
- ✅ kubectl 已配置
- ✅ AWS CLI 已配置
- ✅ Docker 已安装
- ✅ OpenClaw Operator 已部署

### 一键部署

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata/eks-pod-service

# 执行部署脚本
./deploy.sh
```

部署脚本会自动：
1. ✅ 构建 Docker 镜像
2. ✅ 推送到 ECR
3. ✅ 部署到 EKS
4. ✅ 验证部署状态

### 手动部署（逐步）

#### 步骤 1: 构建镜像

```bash
# 登录 ECR
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin 970547376847.dkr.ecr.us-west-2.amazonaws.com

# 创建仓库（首次）
aws ecr create-repository --repository-name openclaw-provisioning --region us-west-2

# 构建并推送
docker build -t openclaw-provisioning .
docker tag openclaw-provisioning:latest \
  970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest
docker push 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest
```

#### 步骤 2: 更新镜像地址

编辑 `kubernetes/deployment.yaml`，第 45 行：

```yaml
image: 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest
```

#### 步骤 3: 部署

```bash
# 应用所有配置
kubectl apply -f kubernetes/rbac.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml
kubectl apply -f kubernetes/hpa.yaml
kubectl apply -f kubernetes/pdb.yaml

# 等待 Pod Ready
kubectl wait --for=condition=available --timeout=300s \
  deployment/openclaw-provisioning -n openclaw-provisioning
```

#### 步骤 4: 验证

```bash
# 查看 Pod
kubectl get pods -n openclaw-provisioning

# 查看日志
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning -f

# 健康检查
kubectl port-forward -n openclaw-provisioning svc/openclaw-provisioning 8080:80
curl http://localhost:8080/health
```

## 🧪 测试

### 本地测试

```bash
# 端口转发
kubectl port-forward -n openclaw-provisioning svc/openclaw-provisioning 8080:80

# 在另一个终端运行测试
./test_api.sh
```

### 测试输出

```
========================================
OpenClaw Provisioning Service API 测试
========================================
Service URL: http://localhost:8080
Test Email: testuser@example.com
User ID: 7ec7606c

→ 测试 1: 健康检查
✓ 健康检查通过
   {"status":"healthy","k8s_api":"connected"}

→ 测试 2: 创建实例
✓ 实例创建成功
   {
     "status": "created",
     "user_id": "7ec7606c",
     "namespace": "openclaw-7ec7606c",
     "instance_name": "openclaw-7ec7606c",
     "gateway_endpoint": "openclaw-7ec7606c.openclaw-7ec7606c.svc:18789"
   }

→ 等待实例就绪 (10 秒)...

→ 测试 3: 查询实例状态
✓ 状态查询成功
   {
     "user_id": "7ec7606c",
     "namespace": "openclaw-7ec7606c",
     "status": {"phase": "Running"}
   }

→ 测试 4: 幂等性测试（再次创建相同实例）
✓ 幂等性测试通过 (实例已存在)

========================================
所有测试完成！
========================================
```

### 手动 API 测试

```bash
# 1. 健康检查
curl http://localhost:8080/health

# 2. 创建实例
curl -X POST http://localhost:8080/provision \
  -H "Content-Type: application/json" \
  -d '{
    "email": "user@example.com",
    "cognito_sub": "xxx-xxx-xxx"
  }'

# 3. 查询状态
USER_ID=$(echo -n "user@example.com" | md5sum | cut -c1-8)
curl http://localhost:8080/status/$USER_ID

# 4. 删除实例
curl -X DELETE http://localhost:8080/delete/$USER_ID
```

## 📊 监控

### 查看资源

```bash
# Pods
kubectl get pods -n openclaw-provisioning

# Service
kubectl get svc -n openclaw-provisioning

# HPA
kubectl get hpa -n openclaw-provisioning

# 资源使用
kubectl top pods -n openclaw-provisioning
```

### 查看日志

```bash
# 实时日志
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning -f

# 最近 100 行
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=100

# 特定 Pod
kubectl logs -n openclaw-provisioning <pod-name> -f
```

### 查看事件

```bash
# Namespace 事件
kubectl get events -n openclaw-provisioning --sort-by='.lastTimestamp'

# Pod 详情
kubectl describe pod -n openclaw-provisioning <pod-name>
```

## 🔧 常见问题

### Q1: Pod 一直 Pending

**原因**: 节点资源不足或 ImagePullBackOff

**解决**:
```bash
# 查看事件
kubectl describe pod -n openclaw-provisioning <pod-name>

# 检查节点资源
kubectl top nodes
```

### Q2: 健康检查失败

**原因**: K8s API 连接失败

**解决**:
```bash
# 检查 RBAC
kubectl auth can-i create namespace \
  --as=system:serviceaccount:openclaw-provisioning:openclaw-provisioner

# 查看日志
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=50
```

### Q3: 实例创建失败

**原因**: OpenClaw Operator 未运行

**解决**:
```bash
# 检查 Operator
kubectl get deployment -n openclaw-operator-system

# 查看 Operator 日志
kubectl logs -n openclaw-operator-system deployment/openclaw-operator
```

## 🔄 更新部署

### 更新镜像

```bash
# 构建新镜像
docker build -t openclaw-provisioning:v2 .
docker tag openclaw-provisioning:v2 \
  970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:v2
docker push 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:v2

# 更新部署
kubectl set image deployment/openclaw-provisioning \
  provisioning=970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:v2 \
  -n openclaw-provisioning

# 查看滚动更新状态
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning
```

### 回滚部署

```bash
# 查看历史
kubectl rollout history deployment/openclaw-provisioning -n openclaw-provisioning

# 回滚到上一个版本
kubectl rollout undo deployment/openclaw-provisioning -n openclaw-provisioning

# 回滚到指定版本
kubectl rollout undo deployment/openclaw-provisioning -n openclaw-provisioning --to-revision=2
```

## 🧹 清理

### 删除部署

```bash
# 删除所有资源
kubectl delete -f kubernetes/

# 或逐个删除
kubectl delete deployment openclaw-provisioning -n openclaw-provisioning
kubectl delete svc openclaw-provisioning -n openclaw-provisioning
kubectl delete hpa openclaw-provisioning -n openclaw-provisioning
kubectl delete pdb openclaw-provisioning -n openclaw-provisioning

# 删除 Namespace
kubectl delete namespace openclaw-provisioning
```

### 删除镜像

```bash
# 删除 ECR 仓库
aws ecr delete-repository \
  --repository-name openclaw-provisioning \
  --region us-west-2 \
  --force
```

## 📚 下一步

1. 集成 Cognito: 参考 [README.md](./README.md#集成-cognito)
2. 配置监控: 参考 [README.md](./README.md#监控)
3. 生产部署: 参考 [EKS-POD-SERVICE-DESIGN.md](../../api-gateway-solution/EKS-POD-SERVICE-DESIGN.md)

## 🆘 获取帮助

- 查看完整文档: [README.md](./README.md)
- 架构设计: [EKS-POD-SERVICE-DESIGN.md](../../api-gateway-solution/EKS-POD-SERVICE-DESIGN.md)
- 大规模部署: [LARGE-SCALE-ARCHITECTURE.md](../../api-gateway-solution/LARGE-SCALE-ARCHITECTURE.md)
