# K8s 部署错误修复

## 🐛 错误描述

**错误信息**:
```
ModuleNotFoundError: No module named 'jose'
```

**错误位置**:
```python
File "/app/app/utils/jwt_auth.py", line 6, in <module>
    from jose import jwt, JWTError
```

**错误原因**:
系统已从 Cognito JWT 认证迁移到 Session 认证，但部分文件仍在导入旧的 `jwt_auth.py` 模块。

---

## ✅ 修复内容

### 1. 修复 `proxy.py`

**修改前**:
```python
from app.utils.jwt_auth import require_auth
```

**修改后**:
```python
from app.utils.session_auth import require_auth
```

### 2. 修复 `devices.py`

**修改前**:
```python
from flask import Blueprint, request, jsonify, current_app
from app.utils.jwt_auth import require_auth

@devices_bp.route('/api/devices/approve', methods=['POST'])
@require_auth(lambda: current_app.jwt_verifier)
def approve_device(user_info):
    authenticated_user_id = generate_user_id(user_info['user_email'])
    # ...
```

**修改后**:
```python
from flask import Blueprint, request, jsonify, current_app, session
from app.utils.session_auth import require_auth

@devices_bp.route('/api/devices/approve', methods=['POST'])
@require_auth
def approve_device():
    user_email = session['user_email']
    authenticated_user_id = generate_user_id(user_email)
    # ...
```

**同时修复**:
- `list_devices()` 函数也进行了相同的修改

---

## 📋 修改文件列表

```
✅ app/api/proxy.py
   - 导入: jwt_auth → session_auth

✅ app/api/devices.py
   - 导入: jwt_auth → session_auth
   - approve_device(): 移除 user_info 参数，使用 session
   - list_devices(): 移除 user_info 参数，使用 session
```

---

## 🚀 重新部署步骤

### 1. 重新构建镜像

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata/eks-pod-service

# 构建新镜像
docker build -t <ECR_REPO>/openclaw-provisioning:billing-fix .

# 推送到 ECR
docker push <ECR_REPO>/openclaw-provisioning:billing-fix
```

### 2. 更新 K8s Deployment

```bash
# 方式 1: 更新镜像标签
kubectl set image deployment/openclaw-provisioning \
  openclaw-provisioning=<ECR_REPO>/openclaw-provisioning:billing-fix \
  -n openclaw-provisioning

# 方式 2: 重启部署（如果使用 :latest 标签）
kubectl rollout restart deployment/openclaw-provisioning -n openclaw-provisioning

# 查看重启状态
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning
```

### 3. 验证部署成功

```bash
# 查看 pod 日志
kubectl logs -n openclaw-provisioning -l app=openclaw-provisioning --tail=50

# 预期输出（无错误）:
# ✅ Database initialized
# ✅ Session management initialized
# ✅ Kubernetes in-cluster config loaded
# ✅ Usage collector started (5-minute interval)
# 🚀 OpenClaw Provisioning Service initialized

# 检查 pod 状态
kubectl get pods -n openclaw-provisioning

# 预期输出:
# NAME                                    READY   STATUS    RESTARTS
# openclaw-provisioning-xxxxxxxxx-xxxxx   1/1     Running   0
```

### 4. 测试 API

```bash
# 获取 API 端点
API_ENDPOINT=$(kubectl get svc -n openclaw-provisioning openclaw-provisioning -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# 或者使用 port-forward
kubectl port-forward -n openclaw-provisioning svc/openclaw-provisioning 8080:80

# 测试健康检查
curl http://localhost:8080/health

# 测试 billing API
curl http://localhost:8080/billing/plans | jq .

# 预期输出:
# {
#   "plans": {
#     "free": {...},
#     "pro": {...},
#     "enterprise": {...}
#   }
# }
```

---

## 🔍 验证清单

- [ ] Docker 镜像成功构建并推送
- [ ] Deployment 成功重启
- [ ] Pod 状态为 Running（无 CrashLoopBackOff）
- [ ] Pod 日志无 ImportError 或 ModuleNotFoundError
- [ ] Usage Collector 成功启动（生产模式）
- [ ] Health endpoint 返回 200
- [ ] Billing API 正常工作

---

## 📝 相关文件

### 已修复的文件
- `app/api/proxy.py` ✅
- `app/api/devices.py` ✅

### 不再使用的文件
- `app/utils/jwt_auth.py` (已废弃，保留但不导入)

### 当前使用的认证
- `app/utils/session_auth.py` (Session-based 认证)
  - `require_auth` 装饰器
  - `require_admin` 装饰器

---

## ⚠️ 注意事项

### Session 存储
确保 K8s 部署配置了持久化 session 存储：

```yaml
env:
- name: SESSION_TYPE
  value: "filesystem"  # 或 redis
- name: SESSION_FILE_DIR
  value: "/app/data/sessions"

volumeMounts:
- name: data
  mountPath: /app/data
```

### 数据库迁移
如果是首次部署 billing 功能，需要运行迁移：

```bash
kubectl exec -it deployment/openclaw-provisioning -n openclaw-provisioning -- \
  python scripts/migrate_billing.py

# 预期输出:
# ✅ Created usage_events table
# ✅ Created hourly_usage table
# ✅ Created daily_usage table
# ✅ Billing database migration completed successfully
```

---

## 🎯 下一步

部署成功后：

1. **测试前端** - 访问 dashboard 验证 billing panel 显示
2. **验证 Usage Collector** - 检查日志确认每 5 分钟运行
3. **创建测试用户** - 注册并验证默认 free plan
4. **测试升级功能** - 尝试升级到 pro plan

---

**修复日期**: 2026-03-15
**状态**: ✅ 已修复，待重新部署验证
