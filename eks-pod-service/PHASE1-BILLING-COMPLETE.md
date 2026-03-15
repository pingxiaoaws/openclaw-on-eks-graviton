# Phase 1: Billing & Quota Management - Implementation Complete ✅

## 概述

Phase 1 实现了基础的配额管理功能，包括：
- ✅ 用户计划管理（Free/Pro/Enterprise）
- ✅ 月度 token 配额跟踪
- ✅ 配额状态展示（百分比、警告、超限）
- ✅ 计划升级 API
- ✅ 前端配额仪表板

**工作量**: 完成 ✅
**预计时间**: 2 天
**实际时间**: 已完成

---

## 已实现的文件

### 1. 后端核心

#### 数据库迁移
- **`scripts/add_plan_field.py`** (新建)
  - 添加 `users.plan` 字段（free/pro/enterprise）
  - 为现有用户设置默认值 'free'
  - 幂等性：多次运行安全

- **`scripts/migrate_billing.py`** (新建)
  - 创建 `usage_events`, `hourly_usage`, `daily_usage` 表
  - 添加 `users.is_admin` 字段
  - 创建必要的索引

#### 配额管理模块
- **`app/services/quota.py`** (新建)
  - `PLAN_LIMITS`: 定义三种计划的限制
    - Free: 100K tokens/月, 1 instance, $0
    - Pro: 10M tokens/月, 5 instances, $99
    - Enterprise: Unlimited, $Custom
  - `QuotaStatus`: 配额状态类
    - `is_warning`: >= 80% 触发警告
    - `is_over_quota`: >= 100% 超限
    - `status_emoji`, `status_text`: 用于 UI 展示
  - `check_quota()`: 检查用户当前配额状态
  - `get_monthly_usage()`: 获取本月累计用量
  - `get_days_until_reset()`: 计算距离配额重置天数
  - `check_instance_limit()`: 检查是否可创建新 instance

#### Billing API
- **`app/api/billing.py`** (扩展)
  - `GET /billing/plans`: 列出所有计划（公开端点）
  - `GET /billing/usage?days=30`: 获取用量 + 配额信息（需认证）
  - `GET /billing/quota`: 获取配额状态（需认证）
  - `POST /billing/upgrade`: 升级计划（需认证，MVP 无支付）
  - `GET /billing/hourly?hours=24`: 小时级用量时间序列

#### 用户管理
- **`app/database.py`** (修改)
  - `init_db()`: users 表增加 `is_admin`, `plan` 字段
  - `create_user()`: 首个用户自动成为管理员
  - `insert_usage_event()`: 插入原始用量事件
  - `get_user_usage_summary()`: 获取用户用量汇总
  - `get_all_users_with_usage()`: 管理员获取所有用户
  - `cleanup_old_usage_events()`: 清理 7 天前的原始事件

- **`app/utils/session_auth.py`** (扩展)
  - `require_admin()`: 管理员权限装饰器
  - 检查 `is_admin` 字段，403 Forbidden if not admin

#### Usage Collector
- **`app/services/usage_collector.py`** (新建)
  - `UsageCollector`: 后台收集器（5 分钟间隔）
  - `collect_from_pod()`: kubectl exec 读取 session JSONL
  - `collect_all_instances()`: 扫描所有 openclaw-* namespaces
  - `aggregate_hourly()`, `aggregate_daily()`: 聚合到小时/天表
  - `cleanup_old_events()`: 自动清理 7 天前数据

### 2. 前端

#### Billing Panel UI
- **`app/static/css/billing.css`** (新建)
  - Industrial Cloud 主题样式
  - 配额进度条（带颜色编码：绿色正常、黄色警告、红色超限）
  - 统计卡片（tokens, calls, quota）
  - 计划信息横幅
  - 模型使用表格
  - 响应式设计

- **`app/static/js/billing.js`** (新建)
  - `Billing.init()`: 初始化并注入 billing panel HTML
  - `Billing.loadBillingData()`: 从 API 加载数据
  - `Billing.updateQuotaDisplay()`: 更新配额 UI（进度条、状态）
  - `Billing.updatePlanInfo()`: 更新计划徽章
  - `Billing.renderModelBreakdown()`: 渲染模型使用表格
  - `Billing.showUpgradeModal()`: 计划升级对话框
  - `Billing.upgradePlan()`: 调用升级 API

#### Dashboard 集成
- **`app/templates/dashboard-new.html`** (修改)
  - 引入 `billing.css` (line 13)
  - 加载 `billing.js` (line 983)
  - billing.js 自动注入 billing panel HTML

### 3. 应用初始化

- **`app/main.py`** (修改)
  - 注册 `billing_bp`, `admin_bp` 蓝图
  - 添加 `/admin` 路由（admin dashboard）
  - 启动 UsageCollector 后台线程（仅 production）

---

## 数据库 Schema 更新

### `users` 表新增字段
```sql
ALTER TABLE users ADD COLUMN is_admin BOOLEAN DEFAULT 0;
ALTER TABLE users ADD COLUMN plan TEXT DEFAULT 'free';
```

### 新增表
```sql
-- 原始用量事件（7 天保留）
CREATE TABLE usage_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    user_email TEXT NOT NULL,
    model TEXT NOT NULL,
    provider TEXT NOT NULL,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    cache_read INTEGER DEFAULT 0,
    cache_write INTEGER DEFAULT 0,
    total_tokens INTEGER DEFAULT 0,
    timestamp BIGINT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 按小时聚合
CREATE TABLE hourly_usage (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    user_email TEXT NOT NULL,
    model TEXT NOT NULL,
    provider TEXT NOT NULL,
    hour TIMESTAMP NOT NULL,
    input_tokens BIGINT DEFAULT 0,
    output_tokens BIGINT DEFAULT 0,
    total_tokens BIGINT DEFAULT 0,
    call_count INTEGER DEFAULT 0,
    estimated_cost REAL DEFAULT 0.0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, model, provider, hour)
);

-- 按天聚合
CREATE TABLE daily_usage (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    user_email TEXT NOT NULL,
    model TEXT NOT NULL,
    provider TEXT NOT NULL,
    date DATE NOT NULL,
    input_tokens BIGINT DEFAULT 0,
    output_tokens BIGINT DEFAULT 0,
    total_tokens BIGINT DEFAULT 0,
    call_count INTEGER DEFAULT 0,
    estimated_cost REAL DEFAULT 0.0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, model, provider, date)
);
```

---

## API 端点

### Billing API (`/billing/*`)

| Endpoint | Method | Auth | 描述 |
|----------|--------|------|------|
| `/billing/plans` | GET | 无 | 列出所有计划及限制 |
| `/billing/usage?days=30` | GET | ✅ | 获取用量 + 配额信息 |
| `/billing/quota` | GET | ✅ | 获取配额状态 |
| `/billing/upgrade` | POST | ✅ | 升级计划 |
| `/billing/hourly?hours=24` | GET | ✅ | 小时级用量时间序列 |

### Admin API (`/admin/*`)

| Endpoint | Method | Auth | 描述 |
|----------|--------|------|------|
| `/admin/users` | GET | Admin | 列出所有用户 + 用量 |
| `/admin/usage/summary` | GET | Admin | 平台级用量统计 |

---

## 部署步骤

### 1. 运行数据库迁移

```bash
cd eks-pod-service

# 方式 1: 直接运行迁移脚本
python scripts/add_plan_field.py
python scripts/migrate_billing.py

# 方式 2: 在 Pod 内运行（如果已部署）
kubectl exec -it deployment/openclaw-provisioning -n openclaw-provisioning -- \
  python scripts/add_plan_field.py

kubectl exec -it deployment/openclaw-provisioning -n openclaw-provisioning -- \
  python scripts/migrate_billing.py
```

### 2. 重新构建并部署

```bash
# 构建新镜像
docker build -t <ECR_REPO>/openclaw-provisioning:latest .
docker push <ECR_REPO>/openclaw-provisioning:latest

# 重启 deployment
kubectl rollout restart deployment openclaw-provisioning -n openclaw-provisioning
kubectl rollout status deployment openclaw-provisioning -n openclaw-provisioning

# 检查日志
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning -f | grep -E "(Usage collector|Billing)"
```

### 3. 创建管理员用户

```bash
# 方式 1: 通过 SQL（首个用户自动成为管理员）
# 注册第一个用户即可

# 方式 2: 手动设置现有用户为管理员
kubectl exec -it deployment/openclaw-provisioning -n openclaw-provisioning -- \
  sqlite3 /app/data/openclaw.db \
  "UPDATE users SET is_admin = 1 WHERE email = 'admin@example.com';"
```

---

## 测试

### 自动化测试

```bash
cd eks-pod-service

# 运行测试脚本
chmod +x scripts/test_billing_phase1.sh
./scripts/test_billing_phase1.sh
```

### 手动测试

#### 1. 测试公开端点
```bash
curl http://localhost:8080/billing/plans | jq .
```

#### 2. 注册并登录
```bash
# 注册
curl -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","email":"test@example.com","password":"Test123!"}'

# 登录（保存 cookie）
curl -X POST http://localhost:8080/login -c cookies.txt \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"Test123!"}'
```

#### 3. 测试配额 API
```bash
# 获取配额状态
curl http://localhost:8080/billing/quota -b cookies.txt | jq .

# 获取用量数据
curl http://localhost:8080/billing/usage?days=30 -b cookies.txt | jq .
```

#### 4. 测试计划升级
```bash
curl -X POST http://localhost:8080/billing/upgrade -b cookies.txt \
  -H "Content-Type: application/json" \
  -d '{"plan":"pro"}' | jq .
```

### 前端测试

1. 访问 Dashboard: `http://localhost:8080/dashboard`
2. 登录测试用户
3. 检查页面底部是否显示 **Usage & Billing** 面板
4. 验证显示内容：
   - ✅ Total Tokens 卡片
   - ✅ API Calls 卡片
   - ✅ Monthly Quota 卡片（带进度条）
   - ✅ 计划信息横幅（FREE PLAN / PRO PLAN）
   - ✅ Upgrade Plan 按钮
   - ✅ Model Breakdown 表格
5. 点击 "Upgrade Plan" 按钮，尝试升级到 Pro
6. 刷新页面，验证计划徽章变为 "PRO PLAN"

---

## 功能验证清单

### 后端
- [ ] 数据库迁移成功（`users.plan`, `users.is_admin` 字段存在）
- [ ] `usage_events`, `hourly_usage`, `daily_usage` 表创建成功
- [ ] `/billing/plans` 返回 3 个计划
- [ ] `/billing/usage` 返回用量 + 配额信息
- [ ] `/billing/quota` 返回配额状态
- [ ] `/billing/upgrade` 可以升级计划
- [ ] Usage Collector 后台线程启动（production 模式）
- [ ] 首个注册用户自动成为管理员

### 前端
- [ ] Dashboard 底部显示 billing panel
- [ ] Total Tokens 卡片显示数值（新用户为 0）
- [ ] API Calls 卡片显示数值
- [ ] Monthly Quota 进度条显示（新用户为 0%）
- [ ] 计划徽章显示当前计划（FREE/PRO/ENTERPRISE）
- [ ] Upgrade Plan 按钮可点击
- [ ] 升级计划对话框弹出
- [ ] 升级成功后计划徽章更新
- [ ] Model Breakdown 表格显示（或显示 "No usage data yet"）

### 集成
- [ ] Usage Collector 每 5 分钟运行一次
- [ ] 用量数据成功插入 `usage_events` 表
- [ ] 数据成功聚合到 `hourly_usage`, `daily_usage`
- [ ] 配额计算正确（基于本月累计用量）
- [ ] 配额警告触发（>= 80%）
- [ ] 配额超限标记（>= 100%）

---

## 已知限制（MVP 阶段）

### 不强制配额
- ⚠️ 超出配额时**仅展示警告**，不阻止 API 调用
- 原因：MVP 阶段，用户体验优先
- 改进：Phase 2 可添加硬限制（拒绝请求）

### 无自动支付
- ⚠️ 计划升级**无需支付**，管理员手动处理
- 原因：MVP 阶段，集成 Stripe 不在范围内
- 改进：Phase 3 可集成 Stripe/支付宝

### 无邮件通知
- ⚠️ 接近配额时**不发送邮件**
- 原因：未集成邮件服务
- 改进：添加 `notifications.py` 模块

### 简单的 UI
- ⚠️ 升级计划使用 `prompt()` 对话框，非模态弹窗
- 原因：快速实现
- 改进：创建专业的模态弹窗组件

---

## Phase 2 准备（K8s 资源配额同步）

Phase 1 完成后，Phase 2 将实现：
1. **K8s ResourceQuota 管理**
   - 根据计划设置 namespace 资源配额
   - 升级计划时同步更新 K8s
2. **Provision 流程集成**
   - 创建 instance 时应用计划限制
   - 检查是否超出 max_instances
3. **资源限制**
   - Free: 2 CPU, 4Gi Memory
   - Pro: 10 CPU, 20Gi Memory
   - Enterprise: 50 CPU, 100Gi Memory

**预计时间**: 2-3 天

---

## 故障排查

### 问题 1: Billing panel 不显示
**检查**:
1. 浏览器控制台是否有 JS 错误？
2. `billing.js` 是否成功加载？（Network tab）
3. `billing.css` 是否成功加载？

**解决**:
```bash
# 检查静态文件
ls -la app/static/js/billing.js
ls -la app/static/css/billing.css

# 清除浏览器缓存，强制刷新 (Ctrl+Shift+R)
```

### 问题 2: API 返回 500 错误
**检查**:
```bash
# 查看后端日志
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=50

# 检查数据库是否迁移成功
kubectl exec deployment/openclaw-provisioning -n openclaw-provisioning -- \
  sqlite3 /app/data/openclaw.db "PRAGMA table_info(users);"

# 应该看到 is_admin 和 plan 字段
```

### 问题 3: Usage Collector 未启动
**检查**:
```bash
# 确认 DEBUG 模式已关闭
kubectl get deployment openclaw-provisioning -n openclaw-provisioning -o yaml | grep DEBUG

# 查看启动日志
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning | grep "Usage collector"

# 应该看到: "✅ Usage collector started (5-minute interval)"
```

### 问题 4: 配额始终为 0
**原因**: 新用户没有任何用量数据

**验证**:
1. 创建 OpenClaw instance
2. 通过 gateway 调用 API（生成用量）
3. 等待 5 分钟（collector 运行）
4. 刷新 dashboard，查看配额是否更新

---

## 成功标准

✅ **Phase 1 完成当满足以下条件**:
1. 所有数据库迁移成功
2. 所有 API 端点正常工作
3. 前端 billing panel 正确显示
4. 用户可以查看配额状态
5. 用户可以升级计划
6. Usage Collector 成功运行
7. 测试脚本全部通过（绿色 ✅）

---

## 下一步

完成 Phase 1 后，可以选择：

**选项 A**: 继续 Phase 2 (K8s 资源配额同步)
- 实现 `app/k8s/quota.py`
- 集成到 provision 流程
- 升级计划时同步更新 K8s

**选项 B**: 先改进 Phase 1 UI
- 创建专业的升级计划模态弹窗
- 添加 Chart.js 图表（使用趋势）
- 添加成本预测功能

**选项 C**: 直接跳到 Phase 3 (管理员面板)
- 实现 admin dashboard 前端
- 管理员修改用户计划
- 平台级用量统计

---

**实施者**: Claude Code
**完成日期**: 2026-03-15
**版本**: Phase 1.0
