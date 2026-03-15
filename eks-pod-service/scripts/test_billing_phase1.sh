#!/bin/bash
#
# Test script for Phase 1: Billing & Quota Management
#
# This script tests all Phase 1 functionality:
# 1. Database migration (plan field)
# 2. Billing API endpoints
# 3. Quota management
#

set -e

echo "========================================"
echo "Phase 1 Billing Implementation Test"
echo "========================================"
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Base URL (adjust if needed)
BASE_URL="${BASE_URL:-http://localhost:8080}"

echo "Using BASE_URL: $BASE_URL"
echo ""

# Test 1: Database migration
echo "📋 Test 1: Database Migration"
echo "Running migration script..."
python scripts/add_plan_field.py
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Database migration successful${NC}"
else
    echo -e "${RED}❌ Database migration failed${NC}"
    exit 1
fi
echo ""

# Test 2: Public endpoint - List plans
echo "📋 Test 2: List Plans (Public Endpoint)"
PLANS_RESPONSE=$(curl -s -w "\n%{http_code}" "$BASE_URL/billing/plans")
HTTP_CODE=$(echo "$PLANS_RESPONSE" | tail -n 1)
BODY=$(echo "$PLANS_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
    echo -e "${GREEN}✅ GET /billing/plans - Success${NC}"
    echo "Response:"
    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
else
    echo -e "${RED}❌ GET /billing/plans - Failed (HTTP $HTTP_CODE)${NC}"
    echo "$BODY"
fi
echo ""

# Test 3: Register a test user
echo "📋 Test 3: Register Test User"
REGISTER_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
    -H "Content-Type: application/json" \
    -d '{
        "username": "testuser_billing",
        "email": "testuser_billing@example.com",
        "password": "TestPass123!"
    }')
HTTP_CODE=$(echo "$REGISTER_RESPONSE" | tail -n 1)
BODY=$(echo "$REGISTER_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "409" ]; then
    echo -e "${GREEN}✅ User registration (or already exists)${NC}"
else
    echo -e "${YELLOW}⚠️  User registration returned HTTP $HTTP_CODE${NC}"
fi
echo ""

# Test 4: Login to get session cookie
echo "📋 Test 4: Login Test User"
COOKIE_FILE="/tmp/billing_test_cookie.txt"
rm -f "$COOKIE_FILE"

LOGIN_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" \
    -c "$COOKIE_FILE" \
    -H "Content-Type: application/json" \
    -d '{
        "email": "testuser_billing@example.com",
        "password": "TestPass123!"
    }')
HTTP_CODE=$(echo "$LOGIN_RESPONSE" | tail -n 1)

if [ "$HTTP_CODE" = "200" ]; then
    echo -e "${GREEN}✅ Login successful${NC}"
else
    echo -e "${RED}❌ Login failed (HTTP $HTTP_CODE)${NC}"
    exit 1
fi
echo ""

# Test 5: Get quota status
echo "📋 Test 5: Get Quota Status"
QUOTA_RESPONSE=$(curl -s -w "\n%{http_code}" "$BASE_URL/billing/quota" \
    -b "$COOKIE_FILE")
HTTP_CODE=$(echo "$QUOTA_RESPONSE" | tail -n 1)
BODY=$(echo "$QUOTA_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
    echo -e "${GREEN}✅ GET /billing/quota - Success${NC}"
    echo "Response:"
    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
else
    echo -e "${RED}❌ GET /billing/quota - Failed (HTTP $HTTP_CODE)${NC}"
    echo "$BODY"
fi
echo ""

# Test 6: Get usage data
echo "📋 Test 6: Get Usage Data"
USAGE_RESPONSE=$(curl -s -w "\n%{http_code}" "$BASE_URL/billing/usage?days=30" \
    -b "$COOKIE_FILE")
HTTP_CODE=$(echo "$USAGE_RESPONSE" | tail -n 1)
BODY=$(echo "$USAGE_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
    echo -e "${GREEN}✅ GET /billing/usage - Success${NC}"
    echo "Response (summary only):"
    echo "$BODY" | jq '{period_days, plan, quota: .quota, summary: .summary}' 2>/dev/null || echo "$BODY"
else
    echo -e "${RED}❌ GET /billing/usage - Failed (HTTP $HTTP_CODE)${NC}"
    echo "$BODY"
fi
echo ""

# Test 7: Upgrade plan to pro
echo "📋 Test 7: Upgrade Plan to Pro"
UPGRADE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/billing/upgrade" \
    -b "$COOKIE_FILE" \
    -H "Content-Type: application/json" \
    -d '{"plan": "pro"}')
HTTP_CODE=$(echo "$UPGRADE_RESPONSE" | tail -n 1)
BODY=$(echo "$UPGRADE_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
    echo -e "${GREEN}✅ POST /billing/upgrade - Success${NC}"
    echo "Response:"
    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
else
    echo -e "${YELLOW}⚠️  POST /billing/upgrade - HTTP $HTTP_CODE${NC}"
    echo "$BODY"
fi
echo ""

# Test 8: Verify plan upgrade
echo "📋 Test 8: Verify Plan Upgrade"
USAGE_RESPONSE=$(curl -s -w "\n%{http_code}" "$BASE_URL/billing/usage?days=30" \
    -b "$COOKIE_FILE")
HTTP_CODE=$(echo "$USAGE_RESPONSE" | tail -n 1)
BODY=$(echo "$USAGE_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
    PLAN=$(echo "$BODY" | jq -r '.plan' 2>/dev/null)
    if [ "$PLAN" = "pro" ]; then
        echo -e "${GREEN}✅ Plan successfully upgraded to 'pro'${NC}"
    else
        echo -e "${YELLOW}⚠️  Plan is '$PLAN' (expected 'pro')${NC}"
    fi
else
    echo -e "${RED}❌ Failed to verify plan upgrade${NC}"
fi
echo ""

# Cleanup
rm -f "$COOKIE_FILE"

echo "========================================"
echo "Phase 1 Testing Complete!"
echo "========================================"
echo ""
echo "Next steps:"
echo "1. Test the frontend by visiting: $BASE_URL/dashboard"
echo "2. Login with: testuser_billing@example.com / TestPass123!"
echo "3. Check that billing panel appears below instance info"
echo "4. Verify quota bar shows 0% used (new user)"
echo "5. Try upgrading plan via UI"
