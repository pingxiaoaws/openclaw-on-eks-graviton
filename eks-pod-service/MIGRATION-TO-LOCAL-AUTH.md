# Migration from Cognito to Local Authentication

## 概述

本文档描述如何将 OpenClaw 从 AWS Cognito 认证迁移到本地用户名/密码认证系统。

## 改造内容

### 1. 新增功能
- ✅ 用户注册功能（用户名 + 邮箱 + 密码）
- ✅ 本地登录验证（SQLite 数据库）
- ✅ Session-based 认证（替代 JWT）
- ✅ 密码安全加密（bcrypt）
- ✅ 登录/登出 API

### 2. 移除内容
- ❌ AWS Cognito 集成
- ❌ JWT token 验证
- ❌ Cognito User Pool 配置
- ❌ `python-jose` 依赖

### 3. 架构变更

**之前（Cognito）：**
```
Frontend → Cognito SDK → JWT token → Backend verifies with Cognito JWKS
```

**现在（Local Auth）：**
```
Frontend → 注册/登录 API → SQLite → Session cookie → Backend validates session
```

## 部署步骤

### Step 1: 更新依赖

已更新 `requirements.txt`：
```txt
flask==3.0.0
flask-session==0.5.0  # 新增：Session 管理
kubernetes==28.1.0
gunicorn==21.2.0
boto3==1.34.34
requests==2.31.0
python-json-logger==2.0.7
bcrypt==4.1.2  # 新增：密码加密
# 移除：python-jose[cryptography]==3.3.0
```

### Step 2: 创建 PersistentVolumeClaim（用于数据持久化）

创建 `kubernetes/pvc.yaml`：

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openclaw-provisioning-data
  namespace: openclaw-provisioning
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp3  # 或使用 EFS 的 efs-sc（支持 RWX）
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openclaw-provisioning-sessions
  namespace: openclaw-provisioning
spec:
  accessModes:
    - ReadWriteMany  # Session 需要多个 Pod 共享
  storageClassName: efs-sc  # 必须使用 EFS 支持 RWX
  resources:
    requests:
      storage: 1Gi
```

**应用：**
```bash
kubectl apply -f kubernetes/pvc.yaml
```

### Step 3: 更新 Deployment（添加 Volume）

在 `kubernetes/deployment.yaml` 的 `spec.template.spec` 中添加：

```yaml
spec:
  template:
    spec:
      # ... 现有配置 ...

      # 添加 volumes
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: openclaw-provisioning-data
        - name: sessions
          persistentVolumeClaim:
            claimName: openclaw-provisioning-sessions

      containers:
      - name: provisioning
        # ... 现有配置 ...

        # 添加 volumeMounts
        volumeMounts:
          - name: data
            mountPath: /app/data  # SQLite 数据库存储路径
          - name: sessions
            mountPath: /app/flask_session  # Session 文件存储路径

        # 添加环境变量
        env:
          - name: DATABASE_PATH
            value: "/app/data/openclaw.db"
          - name: SESSION_FILE_DIR
            value: "/app/flask_session"
```

**完整示例（片段）：**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openclaw-provisioning
  namespace: openclaw-provisioning
spec:
  replicas: 2
  template:
    spec:
      serviceAccountName: openclaw-provisioner
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        runAsNonRoot: true

      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: openclaw-provisioning-data
        - name: sessions
          persistentVolumeClaim:
            claimName: openclaw-provisioning-sessions

      containers:
      - name: provisioning
        image: ${ECR_REGISTRY}/openclaw-provisioning:latest
        imagePullPolicy: Always

        volumeMounts:
          - name: data
            mountPath: /app/data
          - name: sessions
            mountPath: /app/flask_session

        env:
          - name: DATABASE_PATH
            value: "/app/data/openclaw.db"
          - name: SESSION_FILE_DIR
            value: "/app/flask_session"
          - name: SECRET_KEY
            valueFrom:
              secretKeyRef:
                name: openclaw-provisioning-secret
                key: secret-key

        # ... 其他配置保持不变 ...
```

### Step 4: 移除 Cognito 配置

从 `kubernetes/configmap.yaml` 中移除以下配置：

```yaml
# 移除这些
COGNITO_REGION: "us-west-2"
COGNITO_USER_POOL_ID: ""
COGNITO_CLIENT_ID: ""
COGNITO_USER_POOL_DOMAIN: ""
```

### Step 5: 重新构建和部署

```bash
cd eks-pod-service

# 1. 登录 ECR
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin \
  111122223333.dkr.ecr.us-west-2.amazonaws.com

# 2. 构建新镜像
docker build -t 111122223333.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest .

# 3. 推送镜像
docker push 111122223333.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest

# 4. 应用 PVC
kubectl apply -f kubernetes/pvc.yaml

# 5. 更新 Deployment
kubectl apply -f kubernetes/deployment.yaml

# 6. 等待 rollout 完成
kubectl rollout status deployment openclaw-provisioning -n openclaw-provisioning

# 7. 验证
kubectl get pods -n openclaw-provisioning
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning
```

### Step 6: 验证部署

```bash
# 1. 检查 PVC 状态
kubectl get pvc -n openclaw-provisioning
# 应该显示两个 PVC 都是 Bound 状态

# 2. 检查 Pod 状态
kubectl get pods -n openclaw-provisioning

# 3. 查看日志（应该看到数据库和 session 初始化成功）
kubectl logs -n openclaw-provisioning -l app=openclaw-provisioning --tail=50

# 预期日志输出：
# ✅ Database initialized at /app/data/openclaw.db
# ✅ Session management initialized
# ✅ Kubernetes in-cluster config loaded
# 🚀 OpenClaw Provisioning Service initialized
```

### Step 7: 测试新认证系统

#### 7.1 访问登录页面

```bash
# Port-forward 到本地
kubectl port-forward -n openclaw-provisioning svc/openclaw-provisioning 8080:80

# 浏览器访问
open http://localhost:8080/login
```

#### 7.2 测试注册

```bash
curl -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{
    "username": "testuser",
    "email": "test@example.com",
    "password": "test1234"
  }'

# 预期响应（201 Created）：
# {
#   "status": "success",
#   "message": "User registered successfully",
#   "username": "testuser",
#   "email": "test@example.com"
# }
```

#### 7.3 测试登录

```bash
curl -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -c cookies.txt \
  -d '{
    "email": "test@example.com",
    "password": "test1234"
  }'

# 预期响应（200 OK）：
# {
#   "status": "success",
#   "message": "Login successful",
#   "user": {
#     "username": "testuser",
#     "email": "test@example.com"
#   }
# }
```

#### 7.4 测试带认证的 API（Provision）

```bash
# 使用 cookies.txt 中的 session
curl -X POST http://localhost:8080/provision \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{}'

# 预期响应（201 Created）：
# {
#   "status": "created",
#   "user_id": "7ec7606c",
#   "namespace": "openclaw-7ec7606c",
#   ...
# }
```

#### 7.5 测试登出

```bash
curl -X POST http://localhost:8080/logout \
  -b cookies.txt

# 预期响应（200 OK）：
# {
#   "status": "success",
#   "message": "Logout successful"
# }
```

#### 7.6 验证未登录时访问受保护资源

```bash
# 不带 cookie 访问 provision
curl -X POST http://localhost:8080/provision \
  -H "Content-Type: application/json"

# 预期响应（401 Unauthorized）：
# {
#   "error": "Unauthorized",
#   "message": "Please login to access this resource"
# }
```

## API 变更汇总

### 新增 API

| 端点 | 方法 | 认证 | 描述 |
|------|------|------|------|
| `/register` | POST | 否 | 注册新用户 |
| `/login` | POST | 否 | 用户登录（创建 session） |
| `/logout` | POST | 否 | 用户登出（清除 session） |
| `/me` | GET | 否 | 获取当前登录用户信息 |

### 修改 API

| 端点 | 之前 | 现在 |
|------|------|------|
| `/provision` | JWT token 认证 | Session 认证 |
| `/status/<user_id>` | JWT token 认证 | Session 认证 |
| `/delete/<user_id>` | JWT token 认证 | Session 认证 |

### 前端变更

- **登录页面**：`/login` 现在显示 `login-simple.html`（支持注册和登录）
- **认证方式**：使用 session cookie，不再需要手动传递 JWT token
- **移除依赖**：不再加载 `amazon-cognito-identity-js` SDK

## 数据存储

### SQLite 数据库

- **路径**：`/app/data/openclaw.db`
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
  ```

### Session 存储

- **路径**：`/app/flask_session/`
- **格式**：文件系统（Flask-Session filesystem backend）
- **共享**：通过 EFS PVC 实现多 Pod 共享

## 安全考虑

### ✅ 已实现

1. **密码加密**：使用 bcrypt（带 salt）
2. **Session 安全**：
   - `SESSION_COOKIE_SECURE=True`（仅 HTTPS）
   - `SESSION_COOKIE_HTTPONLY=True`（防 XSS）
   - `SESSION_COOKIE_SAMESITE=Lax`（防 CSRF）
3. **Session 过期**：7 天自动过期
4. **用户隔离**：用户只能访问自己的资源（user_id 验证）

### ⚠️ 生产环境建议

1. **HTTPS 必须**：确保所有流量走 HTTPS（通过 ALB/CloudFront）
2. **SECRET_KEY**：使用强随机密钥（通过 Kubernetes Secret）
   ```bash
   kubectl create secret generic openclaw-provisioning-secret \
     --from-literal=secret-key=$(openssl rand -base64 32) \
     -n openclaw-provisioning
   ```
3. **速率限制**：添加登录失败速率限制（防暴力破解）
4. **审计日志**：记录所有认证事件
5. **备份**：定期备份 SQLite 数据库

## 回滚计划

如果需要回滚到 Cognito：

1. 恢复旧的镜像 tag：
   ```bash
   kubectl set image deployment/openclaw-provisioning \
     provisioning=111122223333.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:cognito-backup \
     -n openclaw-provisioning
   ```

2. 恢复 Cognito ConfigMap
3. 删除 PVC（可选，如果不再需要本地用户数据）

## 故障排查

### 问题：Pod 无法启动，显示 "no space left on device"

**原因**：PVC 空间不足

**解决**：
```bash
# 扩容 PVC（如果 StorageClass 支持）
kubectl edit pvc openclaw-provisioning-data -n openclaw-provisioning
# 修改 spec.resources.requests.storage 为更大的值
```

### 问题：多个 Pod 之间 Session 不同步

**原因**：Session PVC 使用了 ReadWriteOnce（只能单 Pod 挂载）

**解决**：确保使用 EFS (`efs-sc`) StorageClass，支持 ReadWriteMany

### 问题：登录后立即显示 401 Unauthorized

**原因**：Session cookie 未正确设置或传递

**检查**：
```bash
# 查看 cookie 是否设置
curl -v http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"test1234"}' \
  2>&1 | grep Set-Cookie
```

### 问题：数据库初始化失败

**原因**：Volume 挂载路径权限问题

**检查**：
```bash
kubectl exec -n openclaw-provisioning deployment/openclaw-provisioning -- \
  ls -la /app/data

# 确保 uid=1000 可写
```

**修复**：确保 Deployment 中 `securityContext.fsGroup=1000`

## 总结

✅ **已完成**：
- 移除 Cognito 依赖
- 实现本地用户注册/登录
- Session-based 认证
- 更新所有 API endpoints
- 新的前端登录页面

📝 **待部署**：
- 创建 PVC（数据和 session）
- 更新 Deployment 配置
- 重新构建和部署镜像
- 测试完整流程

🎯 **生产环境额外配置**：
- 强 SECRET_KEY
- HTTPS 强制
- 速率限制
- 数据库备份策略
