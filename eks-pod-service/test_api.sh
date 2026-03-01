#!/bin/bash
# OpenClaw Provisioning Service API 测试脚本

set -e

# 配置
SERVICE_URL="${SERVICE_URL:-http://localhost:8080}"
TEST_EMAIL="testuser@example.com"

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

# 生成 user_id (使用 SHA256，与服务端一致)
USER_ID=$(echo -n "$TEST_EMAIL" | tr '[:upper:]' '[:lower:]' | shasum -a 256 | cut -c1-8)

echo "========================================"
echo "OpenClaw Provisioning Service API 测试"
echo "========================================"
echo "Service URL: $SERVICE_URL"
echo "Test Email: $TEST_EMAIL"
echo "User ID: $USER_ID"
echo ""

# 测试 1: 健康检查
log_info "测试 1: 健康检查"
RESPONSE=$(curl -s -w "\n%{http_code}" "$SERVICE_URL/health")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" == "200" ]; then
    log_success "健康检查通过"
    echo "   $BODY"
else
    log_error "健康检查失败 (HTTP $HTTP_CODE)"
    echo "   $BODY"
    exit 1
fi
echo ""

# 测试 2: 创建实例
log_info "测试 2: 创建实例"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$SERVICE_URL/provision" \
    -H "Content-Type: application/json" \
    -d "{
        \"email\": \"$TEST_EMAIL\",
        \"cognito_sub\": \"test-sub-123\"
    }")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" == "201" ] || [ "$HTTP_CODE" == "200" ]; then
    log_success "实例创建成功"
    echo "   $BODY" | jq '.'
else
    log_error "实例创建失败 (HTTP $HTTP_CODE)"
    echo "   $BODY"
    exit 1
fi
echo ""

# 等待实例就绪
log_info "等待实例就绪 (10 秒)..."
sleep 10

# 测试 3: 查询状态
log_info "测试 3: 查询实例状态"
RESPONSE=$(curl -s -w "\n%{http_code}" "$SERVICE_URL/status/$USER_ID")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" == "200" ]; then
    log_success "状态查询成功"
    echo "   $BODY" | jq '.'
else
    log_error "状态查询失败 (HTTP $HTTP_CODE)"
    echo "   $BODY"
    exit 1
fi
echo ""

# 测试 4: 幂等性测试（再次创建相同实例）
log_info "测试 4: 幂等性测试（再次创建相同实例）"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$SERVICE_URL/provision" \
    -H "Content-Type: application/json" \
    -d "{
        \"email\": \"$TEST_EMAIL\",
        \"cognito_sub\": \"test-sub-123\"
    }")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" == "200" ]; then
    STATUS=$(echo "$BODY" | jq -r '.status')
    if [ "$STATUS" == "exists" ]; then
        log_success "幂等性测试通过 (实例已存在)"
        echo "   $BODY" | jq '.'
    else
        log_error "幂等性测试失败 (应该返回 exists)"
        echo "   $BODY"
        exit 1
    fi
else
    log_error "幂等性测试失败 (HTTP $HTTP_CODE)"
    echo "   $BODY"
    exit 1
fi
echo ""

# 可选: 删除测试实例
read -p "是否删除测试实例? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_info "删除测试实例..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE "$SERVICE_URL/delete/$USER_ID")
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" == "200" ]; then
        log_success "实例删除成功"
        echo "   $BODY" | jq '.'
    else
        log_error "实例删除失败 (HTTP $HTTP_CODE)"
        echo "   $BODY"
    fi
    echo ""
fi

echo "========================================"
echo "所有测试完成！"
echo "========================================"
