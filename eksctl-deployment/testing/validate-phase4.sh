#!/usr/bin/env bash

##################################################
# Phase 4 Validation: Application Stack
##################################################
#
# Validates that application stack was deployed correctly:
# - OpenClaw Operator
# - Bedrock IAM Role and Policy
# - Pod Identity Association
# - Cognito User Pool and Client
# - Provisioning Service with ALL env vars
# - ALB is internet-facing
# - CloudFront distribution
#
##################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Validation counters
CHECKS_PASSED=0
CHECKS_FAILED=0

check_pass() {
    echo -e "${GREEN}✅${NC} $1"
    ((CHECKS_PASSED++))
}

check_fail() {
    echo -e "${RED}❌${NC} $1"
    ((CHECKS_FAILED++))
}

check_warning() {
    echo -e "${YELLOW}⚠️ ${NC} $1"
}

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║         Phase 4 Validation: Application Stack                  ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Get cluster info
CLUSTER_NAME=$(kubectl config current-context | cut -d/ -f2 | cut -d@ -f1)
AWS_REGION=$(kubectl config current-context | cut -d: -f4)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Check 1: OpenClaw Operator
echo "Checking OpenClaw Operator..."
OPERATOR_REPLICAS=$(kubectl get deployment -n openclaw-operator-system openclaw-operator -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
OPERATOR_READY=$(kubectl get deployment -n openclaw-operator-system openclaw-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "$OPERATOR_REPLICAS" -eq "$OPERATOR_READY" ] && [ "$OPERATOR_READY" -gt 0 ]; then
    check_pass "OpenClaw Operator: $OPERATOR_READY/$OPERATOR_REPLICAS replicas ready"
else
    check_fail "OpenClaw Operator: $OPERATOR_READY/$OPERATOR_REPLICAS replicas ready"
fi

# Check CRD
if kubectl get crd openclawinstances.openclaw.rocks &>/dev/null; then
    check_pass "OpenClawInstance CRD exists"
else
    check_fail "OpenClawInstance CRD not found"
fi
echo ""

# Check 2: Bedrock IAM Resources
echo "Checking Bedrock IAM Resources..."
if aws iam get-role --role-name OpenClawBedrockRole &>/dev/null; then
    check_pass "IAM Role: OpenClawBedrockRole exists"
else
    check_fail "IAM Role: OpenClawBedrockRole not found"
fi

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/OpenClawBedrockAccess"
if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
    check_pass "IAM Policy: OpenClawBedrockAccess exists"
else
    check_fail "IAM Policy: OpenClawBedrockAccess not found"
fi
echo ""

# Check 3: Pod Identity Association
echo "Checking Pod Identity Association..."
POD_IDENTITY_COUNT=$(aws eks list-pod-identity-associations \
    --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'associations' \
    --output json 2>/dev/null | jq '. | length' || echo "0")

if [ "$POD_IDENTITY_COUNT" -gt 0 ]; then
    check_pass "Pod Identity: $POD_IDENTITY_COUNT association(s) found"
else
    check_fail "Pod Identity: No associations found"
fi
echo ""

# Check 4: Cognito User Pool
echo "Checking Cognito User Pool..."
USER_POOL_ID=$(aws cognito-idp list-user-pools --max-results 60 --region "$AWS_REGION" \
    --query "UserPools[?Name=='openclaw-users-${CLUSTER_NAME}'].Id" \
    --output text 2>/dev/null)

if [ -n "$USER_POOL_ID" ]; then
    check_pass "Cognito User Pool: $USER_POOL_ID"

    # Check client
    CLIENT_COUNT=$(aws cognito-idp list-user-pool-clients --user-pool-id "$USER_POOL_ID" --region "$AWS_REGION" \
        --query 'UserPoolClients' --output json 2>/dev/null | jq '. | length' || echo "0")
    if [ "$CLIENT_COUNT" -gt 0 ]; then
        CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id "$USER_POOL_ID" --region "$AWS_REGION" \
            --query 'UserPoolClients[0].ClientId' --output text)
        check_pass "Cognito Client: $CLIENT_ID"
    else
        check_fail "Cognito Client not found"
    fi
else
    check_fail "Cognito User Pool not found"
fi
echo ""

# Check 5: Provisioning Service
echo "Checking Provisioning Service..."
PROV_REPLICAS=$(kubectl get deployment -n openclaw-provisioning openclaw-provisioning -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
PROV_READY=$(kubectl get deployment -n openclaw-provisioning openclaw-provisioning -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "$PROV_REPLICAS" -eq "$PROV_READY" ] && [ "$PROV_READY" -gt 0 ]; then
    check_pass "Provisioning Service: $PROV_READY/$PROV_REPLICAS replicas ready"
else
    check_fail "Provisioning Service: $PROV_READY/$PROV_REPLICAS replicas ready"
fi
echo ""

# Check 6: CRITICAL - Environment Variables
echo "Checking Environment Variables (CRITICAL)..."
ENV_VARS=$(kubectl get deployment openclaw-provisioning -n openclaw-provisioning \
    -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null || echo "[]")

# Check Cognito variables
COGNITO_REGION=$(echo "$ENV_VARS" | jq -r '.[] | select(.name=="COGNITO_REGION") | .value' 2>/dev/null || echo "")
COGNITO_USER_POOL_ID=$(echo "$ENV_VARS" | jq -r '.[] | select(.name=="COGNITO_USER_POOL_ID") | .value' 2>/dev/null || echo "")
COGNITO_CLIENT_ID=$(echo "$ENV_VARS" | jq -r '.[] | select(.name=="COGNITO_CLIENT_ID") | .value' 2>/dev/null || echo "")

if [ -n "$COGNITO_REGION" ] && [ "$COGNITO_REGION" != "null" ]; then
    check_pass "COGNITO_REGION: $COGNITO_REGION"
else
    check_fail "COGNITO_REGION: not set or empty"
fi

if [ -n "$COGNITO_USER_POOL_ID" ] && [ "$COGNITO_USER_POOL_ID" != "null" ]; then
    check_pass "COGNITO_USER_POOL_ID: $COGNITO_USER_POOL_ID"
else
    check_fail "COGNITO_USER_POOL_ID: not set or empty"
fi

if [ -n "$COGNITO_CLIENT_ID" ] && [ "$COGNITO_CLIENT_ID" != "null" ]; then
    check_pass "COGNITO_CLIENT_ID: ${COGNITO_CLIENT_ID:0:20}..."
else
    check_fail "COGNITO_CLIENT_ID: not set or empty"
fi

# Check CloudFront variables
CLOUDFRONT_DOMAIN=$(echo "$ENV_VARS" | jq -r '.[] | select(.name=="CLOUDFRONT_DOMAIN") | .value' 2>/dev/null || echo "")
CLOUDFRONT_DIST_ID=$(echo "$ENV_VARS" | jq -r '.[] | select(.name=="CLOUDFRONT_DISTRIBUTION_ID") | .value' 2>/dev/null || echo "")

if [ -n "$CLOUDFRONT_DOMAIN" ] && [ "$CLOUDFRONT_DOMAIN" != "null" ]; then
    check_pass "CLOUDFRONT_DOMAIN: $CLOUDFRONT_DOMAIN"
else
    check_fail "CLOUDFRONT_DOMAIN: not set or empty"
fi

if [ -n "$CLOUDFRONT_DIST_ID" ] && [ "$CLOUDFRONT_DIST_ID" != "null" ]; then
    check_pass "CLOUDFRONT_DISTRIBUTION_ID: $CLOUDFRONT_DIST_ID"
else
    check_fail "CLOUDFRONT_DISTRIBUTION_ID: not set or empty"
fi
echo ""

# Check 7: ALB Configuration
echo "Checking ALB Configuration..."
if kubectl get ingress openclaw-provisioning-ingress -n openclaw-provisioning &>/dev/null; then
    ALB_DNS=$(kubectl get ingress openclaw-provisioning-ingress -n openclaw-provisioning \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)

    if [ -n "$ALB_DNS" ]; then
        check_pass "ALB DNS: $ALB_DNS"

        # Check if ALB is internet-facing
        ALB_ARN=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
            --query "LoadBalancers[?DNSName=='$ALB_DNS'].LoadBalancerArn" \
            --output text 2>/dev/null)

        if [ -n "$ALB_ARN" ]; then
            ALB_SCHEME=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
                --load-balancer-arns "$ALB_ARN" \
                --query "LoadBalancers[0].Scheme" \
                --output text 2>/dev/null)

            if [ "$ALB_SCHEME" = "internet-facing" ]; then
                check_pass "ALB Scheme: internet-facing"
            else
                check_fail "ALB Scheme: $ALB_SCHEME (expected: internet-facing)"
            fi
        else
            check_fail "ALB ARN not found"
        fi
    else
        check_fail "ALB DNS not assigned to ingress"
    fi
else
    check_fail "Ingress openclaw-provisioning-ingress not found"
fi
echo ""

# Check 8: CloudFront Distribution
echo "Checking CloudFront Distribution..."
CLOUDFRONT_DIST_ID_AWS=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Comment=='OpenClaw-${CLUSTER_NAME}'].Id" \
    --output text 2>/dev/null)

if [ -n "$CLOUDFRONT_DIST_ID_AWS" ]; then
    CLOUDFRONT_STATUS=$(aws cloudfront get-distribution --id "$CLOUDFRONT_DIST_ID_AWS" \
        --query 'Distribution.Status' --output text 2>/dev/null)

    if [ "$CLOUDFRONT_STATUS" = "Deployed" ]; then
        check_pass "CloudFront Distribution: $CLOUDFRONT_DIST_ID_AWS (Deployed)"

        CLOUDFRONT_DOMAIN_AWS=$(aws cloudfront get-distribution --id "$CLOUDFRONT_DIST_ID_AWS" \
            --query 'Distribution.DomainName' --output text 2>/dev/null)
        check_pass "CloudFront Domain: $CLOUDFRONT_DOMAIN_AWS"
    else
        check_warning "CloudFront Distribution: $CLOUDFRONT_DIST_ID_AWS ($CLOUDFRONT_STATUS)"
    fi
else
    check_fail "CloudFront Distribution not found"
fi
echo ""

# Check 9: Service Logs (quick check for errors)
echo "Checking Service Logs..."
LOG_ERRORS=$(kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=50 2>/dev/null | grep -i "error" | wc -l || echo "0")
if [ "$LOG_ERRORS" -eq 0 ]; then
    check_pass "No recent errors in service logs"
else
    check_warning "Found $LOG_ERRORS error messages in recent logs (review manually)"
fi
echo ""

# Summary
echo "════════════════════════════════════════════════════════════════"
echo "Validation Summary:"
echo "  ✅ Passed: $CHECKS_PASSED"
echo "  ❌ Failed: $CHECKS_FAILED"
echo "════════════════════════════════════════════════════════════════"

if [ $CHECKS_FAILED -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✅ Phase 4 validation PASSED${NC}"
    echo ""
    echo "Next Steps:"
    echo "  1. Access CloudFront: https://$CLOUDFRONT_DOMAIN"
    echo "  2. Create test user in Cognito"
    echo "  3. Test dashboard login"
    exit 0
else
    echo ""
    echo -e "${RED}❌ Phase 4 validation FAILED${NC}"
    echo ""
    echo "Review failed checks above and:"
    echo "  1. Check deployment logs"
    echo "  2. Verify script execution order"
    echo "  3. Re-run: ../scripts/04-deploy-application-stack.sh"
    exit 1
fi
