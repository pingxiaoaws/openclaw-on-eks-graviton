#!/usr/bin/env bash

##################################################
# Phase 5: End-User Access Testing
##################################################
#
# Creates a test user in Cognito and provides
# access instructions for dashboard testing
#
##################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║            Phase 5: End-User Access Testing                    ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Get environment info
AWS_REGION=$(kubectl config current-context | cut -d: -f4)
USER_POOL_ID=$(kubectl get deployment openclaw-provisioning -n openclaw-provisioning \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="COGNITO_USER_POOL_ID")].value}' 2>/dev/null)
CLOUDFRONT_DOMAIN=$(kubectl get deployment openclaw-provisioning -n openclaw-provisioning \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CLOUDFRONT_DOMAIN")].value}' 2>/dev/null)

if [ -z "$USER_POOL_ID" ] || [ "$USER_POOL_ID" = "null" ]; then
    echo -e "${RED}❌ Cannot retrieve Cognito User Pool ID${NC}"
    echo "   Check that Phase 4 completed successfully"
    exit 1
fi

if [ -z "$CLOUDFRONT_DOMAIN" ] || [ "$CLOUDFRONT_DOMAIN" = "null" ]; then
    echo -e "${RED}❌ Cannot retrieve CloudFront domain${NC}"
    echo "   Check that Phase 4 completed successfully"
    exit 1
fi

echo -e "${BLUE}Step 1/3: Creating test user in Cognito${NC}"
echo "   User Pool ID: $USER_POOL_ID"
echo "   Region: $AWS_REGION"
echo ""

TEST_EMAIL="test-$(date +%s)@example.com"
TEST_PASSWORD="TempPass123!"

if aws cognito-idp admin-create-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "$TEST_EMAIL" \
    --temporary-password "$TEST_PASSWORD" \
    --region "$AWS_REGION" \
    --user-attributes Name=email,Value="$TEST_EMAIL" Name=email_verified,Value=true \
    &>/dev/null; then
    echo -e "${GREEN}✅ Test user created successfully${NC}"
    echo "   Email: $TEST_EMAIL"
    echo "   Temporary Password: $TEST_PASSWORD"
else
    echo -e "${RED}❌ Failed to create test user${NC}"
    echo "   Check AWS permissions for cognito-idp:AdminCreateUser"
    exit 1
fi
echo ""

echo -e "${BLUE}Step 2/3: CloudFront endpoints${NC}"
echo "   CloudFront Domain: $CLOUDFRONT_DOMAIN"
echo "   Login Page: https://$CLOUDFRONT_DOMAIN/login"
echo "   Dashboard: https://$CLOUDFRONT_DOMAIN/dashboard"
echo ""

echo -e "${BLUE}Step 3/3: Manual testing instructions${NC}"
cat << EOF
Please complete the following manual tests in your browser:

${YELLOW}1. Access Login Page${NC}
   URL: https://$CLOUDFRONT_DOMAIN/login

   Expected result:
   - Login page loads without errors (no 502/503)
   - Username and password fields visible
   - "Sign In" button present

${YELLOW}2. Login with Test User${NC}
   Email: $TEST_EMAIL
   Password: $TEST_PASSWORD

   Expected result:
   - Login succeeds
   - Prompt to change password appears

${YELLOW}3. Change Password${NC}
   New password: Choose a secure password

   Expected result:
   - Password change succeeds
   - Redirect to dashboard

${YELLOW}4. Dashboard Validation${NC}
   URL: https://$CLOUDFRONT_DOMAIN/dashboard

   Expected result:
   - Dashboard loads successfully
   - "No instances" message shown
   - "Create New Instance" button visible
   - No JavaScript errors in browser console (F12 → Console)

${YELLOW}5. Browser Console Check${NC}
   Press F12 → Console tab

   Expected result:
   - No red error messages
   - JWT token stored in localStorage (check Application → Local Storage)

${YELLOW}6. Network Tab Check${NC}
   Press F12 → Network tab → Refresh page

   Expected result:
   - /dashboard request returns 200 OK
   - Static assets load successfully
   - API calls (if any) return 200 or appropriate status codes

EOF

echo ""
read -p "Have you completed all manual tests? (yes/no): " -r
echo ""

if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo -e "${GREEN}✅ Phase 5: Manual testing completed${NC}"
    echo ""
    echo "Test user credentials (save for reference):"
    echo "  Email: $TEST_EMAIL"
    echo "  CloudFront: https://$CLOUDFRONT_DOMAIN"
    echo ""
    exit 0
else
    echo -e "${RED}❌ Phase 5: Manual testing not completed${NC}"
    echo "   Complete the tests above before proceeding to Phase 6"
    exit 1
fi
