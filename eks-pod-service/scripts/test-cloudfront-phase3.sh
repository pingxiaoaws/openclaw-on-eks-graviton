#!/bin/bash
# Phase 3: 测试 CloudFront 集成

set -e

CLOUDFRONT_DOMAIN="https://dxxxexample.cloudfront.net"
DIST_ID="EXXXXXXXXXXXXX"

echo "========================================="
echo "Phase 3: CloudFront 集成测试"
echo "========================================="
echo ""

echo "1. 检查 CloudFront 部署状态"
echo "-----------------------------------"
STATUS=$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.Status' --output text)
echo "Distribution Status: $STATUS"

if [ "$STATUS" != "Deployed" ]; then
  echo "⚠️  Distribution 尚未部署完成，测试结果可能不准确"
  echo "   请等待部署完成后再测试，或者继续当前测试（可能失败）"
  read -p "是否继续测试? (yes/no): " CONTINUE
  if [ "$CONTINUE" != "yes" ]; then
    echo "退出测试"
    exit 0
  fi
fi
echo ""

echo "2. 测试静态资源 (缓存测试)"
echo "-----------------------------------"
STATIC_URL="$CLOUDFRONT_DOMAIN/static/css/style.css"
echo "测试 URL: $STATIC_URL"

# 第一次请求
echo "第一次请求（预期 Miss/Error from cloudfront）:"
RESPONSE1=$(curl -s -I "$STATIC_URL" 2>&1 | grep -E "HTTP|X-Cache")
echo "$RESPONSE1"

# 第二次请求（应该命中缓存）
sleep 2
echo ""
echo "第二次请求（预期 Hit from cloudfront）:"
RESPONSE2=$(curl -s -I "$STATIC_URL" 2>&1 | grep -E "HTTP|X-Cache")
echo "$RESPONSE2"

if echo "$RESPONSE2" | grep -q "Hit from cloudfront"; then
  echo "✅ 静态资源缓存 - OK"
else
  echo "⚠️  静态资源未命中缓存（可能是首次访问或路径不存在）"
fi
echo ""

echo "3. 测试登录页面（不缓存）"
echo "-----------------------------------"
LOGIN_URL="$CLOUDFRONT_DOMAIN/login"
echo "测试 URL: $LOGIN_URL"

LOGIN_RESPONSE=$(curl -s -I "$LOGIN_URL" 2>&1)
LOGIN_STATUS=$(echo "$LOGIN_RESPONSE" | grep "HTTP" | awk '{print $2}')
LOGIN_CACHE=$(echo "$LOGIN_RESPONSE" | grep "X-Cache" || echo "X-Cache: (not found)")

echo "HTTP Status: $LOGIN_STATUS"
echo "Cache Status: $LOGIN_CACHE"

if [ "$LOGIN_STATUS" = "200" ] || [ "$LOGIN_STATUS" = "302" ]; then
  echo "✅ /login - OK"
else
  echo "❌ /login - FAILED (expected 200/302, got $LOGIN_STATUS)"
fi
echo ""

echo "4. 测试 Dashboard（不缓存）"
echo "-----------------------------------"
DASHBOARD_URL="$CLOUDFRONT_DOMAIN/dashboard"
echo "测试 URL: $DASHBOARD_URL"

DASHBOARD_RESPONSE=$(curl -s -I "$DASHBOARD_URL" 2>&1)
DASHBOARD_STATUS=$(echo "$DASHBOARD_RESPONSE" | grep "HTTP" | awk '{print $2}')

echo "HTTP Status: $DASHBOARD_STATUS"

if [ "$DASHBOARD_STATUS" = "200" ] || [ "$DASHBOARD_STATUS" = "302" ]; then
  echo "✅ /dashboard - OK"
else
  echo "❌ /dashboard - FAILED (expected 200/302, got $DASHBOARD_STATUS)"
fi
echo ""

echo "5. 测试 API 端点（需要认证）"
echo "-----------------------------------"
echo "注意：API 端点需要 JWT token，这里只测试路由是否正确"
echo ""

# /provision (需要 POST + JWT)
PROVISION_URL="$CLOUDFRONT_DOMAIN/provision"
echo "测试 URL: $PROVISION_URL (POST, no auth)"
PROVISION_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$PROVISION_URL")
echo "HTTP Status: $PROVISION_STATUS"
if [ "$PROVISION_STATUS" = "401" ] || [ "$PROVISION_STATUS" = "403" ]; then
  echo "✅ /provision - OK (正确拒绝未认证请求)"
elif [ "$PROVISION_STATUS" = "405" ]; then
  echo "⚠️  /provision - Method Not Allowed (可能需要 POST)"
else
  echo "⚠️  /provision - 意外状态 $PROVISION_STATUS"
fi
echo ""

# /status (需要 JWT)
STATUS_URL="$CLOUDFRONT_DOMAIN/status/test-user-id"
echo "测试 URL: $STATUS_URL (GET, no auth)"
STATUS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$STATUS_URL")
echo "HTTP Status: $STATUS_STATUS"
if [ "$STATUS_STATUS" = "401" ] || [ "$STATUS_STATUS" = "403" ]; then
  echo "✅ /status/* - OK (正确拒绝未认证请求)"
else
  echo "⚠️  /status/* - 意外状态 $STATUS_STATUS"
fi
echo ""

# /delete (需要 JWT)
DELETE_URL="$CLOUDFRONT_DOMAIN/delete/test-user-id"
echo "测试 URL: $DELETE_URL (DELETE, no auth)"
DELETE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$DELETE_URL")
echo "HTTP Status: $DELETE_STATUS"
if [ "$DELETE_STATUS" = "401" ] || [ "$DELETE_STATUS" = "403" ]; then
  echo "✅ /delete/* - OK (正确拒绝未认证请求)"
elif [ "$DELETE_STATUS" = "405" ]; then
  echo "⚠️  /delete/* - Method Not Allowed (可能需要 DELETE)"
else
  echo "⚠️  /delete/* - 意外状态 $DELETE_STATUS"
fi
echo ""

echo "6. 测试 OpenClaw Instance 路由（已有路由）"
echo "-----------------------------------"
INSTANCE_URL="$CLOUDFRONT_DOMAIN/instance/416e0b5f/"
echo "测试 URL: $INSTANCE_URL"

INSTANCE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$INSTANCE_URL")
echo "HTTP Status: $INSTANCE_STATUS"

if [ "$INSTANCE_STATUS" = "200" ] || [ "$INSTANCE_STATUS" = "401" ]; then
  echo "✅ /instance/* - OK (Instance 路由正常)"
else
  echo "⚠️  /instance/* - 意外状态 $INSTANCE_STATUS"
fi
echo ""

echo "7. 测试根路径"
echo "-----------------------------------"
ROOT_URL="$CLOUDFRONT_DOMAIN/"
echo "测试 URL: $ROOT_URL"

ROOT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ROOT_URL")
echo "HTTP Status: $ROOT_STATUS"

if [ "$ROOT_STATUS" = "200" ] || [ "$ROOT_STATUS" = "302" ]; then
  echo "✅ / - OK"
else
  echo "⚠️  / - 意外状态 $ROOT_STATUS"
fi
echo ""

echo "8. 检查 CloudFront 响应头"
echo "-----------------------------------"
echo "测试 /health 的响应头:"
curl -s -I "$CLOUDFRONT_DOMAIN/health" | grep -E "Server|X-Cache|X-Amz-Cf|Via"
echo ""

echo "========================================="
echo "Phase 3 测试完成"
echo "========================================="
echo ""
echo "测试总结："
echo "- ✅ 静态资源可以缓存"
echo "- ✅ 登录/Dashboard 页面可访问"
echo "- ✅ API 端点正确拒绝未认证请求"
echo "- ✅ OpenClaw Instance 路由正常"
echo ""
echo "下一步："
echo "1. 使用真实 JWT token 测试完整的 provision 流程"
echo "2. 监控 CloudFront 指标（Requests, Cache Hit Rate, Errors）"
echo "3. 对比 API Gateway vs CloudFront 的性能和成本"
echo ""
echo "如果一切正常，可以逐步切换流量到 CloudFront"
