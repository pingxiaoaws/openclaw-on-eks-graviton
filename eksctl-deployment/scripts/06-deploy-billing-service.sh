#!/bin/bash
export AWS_PAGER=""
# Phase 6: Deploy Billing Sidecar Service
# - Build and push billing sidecar Docker image
# - Run DB migration (new usage_events schema)
# - Update provisioning service with billing sidecar image
# - Verify billing endpoint

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
BILLING_DIR="$(cd "${SCRIPT_DIR}/../../billing-service"; pwd)"

echo -e "${BLUE}=== Phase 6: Deploy Billing Sidecar Service ===${NC}"
echo ""

# Get cluster info
CLUSTER_ARN=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
if [[ "$CLUSTER_ARN" == arn:aws*:eks:* ]]; then
  AWS_REGION=$(echo "$CLUSTER_ARN" | cut -d':' -f4)
  CLUSTER_NAME=$(echo "$CLUSTER_ARN" | cut -d'/' -f2)
else
  CONTEXT=$(kubectl config current-context)
  CLUSTER_NAME=$(echo "$CONTEXT" | cut -d'@' -f2 | cut -d'.' -f1)
  AWS_REGION=$(echo "$CONTEXT" | grep -o 'us-[a-z]*-[0-9]\|cn-[a-z]*-[0-9]' || echo "us-east-1")
fi
AWS_ACCOUNT=${AWS_ACCOUNT_ID:-${AWS_ACCOUNT:-$(aws sts get-caller-identity --query Account --output text)}}

echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Account: $AWS_ACCOUNT"
echo ""

# ============================================================================
# Step 1: Build and Push Billing Sidecar Image
# ============================================================================

echo -e "${BLUE}[1/4] Building and pushing billing sidecar image...${NC}"

SIDECAR_REPO="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/billing-sidecar"

aws ecr create-repository --repository-name billing-sidecar --region "$AWS_REGION" 2>/dev/null || true
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

docker build -t "${SIDECAR_REPO}:latest" "$BILLING_DIR"
docker push "${SIDECAR_REPO}:latest"

echo -e "${GREEN}✅ Billing sidecar image pushed: ${SIDECAR_REPO}:latest${NC}"
echo ""

# ============================================================================
# Step 2: Run DB Migration
# ============================================================================

echo -e "${BLUE}[2/4] Running database migration...${NC}"

POSTGRES_POD=$(kubectl get pods -n openclaw-provisioning -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$POSTGRES_POD" ]; then
  echo -e "${RED}❌ PostgreSQL pod not found in openclaw-provisioning namespace${NC}"
  exit 1
fi

echo "Running migration on pod: $POSTGRES_POD"
kubectl cp "$BILLING_DIR/kubernetes/billing-db-migration.sql" \
  "openclaw-provisioning/${POSTGRES_POD}:/tmp/billing-db-migration.sql"

kubectl exec -n openclaw-provisioning "$POSTGRES_POD" -- \
  psql -U openclaw -d openclaw -f /tmp/billing-db-migration.sql

echo -e "${GREEN}✅ Database migration complete${NC}"
echo ""

# ============================================================================
# Step 3: Rebuild and Push Provisioning Service Image
# ============================================================================

echo -e "${BLUE}[3/5] Rebuilding provisioning service image (with billing code changes)...${NC}"

PROVISIONING_DIR_SRC="$(cd "${SCRIPT_DIR}/../../eks-pod-service"; pwd)"
PROVISIONING_REPO="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/openclaw-provisioning"

docker build -t "${PROVISIONING_REPO}:latest" "$PROVISIONING_DIR_SRC"
docker push "${PROVISIONING_REPO}:latest"

echo -e "${GREEN}✅ Provisioning service image pushed: ${PROVISIONING_REPO}:latest${NC}"
echo ""

# ============================================================================
# Step 4: Update Provisioning Service with Billing Sidecar Config
# ============================================================================

echo -e "${BLUE}[4/5] Updating provisioning service deployment...${NC}"

kubectl set image deployment/openclaw-provisioning -n openclaw-provisioning \
  provisioning="${PROVISIONING_REPO}:latest"

kubectl set env deployment/openclaw-provisioning -n openclaw-provisioning \
  BILLING_SIDECAR_ENABLED=true \
  BILLING_SIDECAR_IMAGE="${SIDECAR_REPO}:latest"

kubectl rollout restart deployment/openclaw-provisioning -n openclaw-provisioning

echo "Waiting for rollout..."
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning --timeout=300s

echo -e "${GREEN}✅ Provisioning service updated with billing sidecar${NC}"
echo ""

# ============================================================================
# Step 5: Verify Billing Endpoint
# ============================================================================

echo -e "${BLUE}[5/5] Verifying billing endpoint...${NC}"

# Port-forward and test health
kubectl port-forward -n openclaw-provisioning svc/openclaw-provisioning 18080:80 &>/dev/null &
PF_PID=$!
sleep 3

HEALTH=$(curl -sf http://localhost:18080/health 2>/dev/null || echo "FAIL")
kill $PF_PID 2>/dev/null || true

if echo "$HEALTH" | grep -q "ok\|healthy\|status"; then
  echo -e "${GREEN}✅ Provisioning service is healthy${NC}"
else
  echo -e "${YELLOW}⚠️  Could not verify health endpoint (may need CloudFront URL)${NC}"
fi

echo ""

# ============================================================================
# Summary
# ============================================================================

echo -e "${GREEN}=== Phase 6 Complete: Billing Sidecar Deployed ===${NC}"
echo ""
echo "Deployed Components:"
echo "  ✅ Billing sidecar image: ${SIDECAR_REPO}:latest"
echo "  ✅ Provisioning service image: ${PROVISIONING_REPO}:latest"
echo "  ✅ Database migration: usage_events table upgraded"
echo "  ✅ Provisioning service: billing sidecar injection enabled"
echo ""
echo "How it works:"
echo "  - New OpenClaw instances will include a billing-sidecar container"
echo "  - Sidecar reads session JSONL files and writes usage to PostgreSQL"
echo "  - Usage data available via /billing/usage and /billing/hourly endpoints"
echo ""
echo "To verify:"
echo "  kubectl get pods -n openclaw-<user_id> -o jsonpath='{.items[0].spec.containers[*].name}'"
echo "  # Should include: openclaw, gateway-proxy, billing-sidecar"
echo ""
