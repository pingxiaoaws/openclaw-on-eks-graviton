# OpenClaw Provisioning Service - 本地认证系统

## 概述

OpenClaw 认证系统已从 **AWS Cognito** 迁移到 **本地用户名/密码认证**。

### 主要特性

✅ **用户注册**：用户名 + 邮箱 + 密码
✅ **本地登录**：基于 SQLite 数据库验证
✅ **Session 认证**：使用 Flask-Session（替代 JWT）
✅ **密码安全**：bcrypt 加密（带 salt）
✅ **多 Pod 支持**：通过 EFS 共享 session
✅ **用户隔离**：每个用户只能访问自己的资源

### 架构变更

**之前（Cognito）：**
```
Frontend → Cognito SDK → JWT token → Backend verifies via JWKS
```

**现在（Local Auth）：**
```
Frontend → /register or /login → SQLite → Session cookie → Backend validates session
```

---

## 快速开始

### 一键部署

```bash
cd eks-pod-service
./deploy-local-auth.sh
```

脚本会自动完成：
1. ✅ 检查环境（kubectl, docker, aws cli）
2. ✅ 创建 Namespace
3. ✅ 生成 SECRET_KEY
4. ✅ 构建并推送 Docker 镜像
5. ✅ 创建 PVC（数据库 + Session）
6. ✅ 部署应用
7. ✅ 等待就绪

### 手动部署

如果需要手动控制每一步：

```bash
# 1. 创建 Namespace
kubectl create namespace openclaw-provisioning

# 2. 创建 SECRET_KEY
kubectl create secret generic openclaw-provisioning-secret \
  --from-literal=secret-key=$(openssl rand -base64 32) \
  -n openclaw-provisioning

# 3. 创建 PVC
kubectl apply -f kubernetes/pvc.yaml

# 4. 构建镜像
docker build -t <ECR_REGISTRY>/openclaw-provisioning:latest .
docker push <ECR_REGISTRY>/openclaw-provisioning:latest

# 5. 部署应用
kubectl apply -f kubernetes/deployment-with-volumes.yaml

# 6. 检查状态
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning
kubectl get pods -n openclaw-provisioning
```

---

## API 文档

### 认证 API

#### 1. 注册用户

```bash
POST /register
Content-Type: application/json

{
  "username": "johndoe",
  "email": "john@example.com",
  "password": "securepass123"
}

# 响应 (201 Created)
{
  "status": "success",
  "message": "User registered successfully",
  "username": "johndoe",
  "email": "john@example.com"
}
```

**密码要求**：
- 至少 8 个字符
- 包含字母和数字

#### 2. 登录

```bash
POST /login
Content-Type: application/json

{
  "email": "john@example.com",
  "password": "securepass123"
}

# 响应 (200 OK)
{
  "status": "success",
  "message": "Login successful",
  "user": {
    "username": "johndoe",
    "email": "john@example.com"
  }
}

# 同时设置 session cookie（自动）
```

#### 3. 登出

```bash
POST /logout

# 响应 (200 OK)
{
  "status": "success",
  "message": "Logout successful"
}
```

#### 4. 获取当前用户

```bash
GET /me

# 响应 (200 OK) - 如果已登录
{
  "user": {
    "username": "johndoe",
    "email": "john@example.com"
  }
}

# 响应 (401 Unauthorized) - 如果未登录
{
  "error": "Not logged in"
}
```

### OpenClaw 实例 API（需要登录）

所有以下 API 都需要先登录（会验证 session cookie）：

- `POST /provision` - 创建实例
- `GET /status/<user_id>` - 查看实例状态
- `DELETE /delete/<user_id>` - 删除实例

**示例**：

```bash
# 登录获取 session cookie
curl -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -c cookies.txt \
  -d '{"email":"john@example.com","password":"securepass123"}'

# 使用 cookie 创建实例
curl -X POST http://localhost:8080/provision \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{}'

# 查看状态
curl http://localhost:8080/status/7ec7606c -b cookies.txt
```

---

## 测试

### 本地测试

```bash
# 1. Port-forward
kubectl port-forward -n openclaw-provisioning svc/openclaw-provisioning 8080:80

# 2. 在浏览器中访问
open http://localhost:8080/login

# 3. 或使用 curl 测试
# 注册
curl -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","email":"test@example.com","password":"test1234"}'

# 登录
curl -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -c cookies.txt \
  -d '{"email":"test@example.com","password":"test1234"}'

# 创建实例
curl -X POST http://localhost:8080/provision \
  -H "Content-Type: application/json" \
  -b cookies.txt

# 查看状态（获取 user_id 从上一步响应中）
curl http://localhost:8080/status/7ec7606c -b cookies.txt

# 登出
curl -X POST http://localhost:8080/logout -b cookies.txt
```

### 集成测试

完整的端到端测试脚本：

```bash
#!/bin/bash
set -e

BASE_URL="http://localhost:8080"

echo "1. 注册用户..."
curl -s -X POST $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username":"e2e-test","email":"e2e@test.com","password":"test1234"}' \
  | jq .

echo "2. 登录..."
curl -s -X POST $BASE_URL/login \
  -H "Content-Type: application/json" \
  -c /tmp/cookies.txt \
  -d '{"email":"e2e@test.com","password":"test1234"}' \
  | jq .

echo "3. 获取当前用户..."
curl -s $BASE_URL/me -b /tmp/cookies.txt | jq .

echo "4. 创建实例..."
USER_ID=$(curl -s -X POST $BASE_URL/provision \
  -H "Content-Type: application/json" \
  -b /tmp/cookies.txt \
  | jq -r '.user_id')
echo "User ID: $USER_ID"

echo "5. 查看状态..."
curl -s $BASE_URL/status/$USER_ID -b /tmp/cookies.txt | jq .

echo "6. 删除实例..."
curl -s -X DELETE $BASE_URL/delete/$USER_ID -b /tmp/cookies.txt | jq .

echo "7. 登出..."
curl -s -X POST $BASE_URL/logout -b /tmp/cookies.txt | jq .

echo "✅ E2E 测试完成"
```

---

## 数据持久化

### SQLite 数据库

- **路径**：`/app/data/openclaw.db`
- **PVC**：`openclaw-provisioning-data` (5Gi, gp3, RWO)
- **表结构**：

```sql
CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_users_email ON users(email);
```

### Session 存储

- **路径**：`/app/flask_session/`
- **PVC**：`openclaw-provisioning-sessions` (1Gi, efs-sc, RWX)
- **格式**：文件系统（Flask-Session filesystem backend）
- **共享**：多 Pod 通过 EFS 共享 session

**为什么需要 EFS？**

因为 deployment 有 2 个副本（replicas: 2），用户的请求可能被负载均衡到不同的 Pod，所以 session 必须在 Pod 之间共享。EFS 支持 ReadWriteMany (RWX)，可以被多个 Pod 同时挂载。

---

## 安全性

### 已实现

✅ **密码加密**：bcrypt with salt
✅ **Session 安全**：
  - `SESSION_COOKIE_SECURE=True`（仅 HTTPS）
  - `SESSION_COOKIE_HTTPONLY=True`（防 XSS）
  - `SESSION_COOKIE_SAMESITE=Lax`（防 CSRF）
✅ **Session 过期**：7 天自动过期
✅ **用户隔离**：用户只能访问自己的资源（通过 user_id 校验）

### 生产环境建议

⚠️ **必须配置**：

1. **HTTPS 强制**：确保所有流量走 HTTPS（通过 ALB/CloudFront）
2. **强 SECRET_KEY**：
   ```bash
   # 生成强随机密钥
   openssl rand -base64 32

   # 存储到 Kubernetes Secret
   kubectl create secret generic openclaw-provisioning-secret \
     --from-literal=secret-key="<生成的密钥>" \
     -n openclaw-provisioning
   ```
3. **速率限制**：防止暴力破解
4. **审计日志**：记录所有认证事件
5. **定期备份**：备份 SQLite 数据库

---

## 故障排查

### 问题 1：Pod 无法启动

**症状**：
```
CrashLoopBackOff or Error
```

**检查**：
```bash
# 查看日志
kubectl logs -n openclaw-provisioning -l app=openclaw-provisioning --tail=50

# 查看 Pod 事件
kubectl describe pod -n openclaw-provisioning -l app=openclaw-provisioning
```

**常见原因**：
- Volume 挂载失败（PVC 未 Bound）
- 权限问题（fsGroup 配置错误）
- 数据库初始化失败

### 问题 2：Session 不同步（多 Pod 场景）

**症状**：
- 登录后立即 401 Unauthorized
- 不同请求之间 session 丢失

**原因**：Session PVC 使用了 ReadWriteOnce（只能单 Pod 挂载）

**解决**：
```bash
# 检查 PVC 是否使用 EFS
kubectl get pvc openclaw-provisioning-sessions -n openclaw-provisioning -o yaml | grep storageClassName

# 应该显示: storageClassName: efs-sc

# 如果不是，删除并重新创建
kubectl delete pvc openclaw-provisioning-sessions -n openclaw-provisioning
kubectl apply -f kubernetes/pvc.yaml
```

### 问题 3：登录失败（Invalid email or password）

**检查**：
```bash
# 1. 确认用户是否存在
kubectl exec -n openclaw-provisioning deployment/openclaw-provisioning -- \
  sqlite3 /app/data/openclaw.db "SELECT email FROM users;"

# 2. 查看数据库文件权限
kubectl exec -n openclaw-provisioning deployment/openclaw-provisioning -- \
  ls -la /app/data/

# 3. 查看应用日志
kubectl logs -n openclaw-provisioning -l app=openclaw-provisioning --tail=100 | grep -i login
```

### 问题 4：PVC 无法 Bound

**症状**：
```
PersistentVolumeClaim is not bound
```

**检查**：
```bash
# 查看 PVC 状态
kubectl get pvc -n openclaw-provisioning
kubectl describe pvc openclaw-provisioning-data -n openclaw-provisioning

# 检查 StorageClass 是否存在
kubectl get storageclass gp3
kubectl get storageclass efs-sc
```

**解决**：
- 确保 EFS CSI driver 已安装（用于 efs-sc）
- 确保 EBS CSI driver 已安装（用于 gp3）

---

## 维护

### 备份数据库

```bash
# 导出数据库
kubectl exec -n openclaw-provisioning deployment/openclaw-provisioning -- \
  sqlite3 /app/data/openclaw.db ".backup /tmp/backup.db"

# 复制到本地
kubectl cp openclaw-provisioning/<pod-name>:/tmp/backup.db ./openclaw-backup-$(date +%Y%m%d).db
```

### 清理用户数据

```bash
# 删除特定用户
kubectl exec -n openclaw-provisioning deployment/openclaw-provisioning -- \
  sqlite3 /app/data/openclaw.db "DELETE FROM users WHERE email='user@example.com';"

# 查看所有用户
kubectl exec -n openclaw-provisioning deployment/openclaw-provisioning -- \
  sqlite3 /app/data/openclaw.db "SELECT id, username, email, created_at FROM users;"
```

### 重置数据库

```bash
# 停止应用
kubectl scale deployment openclaw-provisioning --replicas=0 -n openclaw-provisioning

# 删除 PVC（会删除所有数据）
kubectl delete pvc openclaw-provisioning-data -n openclaw-provisioning

# 重新创建
kubectl apply -f kubernetes/pvc.yaml

# 重启应用
kubectl scale deployment openclaw-provisioning --replicas=2 -n openclaw-provisioning
```

---

## 文件结构

```
eks-pod-service/
├── app/
│   ├── main.py                      # 应用入口（已移除 JWT verifier）
│   ├── config.py                    # 配置（已移除 Cognito 配置）
│   ├── database.py                  # 新增：数据库模块
│   ├── api/
│   │   ├── register.py              # 新增：注册 API
│   │   ├── login.py                 # 新增：登录/登出 API
│   │   ├── provision.py             # 已修改：使用 session 认证
│   │   ├── status.py                # 已修改：使用 session 认证
│   │   └── delete.py                # 已修改：使用 session 认证
│   ├── utils/
│   │   ├── session_auth.py          # 新增：Session 认证模块
│   │   └── jwt_auth.py              # 已弃用（保留以防回滚）
│   └── templates/
│       └── login-simple.html        # 新增：登录/注册页面
├── kubernetes/
│   ├── pvc.yaml                     # 新增：PVC 配置
│   ├── deployment-with-volumes.yaml # 新增：带 Volume 的 Deployment
│   └── deployment.yaml              # 原始文件（未修改，作为参考）
├── requirements.txt                 # 已更新：添加 bcrypt, flask-session
├── deploy-local-auth.sh             # 新增：一键部署脚本
├── MIGRATION-TO-LOCAL-AUTH.md       # 新增：迁移文档
└── README-LOCAL-AUTH.md             # 本文件
```

---

## 相关文档

- [迁移指南](./MIGRATION-TO-LOCAL-AUTH.md) - 详细的迁移步骤
- [Deployment README](../README.md) - 整体项目文档
- [OpenClaw Operator](../../openclaw-operator/README.md) - Operator 文档

---

## 常见问题

**Q: 为什么使用 SQLite 而不是 PostgreSQL？**

A: SQLite 足够简单且无需额外的数据库服务，适合中小规模部署。如果需要高可用和更强的并发性能，可以迁移到 PostgreSQL。

**Q: 多副本（replicas > 1）会导致数据不一致吗？**

A: 不会。数据库使用 ReadWriteOnce PVC，只有一个 Pod 可以写入。Session 使用 ReadWriteMany EFS，多 Pod 共享。

**Q: 如何迁移现有 Cognito 用户？**

A: 无法直接迁移密码（Cognito 不提供明文密码）。选项：
1. 要求用户重新注册
2. 使用邮箱匹配，发送重置密码链接
3. 保留 Cognito 作为 fallback（实现双认证系统）

**Q: 如何添加管理员功能？**

A: 在 `users` 表中添加 `role` 字段，然后在 API 中检查 `session.get('role')` 是否为 `admin`。

---

**最后更新**: 2026-03-14
**维护者**: Claude Code
