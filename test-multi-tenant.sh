#!/bin/bash
# OpenClaw Multi-Tenant API 测试脚本

set -e

CONFIG_FILE="multi-tenant-config.txt"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误: 找不到配置文件 $CONFIG_FILE"
    echo "请先运行 ./deploy-multi-tenant.sh"
    exit 1
fi

source $CONFIG_FILE

# 颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

function log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

function log_error() {
    echo -e "${RED}✗${NC} $1"
}

function log_info() {
    echo -e "${YELLOW}→${NC} $1"
}

echo "=========================================="
echo "OpenClaw Multi-Tenant API 测试"
echo "=========================================="
echo "API Endpoint: $API_ENDPOINT"
echo "Test User: $TEST_USER"
echo ""

# 1. 获取 JWT Token
log_info "测试 1: 用户登录 Cognito"
TOKEN_RESPONSE=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id $CLIENT_ID \
  --region $REGION \
  --auth-parameters USERNAME=$TEST_USER,PASSWORD=$TEST_PASSWORD \
  --query 'AuthenticationResult' \
  --output json)

ID_TOKEN=$(echo $TOKEN_RESPONSE | jq -r '.IdToken')

if [ -n "$ID_TOKEN" ] && [ "$ID_TOKEN" != "null" ]; then
    log_success "JWT Token 获取成功"
    echo "   Token (前50字符): ${ID_TOKEN:0:50}..."
else
    log_error "JWT Token 获取失败"
    exit 1
fi

echo ""

# 2. 测试健康检查 (无需认证)
log_info "测试 2: 健康检查 (GET /health, 无需认证)"
HEALTH_RESPONSE=$(curl -s -w "\n%{http_code}" "${API_ENDPOINT}/health")
HTTP_CODE=$(echo "$HEALTH_RESPONSE" | tail -n1)
BODY=$(echo "$HEALTH_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" == "200" ]; then
    log_success "健康检查通过"
    echo "   $BODY"
else
    log_error "健康检查失败 (HTTP $HTTP_CODE)"
    echo "   $BODY"
fi

echo ""

# 3. 测试未认证访问 (应该失败)
log_info "测试 3: 未认证访问 (POST /provision, 无 Token)"
UNAUTH_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_ENDPOINT}/provision" \
  -H "Content-Type: application/json" \
  -d '{}')
HTTP_CODE=$(echo "$UNAUTH_RESPONSE" | tail -n1)

if [ "$HTTP_CODE" == "401" ]; then
    log_success "未认证访问被正确拒绝 (HTTP 401)"
else
    log_error "未认证访问未被拒绝 (HTTP $HTTP_CODE)"
fi

echo ""

# 4. 测试创建实例 (需要认证)
log_info "测试 4: 创建 OpenClaw 实例 (POST /provision, 带 Token)"
PROVISION_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_ENDPOINT}/provision" \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}')
HTTP_CODE=$(echo "$PROVISION_RESPONSE" | tail -n1)
BODY=$(echo "$PROVISION_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" == "201" ] || [ "$HTTP_CODE" == "200" ]; then
    log_success "实例创建成功"
    echo "$BODY" | jq '.' 2>/dev/null || echo "   $BODY"

    # 提取 user_id
    USER_ID=$(echo "$BODY" | jq -r '.user_id' 2>/dev/null || echo "")
else
    log_error "实例创建失败 (HTTP $HTTP_CODE)"
    echo "   $BODY"
    exit 1
fi

echo ""

# 5. 查询实例状态
if [ -n "$USER_ID" ] && [ "$USER_ID" != "null" ]; then
    log_info "测试 5: 查询实例状态 (GET /status/$USER_ID)"
    sleep 5

    STATUS_RESPONSE=$(curl -s -w "\n%{http_code}" "${API_ENDPOINT}/status/$USER_ID" \
      -H "Authorization: Bearer $ID_TOKEN")
    HTTP_CODE=$(echo "$STATUS_RESPONSE" | tail -n1)
    BODY=$(echo "$STATUS_RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" == "200" ]; then
        log_success "状态查询成功"
        echo "$BODY" | jq '.' 2>/dev/null || echo "   $BODY"
    else
        log_error "状态查询失败 (HTTP $HTTP_CODE)"
        echo "   $BODY"
    fi
fi

echo ""

# 6. 幂等性测试
log_info "测试 6: 幂等性测试 (再次创建相同实例)"
IDEMPOTENT_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_ENDPOINT}/provision" \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}')
HTTP_CODE=$(echo "$IDEMPOTENT_RESPONSE" | tail -n1)
BODY=$(echo "$IDEMPOTENT_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" == "200" ]; then
    STATUS=$(echo "$BODY" | jq -r '.status' 2>/dev/null)
    if [ "$STATUS" == "exists" ]; then
        log_success "幂等性测试通过 (实例已存在)"
    else
        log_error "幂等性测试失败 (应该返回 exists)"
    fi
else
    log_error "幂等性测试失败 (HTTP $HTTP_CODE)"
fi

echo ""
echo "=========================================="
echo "所有测试完成！"
echo "=========================================="
echo ""

# 可选: 删除测试实例
read -p "是否删除测试实例? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]] && [ -n "$USER_ID" ]; then
    log_info "删除测试实例..."
    DELETE_RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE "${API_ENDPOINT}/delete/$USER_ID" \
      -H "Authorization: Bearer $ID_TOKEN")
    HTTP_CODE=$(echo "$DELETE_RESPONSE" | tail -n1)
    BODY=$(echo "$DELETE_RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" == "200" ]; then
        log_success "实例删除成功"
        echo "$BODY" | jq '.' 2>/dev/null || echo "   $BODY"
    else
        log_error "实例删除失败 (HTTP $HTTP_CODE)"
        echo "   $BODY"
    fi
fi
