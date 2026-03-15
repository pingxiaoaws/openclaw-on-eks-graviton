# 🚀 快速开始 - 本地认证系统

## 3 步部署

### 1️⃣ 检查前提条件

```bash
# 确保 kubectl 连接到正确的集群
kubectl config current-context

# 确保 EFS StorageClass 存在（用于 session 共享）
kubectl get storageclass efs-sc
```

### 2️⃣ 一键部署

```bash
cd eks-pod-service
./deploy-local-auth.sh
```

脚本会自动：
- ✅ 创建 namespace
- ✅ 生成 SECRET_KEY
- ✅ 构建并推送 Docker 镜像
- ✅ 创建 PVC（数据库 + session）
- ✅ 部署应用（2 副本）

### 3️⃣ 验证

```bash
# Port-forward 到本地
kubectl port-forward -n openclaw-provisioning svc/openclaw-provisioning 8080:80

# 浏览器打开
open http://localhost:8080/login

# 或使用 curl 测试
curl -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","email":"test@example.com","password":"test1234"}'
```

---

## 使用示例

### 注册和登录

```bash
# 1. 注册
curl -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{
    "username": "johndoe",
    "email": "john@example.com",
    "password": "securepass123"
  }'

# 2. 登录（保存 cookie）
curl -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -c cookies.txt \
  -d '{
    "email": "john@example.com",
    "password": "securepass123"
  }'

# 3. 使用 cookie 创建实例
curl -X POST http://localhost:8080/provision \
  -H "Content-Type: application/json" \
  -b cookies.txt
```

---

## 主要变更

| 之前（Cognito） | 现在（Local Auth） |
|----------------|-------------------|
| AWS Cognito User Pool | SQLite 数据库 |
| JWT token 认证 | Session cookie 认证 |
| 无注册功能（管理员创建） | 用户自助注册 |
| python-jose 依赖 | bcrypt + flask-session |

---

## 下一步

- 📖 阅读完整文档：[README-LOCAL-AUTH.md](./README-LOCAL-AUTH.md)
- 🔧 查看迁移详情：[MIGRATION-TO-LOCAL-AUTH.md](./MIGRATION-TO-LOCAL-AUTH.md)

**问题？** 查看 [README-LOCAL-AUTH.md](./README-LOCAL-AUTH.md) 的故障排查部分
