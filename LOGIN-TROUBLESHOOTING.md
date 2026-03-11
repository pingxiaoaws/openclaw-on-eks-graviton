# OpenClaw 登录问题排查指南

## ✅ 后端测试结果

所有后端组件工作正常：
- ✅ Cognito 用户认证成功
- ✅ API Gateway 健康检查通过
- ✅ 前端配置文件正确

## 🔐 新用户登录信息

**用户名**: `testuser3@openclaw.rocks`
**密码**: `OpenClawTest2026!`
**登录URL**: https://xxxxxxxxxx.execute-api.us-west-2.amazonaws.com/prod/

## 🛠️ 浏览器端排查步骤

### 步骤 1: 清除浏览器缓存

**Chrome/Edge**:
1. 按 `Cmd+Shift+Delete` (Mac) 或 `Ctrl+Shift+Delete` (Windows)
2. 选择 "Cached images and files"
3. 选择 "Cookies and other site data"
4. 点击 "Clear data"

**Safari**:
1. Safari 菜单 → Preferences → Privacy
2. 点击 "Manage Website Data"
3. 搜索 `amazonaws.com`
4. 点击 "Remove All"

**或者直接使用无痕模式**:
- Chrome: `Cmd+Shift+N` (Mac) 或 `Ctrl+Shift+N` (Windows)
- Safari: `Cmd+Shift+N`
- Firefox: `Cmd+Shift+P`

### 步骤 2: 检查浏览器控制台错误

1. 打开登录页面: https://xxxxxxxxxx.execute-api.us-west-2.amazonaws.com/prod/
2. 按 `F12` 或 `Cmd+Option+I` 打开开发者工具
3. 切换到 **Console** 标签
4. 尝试登录
5. 查看是否有红色错误信息

**常见错误及解决方案**:

| 错误信息 | 原因 | 解决方案 |
|---------|------|---------|
| `Incorrect username or password` | 密码输入错误 | 确认密码: `OpenClawTest2026!` (注意大小写) |
| `User does not exist` | 用户名输入错误 | 确认邮箱: `testuser3@openclaw.rocks` |
| `Failed to fetch` | 网络问题 | 检查网络连接，或使用 VPN |
| `CORS error` | 跨域问题 | 后端配置问题，联系管理员 |
| `UserPool appClientId is required` | 配置未加载 | 刷新页面，清除缓存 |

### 步骤 3: 手动测试 Cognito SDK

在浏览器控制台运行以下代码（在登录页面的 Console 中）:

```javascript
// 测试 1: 检查配置
console.log('CONFIG:', CONFIG);

// 测试 2: 尝试登录
Auth.signIn('testuser3@openclaw.rocks', 'OpenClawTest2026!')
  .then(session => {
    console.log('✅ Login successful!', session);
    alert('Login successful! Token: ' + session.idToken.substring(0, 50) + '...');
  })
  .catch(err => {
    console.error('❌ Login failed:', err);
    alert('Login failed: ' + err.message);
  });
```

### 步骤 4: 使用独立测试页面

我已经创建了一个测试页面，直接在浏览器中打开：

```bash
open /tmp/test-cognito-login.html
```

这个页面会直接测试 Cognito 登录，不依赖任何后端服务。

### 步骤 5: 检查 localStorage

在浏览器控制台运行：

```javascript
// 清除旧的 session
localStorage.removeItem('openclaw_session');

// 查看当前 localStorage
console.log('localStorage:', localStorage);
```

## 🐛 具体错误场景

### 场景 1: "Incorrect username or password"

**可能原因**:
1. 密码输入错误（最常见）
2. 大小写错误
3. 复制粘贴时带了额外空格

**解决方案**:
```bash
# 重置密码（如果需要）
aws cognito-idp admin-set-user-password \
  --user-pool-id us-west-2_ExAmPlE \
  --username testuser3@openclaw.rocks \
  --password 'NewPassword123!' \
  --permanent \
  --region us-west-2
```

### 场景 2: 页面加载但登录按钮无响应

**可能原因**:
1. JavaScript 未加载
2. Cognito SDK 加载失败

**解决方案**:
在控制台检查：
```javascript
console.log('AmazonCognitoIdentity:', typeof AmazonCognitoIdentity);
console.log('Auth:', typeof Auth);
```

如果显示 `undefined`，说明 SDK 未加载。

### 场景 3: 登录后立即退出

**可能原因**:
Token 验证失败

**解决方案**:
检查后端日志：
```bash
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=50 | grep -i "jwt\|token\|auth"
```

## 🧪 命令行测试

如果浏览器登录仍然失败，使用命令行直接测试完整流程：

```bash
# 1. 获取 JWT Token
TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id xxxxxxxxxxxxxxxxxxxxxxxxxx \
  --region us-west-2 \
  --auth-parameters USERNAME=testuser3@openclaw.rocks,PASSWORD='OpenClawTest2026!' \
  --query 'AuthenticationResult.IdToken' \
  --output text)

echo "Token (前50字符): ${TOKEN:0:50}..."

# 2. 测试 API 调用
curl -X POST https://xxxxxxxxxx.execute-api.us-west-2.amazonaws.com/prod/provision \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}' | jq .

# 3. 查看状态
USER_ID=$(echo -n "testuser3@openclaw.rocks" | shasum -a 256 | cut -c1-12)
curl -X GET https://xxxxxxxxxx.execute-api.us-west-2.amazonaws.com/prod/status/$USER_ID \
  -H "Authorization: Bearer $TOKEN" | jq .
```

## 📞 需要帮助？

如果以上步骤都无法解决问题，请提供以下信息：

1. **浏览器和版本**: (例如 Chrome 131.0.6778.140)
2. **操作系统**: (例如 macOS 15.2)
3. **控制台错误截图**: (F12 → Console)
4. **Network 标签截图**: (F12 → Network，显示失败的请求)

## 🎯 快速验证清单

- [ ] 在无痕模式下尝试登录
- [ ] 确认密码输入正确（复制粘贴：`OpenClawTest2026!`）
- [ ] 检查浏览器控制台是否有错误
- [ ] 使用测试页面 `/tmp/test-cognito-login.html` 验证
- [ ] 命令行测试成功

---

**最后更新**: 2026-03-04
**用户**: testuser3@openclaw.rocks
**登录URL**: https://xxxxxxxxxx.execute-api.us-west-2.amazonaws.com/prod/
