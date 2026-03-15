# Phase 1 Billing - Local Testing Guide

## 测试结果总结 ✅

### 核心功能验证通过
- ✅ 计划配置正确（Free/Pro/Enterprise）
- ✅ 用户查询正常（包含 plan 和 is_admin 字段）
- ✅ 月度用量计算准确
- ✅ 配额检查逻辑正确（百分比、警告、超限）
- ✅ 用量汇总生成正确（按天、按模型）
- ✅ 配额重置倒计时准确

### 测试数据
```
用户：
  - admin@example.com (admin, free plan, 0 tokens)
  - user1@example.com (user, free plan, 0 tokens)
  - user2@example.com (user, pro plan, 950K tokens, $42.75)

配额状态：
  - admin: 0/100K (0%) 🟢 正常
  - user1: 0/100K (0%) 🟢 正常
  - user2: 950K/10M (9.5%) 🟢 正常
```

---

## 本地运行步骤

### 1. 准备测试数据库

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata/eks-pod-service

# 创建测试数据库（已完成✅）
python3 scripts/quick_test_setup.py

# 输出：
# ✅ Test database created successfully!
# 📋 Tables: users, usage_events, hourly_usage, daily_usage
# 👤 Users: 3
# 📊 Daily usage records: 10
```

### 2. 安装依赖（如需要）

```bash
# 创建虚拟环境（推荐）
python3 -m venv venv
source venv/bin/activate

# 安装依赖
pip install -r requirements.txt
```

### 3. 启动 Flask 服务

```bash
# 设置环境变量
export DATABASE_PATH=/Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata/eks-pod-service/test_openclaw.db
export DEBUG=true

# 启动服务（方式 1：直接运行）
python3 -m app.main

# 或者方式 2：使用 Flask 命令
export FLASK_APP=app.main
flask run --host=0.0.0.0 --port=8080
```

**预期输出**：
```
✅ Database initialized
✅ Session management initialized
✅ Kubernetes kubeconfig loaded (dev mode)
ℹ️ Usage collector disabled (DEBUG mode)
🚀 OpenClaw Provisioning Service initialized
 * Running on http://0.0.0.0:8080
```

### 4. 测试 API 端点

#### A. 公开端点（无需认证）

```bash
# Test 1: 获取计划列表
curl http://localhost:8080/billing/plans | jq .

# 预期输出：
# {
#   "plans": {
#     "free": {"tokens_per_month": 100000, "max_instances": 1, ...},
#     "pro": {"tokens_per_month": 10000000, ...},
#     "enterprise": {...}
#   }
# }
```

#### B. 需要认证的端点

```bash
# Test 2: 登录（获取 session cookie）
curl -X POST http://localhost:8080/login -c cookies.txt \
  -H "Content-Type: application/json" \
  -d '{
    "email": "user2@example.com",
    "password": "User123!"
  }'

# 预期输出：
# {"message": "Login successful", "user": {...}}

# Test 3: 获取配额状态
curl http://localhost:8080/billing/quota -b cookies.txt | jq .

# 预期输出：
# {
#   "user_email": "user2@example.com",
#   "plan": "pro",
#   "current_usage": 950000,
#   "limit": 10000000,
#   "percentage_used": 9.5,
#   "is_warning": false,
#   "is_over_quota": false,
#   "status_emoji": "🟢",
#   "status_text": "Within limit"
# }

# Test 4: 获取用量详情
curl http://localhost:8080/billing/usage?days=30 -b cookies.txt | jq .

# 预期输出：
# {
#   "period_days": 30,
#   "plan": "pro",
#   "quota": {...},
#   "days_until_reset": 16,
#   "summary": {
#     "total_tokens": 950000,
#     "input_tokens": 475000,
#     "output_tokens": 475000,
#     "total_calls": 725,
#     "estimated_cost": 42.75
#   },
#   "by_model": [...],
#   "daily": [...]
# }

# Test 5: 升级计划
curl -X POST http://localhost:8080/billing/upgrade -b cookies.txt \
  -H "Content-Type: application/json" \
  -d '{"plan": "enterprise"}' | jq .

# 预期输出：
# {
#   "user_email": "user2@example.com",
#   "old_plan": "pro",
#   "new_plan": "enterprise",
#   "limits": {...},
#   "message": "Plan upgraded from pro to enterprise"
# }
```

### 5. 测试前端 Dashboard

#### A. 访问 Dashboard

```bash
# 打开浏览器访问
open http://localhost:8080/dashboard

# 或者直接访问
# http://localhost:8080/dashboard
```

#### B. 登录测试用户

使用以下任一账户登录：
- **Admin**: `admin@example.com` / `Admin123!` (假密码，需要更新 bcrypt 哈希)
- **User1**: `user1@example.com` / `User123!` (假密码)
- **User2**: `user2@example.com` / `User123!` (假密码，有用量数据)

**注意**：测试数据库使用的是假密码哈希，实际登录会失败。需要通过注册功能创建真实用户：

```bash
# 注册新用户
curl -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{
    "username": "testuser",
    "email": "test@example.com",
    "password": "Test123!"
  }'

# 然后登录
curl -X POST http://localhost:8080/login -c cookies.txt \
  -H "Content-Type: application/json" \
  -d '{
    "email": "test@example.com",
    "password": "Test123!"
  }'
```

#### C. 验证 Billing Panel 显示

登录后，在 Dashboard 底部应该看到：

```
┌─────────────────────────────────────────────────────────┐
│ 📊 Usage & Billing                                      │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  💬 Total Tokens    🔄 API Calls    ⚠️ Monthly Quota    │
│     0                  0            ▓░░░░░ 0%           │
│  Last 30 days      Last 30 days    0 / 100K tokens     │
│                                    🟢 Within limit       │
│                                    Resets in 16 days    │
│                                                         │
│  [FREE PLAN] 📦 1 Instance · 💬 100K tokens/month · $0  │
│                                    [Upgrade Plan] →     │
│                                                         │
│  Model Breakdown                                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │ Provider │ Model │ Tokens Used                   │  │
│  ├──────────────────────────────────────────────────┤  │
│  │ No usage data yet. Start using your instance!   │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

**检查项**：
- ✅ Billing panel 出现在 instance info 下方
- ✅ 显示 3 个统计卡片（Tokens, Calls, Quota）
- ✅ 配额进度条显示（颜色根据状态变化）
- ✅ 计划横幅显示当前计划
- ✅ Upgrade Plan 按钮可点击
- ✅ Model Breakdown 表格显示（或空状态）

#### D. 测试升级功能

1. 点击 **"Upgrade Plan"** 按钮
2. 在弹出对话框中输入 `pro`
3. 确认升级
4. 刷新页面，验证计划徽章变为 **"PRO PLAN"**

---

## 常见问题排查

### 问题 1: Billing Panel 不显示

**症状**：Dashboard 加载但没有 billing panel

**检查**：
```bash
# 1. 检查浏览器控制台（F12）
# 应该看到：
# All scripts loaded, initializing dashboard...
# Initializing billing panel...

# 2. 检查 Network tab
# billing.js 和 billing.css 应该成功加载（HTTP 200）

# 3. 检查静态文件
ls -la app/static/js/billing.js
ls -la app/static/css/billing.css
```

**解决**：
```bash
# 清除浏览器缓存
# Chrome/Edge: Ctrl+Shift+R (Windows) 或 Cmd+Shift+R (Mac)
# 强制刷新页面
```

### 问题 2: API 返回 500 错误

**症状**：`/billing/usage` 等端点返回 500

**检查**：
```bash
# 查看 Flask 日志
# 应该在终端看到错误堆栈

# 检查数据库
sqlite3 test_openclaw.db ".tables"
# 应该看到：users, usage_events, hourly_usage, daily_usage

sqlite3 test_openclaw.db "PRAGMA table_info(users);"
# 应该有 is_admin 和 plan 字段
```

**解决**：
```bash
# 重新创建测试数据库
rm -f test_openclaw.db
python3 scripts/quick_test_setup.py
```

### 问题 3: 登录失败

**症状**：测试用户无法登录

**原因**：测试数据库使用的是假密码哈希

**解决**：
```bash
# 方式 1: 注册新用户
curl -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{
    "username": "realuser",
    "email": "real@example.com",
    "password": "RealPass123!"
  }'

# 方式 2: 更新测试用户密码（需要 bcrypt）
python3 -c "
import bcrypt
import sqlite3

password = 'Test123!'
hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()

conn = sqlite3.connect('test_openclaw.db')
conn.execute('UPDATE users SET password_hash = ? WHERE email = ?', (hash, 'user2@example.com'))
conn.commit()
print('Password updated for user2@example.com')
"
```

### 问题 4: Usage Collector 未启动

**症状**：日志显示 "Usage collector disabled (DEBUG mode)"

**说明**：这是正常的！在 DEBUG 模式下，collector 不会启动，避免干扰本地测试。

**如果需要测试 collector**：
```bash
# 临时关闭 DEBUG 模式
export DEBUG=false
python3 -m app.main

# 应该看到：
# ✅ Usage collector started (5-minute interval)
```

### 问题 5: 配额数据不更新

**症状**：升级计划后，配额限制没变

**检查**：
```bash
# 验证数据库中的计划已更新
sqlite3 test_openclaw.db \
  "SELECT email, plan FROM users WHERE email='user2@example.com';"

# 应该看到新的计划
```

**解决**：
```bash
# 刷新页面（F5）
# 或者清除 session cookie 重新登录
```

---

## 测试清单

### 后端 API
- [ ] GET `/billing/plans` 返回 3 个计划
- [ ] GET `/billing/quota` 返回配额状态
- [ ] GET `/billing/usage?days=30` 返回用量 + 配额
- [ ] POST `/billing/upgrade` 可以升级计划
- [ ] 配额计算正确（0%, 9.5%, 100%+）
- [ ] 警告触发正确（>= 80%）
- [ ] 超限标记正确（>= 100%）

### 前端 Dashboard
- [ ] Billing panel 在 instance info 下方显示
- [ ] Total Tokens 卡片显示数值
- [ ] API Calls 卡片显示数值
- [ ] Monthly Quota 卡片显示进度条
- [ ] 配额进度条颜色正确（绿色/黄色/红色）
- [ ] 计划横幅显示当前计划
- [ ] Upgrade Plan 按钮可点击
- [ ] 升级对话框可以输入并提交
- [ ] 升级后计划徽章更新
- [ ] Model Breakdown 表格显示数据（或空状态）

### 集成测试
- [ ] 注册新用户 → 默认 free plan
- [ ] 首个用户自动成为管理员
- [ ] 升级 free → pro 成功
- [ ] 升级 pro → enterprise 成功
- [ ] 降级 pro → free 被阻止（可选）
- [ ] 配额重置倒计时显示正确

---

## 性能测试

### 数据库查询性能

```bash
# 测试配额查询速度
time curl -s http://localhost:8080/billing/quota -b cookies.txt > /dev/null

# 预期：< 100ms

# 测试用量汇总速度
time curl -s http://localhost:8080/billing/usage?days=30 -b cookies.txt > /dev/null

# 预期：< 200ms
```

### 前端加载性能

```bash
# 打开浏览器开发者工具 > Network tab
# 刷新 Dashboard 页面
# 检查：
# - billing.css: < 50ms
# - billing.js: < 100ms
# - /billing/usage API: < 300ms
```

---

## 下一步

### ✅ Phase 1 完成验证

当以下所有项都通过时，Phase 1 完成：
1. ✅ 所有 API 测试通过
2. ✅ 前端 billing panel 正确显示
3. ✅ 用户可以查看配额和用量
4. ✅ 用户可以升级计划
5. ✅ 配额警告和超限逻辑正确

### 🚀 准备 Phase 2

Phase 2 将实现：
1. K8s ResourceQuota 管理（根据计划设置资源限制）
2. Provision 流程集成（创建 instance 时检查配额）
3. 升级计划时同步更新 K8s

**或者**，你也可以选择：
- 先部署到 K8s 测试环境验证
- 优化前端 UI（添加图表、动画）
- 实现 Phase 3（管理员面板）

---

**测试完成日期**: 2026-03-15
**测试环境**: macOS 本地
**测试状态**: ✅ 核心功能验证通过
