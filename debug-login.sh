#!/bin/bash
# 登录问题调试脚本

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}OpenClaw 登录问题诊断${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 1. 测试用户凭据
echo -e "${YELLOW}[1/5]${NC} 测试 Cognito 用户凭据..."
echo "用户: testuser3@openclaw.rocks"
echo "密码: OpenClawTest2026!"
echo ""

TOKEN_RESPONSE=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id 7hu644gbgodv2bap8cq6eb02n7 \
  --region us-west-2 \
  --auth-parameters USERNAME=testuser3@openclaw.rocks,PASSWORD='OpenClawTest2026!' 2>&1)

if echo "$TOKEN_RESPONSE" | grep -q "IdToken"; then
    echo -e "${GREEN}✅ 凭据正确，可以成功登录${NC}"
    ID_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.AuthenticationResult.IdToken')
    echo "ID Token (前50字符): ${ID_TOKEN:0:50}..."
else
    echo -e "${RED}❌ 凭据验证失败${NC}"
    echo "$TOKEN_RESPONSE"
    exit 1
fi
echo ""

# 2. 检查 API Gateway
echo -e "${YELLOW}[2/5]${NC} 检查 API Gateway..."
API_ENDPOINT="https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod"
echo "Endpoint: $API_ENDPOINT"

HEALTH_CHECK=$(curl -s -o /dev/null -w "%{http_code}" "$API_ENDPOINT/health")
if [ "$HEALTH_CHECK" == "200" ]; then
    echo -e "${GREEN}✅ API Gateway 可访问${NC}"
else
    echo -e "${RED}❌ API Gateway 健康检查失败 (HTTP $HEALTH_CHECK)${NC}"
fi
echo ""

# 3. 检查登录页面
echo -e "${YELLOW}[3/5]${NC} 检查登录页面..."
LOGIN_PAGE=$(curl -s -o /dev/null -w "%{http_code}" "$API_ENDPOINT/")
if [ "$LOGIN_PAGE" == "200" ]; then
    echo -e "${GREEN}✅ 登录页面可访问${NC}"
else
    echo -e "${RED}❌ 登录页面不可访问 (HTTP $LOGIN_PAGE)${NC}"
fi
echo ""

# 4. 检查前端配置
echo -e "${YELLOW}[4/5]${NC} 检查前端 Cognito 配置..."
echo "获取前端 config.js..."
CONFIG_JS=$(curl -s "$API_ENDPOINT/static/js/config.js")

if echo "$CONFIG_JS" | grep -q "7hu644gbgodv2bap8cq6eb02n7"; then
    echo -e "${GREEN}✅ 前端配置正确 (Client ID 匹配)${NC}"
else
    echo -e "${RED}❌ 前端配置不正确或无法访问${NC}"
    echo "配置内容:"
    echo "$CONFIG_JS" | head -20
fi
echo ""

# 5. 测试完整登录流程
echo -e "${YELLOW}[5/5]${NC} 测试通过 API 创建实例..."
PROVISION_RESPONSE=$(curl -s -X POST "$API_ENDPOINT/provision" \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}')

if echo "$PROVISION_RESPONSE" | grep -q "namespace\|message"; then
    echo -e "${GREEN}✅ API 认证成功${NC}"
    echo "响应: $(echo $PROVISION_RESPONSE | jq -c .)"
else
    echo -e "${RED}❌ API 认证失败${NC}"
    echo "响应: $PROVISION_RESPONSE"
fi
echo ""

# 总结
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}诊断完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "登录信息:"
echo "  用户: testuser3@openclaw.rocks"
echo "  密码: OpenClawTest2026!"
echo "  登录URL: $API_ENDPOINT/"
echo ""
echo "如果浏览器登录失败，请尝试:"
echo "  1. 清除浏览器缓存和 localStorage"
echo "  2. 使用无痕模式/隐私窗口"
echo "  3. 检查浏览器控制台的错误信息 (F12 -> Console)"
echo "  4. 确认密码输入正确（注意大小写和特殊字符）"
echo ""
echo "调试工具："
echo "  - 打开浏览器: open $API_ENDPOINT/"
echo "  - 查看测试页面: open file:///tmp/test-cognito-login.html"
echo ""
