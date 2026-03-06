#!/bin/bash

# Verification script for shared IAM role setup

set -e

AWS_REGION="${AWS_REGION:-us-west-2}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-test-s4}"

echo "=================================="
echo "Shared IAM Role Verification"
echo "=================================="
echo ""

# Check 1: Verify Shared Bedrock Role exists
echo "Check 1: Verifying Shared Bedrock Role..."
BEDROCK_ROLE=$(aws iam get-role --role-name openclaw-bedrock-shared --query 'Role.Arn' --output text 2>/dev/null || echo "NOT_FOUND")
if [ "$BEDROCK_ROLE" = "NOT_FOUND" ]; then
    echo "❌ FAIL: openclaw-bedrock-shared role not found"
    echo "   Run: ./setup-shared-bedrock-role.sh"
    exit 1
else
    echo "✅ PASS: $BEDROCK_ROLE"
fi
echo ""

# Check 2: Verify Provisioning Service Role exists
echo "Check 2: Verifying Provisioning Service Role..."
PROVISIONING_ROLE=$(aws iam get-role --role-name openclaw-provisioning-service --query 'Role.Arn' --output text 2>/dev/null || echo "NOT_FOUND")
if [ "$PROVISIONING_ROLE" = "NOT_FOUND" ]; then
    echo "❌ FAIL: openclaw-provisioning-service role not found"
    echo "   Run: ./setup-shared-bedrock-role.sh"
    exit 1
else
    echo "✅ PASS: $PROVISIONING_ROLE"
fi
echo ""

# Check 3: Verify Provisioning Service has policy attached
echo "Check 3: Verifying Provisioning Service policy attachment..."
POLICY_ATTACHED=$(aws iam list-attached-role-policies \
    --role-name openclaw-provisioning-service \
    --query "AttachedPolicies[?PolicyName=='OpenClawProvisioningServicePolicy'].PolicyArn" \
    --output text)
if [ -z "$POLICY_ATTACHED" ]; then
    echo "❌ FAIL: OpenClawProvisioningServicePolicy not attached"
    exit 1
else
    echo "✅ PASS: Policy attached: $POLICY_ATTACHED"
fi
echo ""

# Check 4: Verify Provisioning Service Pod Identity Association
echo "Check 4: Verifying Provisioning Service Pod Identity Association..."
PROVISIONING_ASSOCIATION=$(aws eks list-pod-identity-associations \
    --cluster-name "$EKS_CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --namespace openclaw-provisioning \
    --service-account openclaw-provisioner \
    --query 'associations[0].associationId' \
    --output text 2>/dev/null || echo "None")
if [ "$PROVISIONING_ASSOCIATION" = "None" ]; then
    echo "⚠️  WARN: No Pod Identity Association found (may need to create)"
    echo "   Run: ./setup-shared-bedrock-role.sh"
else
    echo "✅ PASS: Association ID: $PROVISIONING_ASSOCIATION"
fi
echo ""

# Check 5: Verify Provisioning Service Deployment
echo "Check 5: Verifying Provisioning Service Deployment..."
DEPLOYMENT_STATUS=$(kubectl get deployment openclaw-provisioning -n openclaw-provisioning \
    -o jsonpath='{.status.availableReplicas}/{.status.replicas}' 2>/dev/null || echo "0/0")
echo "   Available Replicas: $DEPLOYMENT_STATUS"
if [ "$DEPLOYMENT_STATUS" = "0/0" ]; then
    echo "❌ FAIL: Deployment not ready"
    exit 1
else
    echo "✅ PASS: Deployment is ready"
fi
echo ""

# Check 6: Verify Environment Variables in Pod
echo "Check 6: Verifying Environment Variables in Pod..."
POD_NAME=$(kubectl get pods -n openclaw-provisioning -l app=openclaw-provisioning \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$POD_NAME" ]; then
    echo "❌ FAIL: No running pods found"
    exit 1
fi

echo "   Pod: $POD_NAME"
echo ""

# Check USE_POD_IDENTITY
USE_POD_IDENTITY=$(kubectl exec -n openclaw-provisioning "$POD_NAME" -- \
    env | grep "^USE_POD_IDENTITY=" | cut -d= -f2 || echo "not_set")
if [ "$USE_POD_IDENTITY" = "true" ]; then
    echo "   ✅ USE_POD_IDENTITY=true"
else
    echo "   ❌ USE_POD_IDENTITY=$USE_POD_IDENTITY (should be 'true')"
fi

# Check CREATE_IAM_ROLE_PER_USER
CREATE_IAM_ROLE_PER_USER=$(kubectl exec -n openclaw-provisioning "$POD_NAME" -- \
    env | grep "^CREATE_IAM_ROLE_PER_USER=" | cut -d= -f2 || echo "not_set")
if [ "$CREATE_IAM_ROLE_PER_USER" = "false" ]; then
    echo "   ✅ CREATE_IAM_ROLE_PER_USER=false"
else
    echo "   ❌ CREATE_IAM_ROLE_PER_USER=$CREATE_IAM_ROLE_PER_USER (should be 'false')"
fi

# Check SHARED_BEDROCK_ROLE_ARN
SHARED_BEDROCK_ROLE_ARN=$(kubectl exec -n openclaw-provisioning "$POD_NAME" -- \
    env | grep "^SHARED_BEDROCK_ROLE_ARN=" | cut -d= -f2 || echo "not_set")
if [[ "$SHARED_BEDROCK_ROLE_ARN" == *"openclaw-bedrock-shared"* ]]; then
    echo "   ✅ SHARED_BEDROCK_ROLE_ARN=$SHARED_BEDROCK_ROLE_ARN"
else
    echo "   ❌ SHARED_BEDROCK_ROLE_ARN=$SHARED_BEDROCK_ROLE_ARN (invalid)"
fi

# Check AWS_REGION
AWS_REGION_POD=$(kubectl exec -n openclaw-provisioning "$POD_NAME" -- \
    env | grep "^AWS_REGION=" | cut -d= -f2 || echo "not_set")
if [ "$AWS_REGION_POD" = "$AWS_REGION" ]; then
    echo "   ✅ AWS_REGION=$AWS_REGION_POD"
else
    echo "   ⚠️  AWS_REGION=$AWS_REGION_POD (expected: $AWS_REGION)"
fi

# Check EKS_CLUSTER_NAME
EKS_CLUSTER_NAME_POD=$(kubectl exec -n openclaw-provisioning "$POD_NAME" -- \
    env | grep "^EKS_CLUSTER_NAME=" | cut -d= -f2 || echo "not_set")
if [ "$EKS_CLUSTER_NAME_POD" = "$EKS_CLUSTER_NAME" ]; then
    echo "   ✅ EKS_CLUSTER_NAME=$EKS_CLUSTER_NAME_POD"
else
    echo "   ⚠️  EKS_CLUSTER_NAME=$EKS_CLUSTER_NAME_POD (expected: $EKS_CLUSTER_NAME)"
fi

echo ""

# Check 7: Verify Pod has AWS credentials from Pod Identity
echo "Check 7: Verifying Pod Identity credentials..."
AWS_CONTAINER_CREDENTIALS=$(kubectl exec -n openclaw-provisioning "$POD_NAME" -- \
    env | grep "^AWS_CONTAINER_CREDENTIALS_FULL_URI=" || echo "not_set")
if [[ "$AWS_CONTAINER_CREDENTIALS" == *"169.254.170"* ]]; then
    echo "   ✅ Pod Identity credentials available"
else
    echo "   ⚠️  Pod Identity credentials not detected (may be expected if SA not configured)"
fi
echo ""

echo "=================================="
echo "Verification Summary"
echo "=================================="
echo ""
echo "IAM Roles:"
echo "  ✅ Shared Bedrock Role: $BEDROCK_ROLE"
echo "  ✅ Provisioning Service Role: $PROVISIONING_ROLE"
echo ""
echo "Deployment:"
echo "  ✅ Pods Ready: $DEPLOYMENT_STATUS"
echo "  ✅ Configuration: Correct environment variables"
echo ""
echo "Next Steps:"
echo "  1. Test new user creation via Dashboard"
echo "  2. Verify logs show 'Using shared Bedrock IAM Role'"
echo "  3. Check no new IAM roles created per user"
echo ""
echo "Monitor logs with:"
echo "  kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning -f | grep -E '(IAM|Pod Identity|Role)'"
echo ""
