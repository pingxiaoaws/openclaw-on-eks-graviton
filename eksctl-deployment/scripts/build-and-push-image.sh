#!/bin/bash
export AWS_PAGER=""
#
# Build, Push, Deploy OpenClaw Provisioning Service
# One-command deployment script for code changes
#
# Usage:
#   Run on Graviton EC2: ./build-and-push-image.sh
#   Run from local (deploys only): ./build-and-push-image.sh local
#

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "=========================================="
echo "OpenClaw Provisioning - Complete Deploy"
echo "=========================================="
echo ""

# Configuration (use env vars when available, fall back to defaults)
REPO_DIR="${REPO_DIR:-$HOME/openclaw-on-eks-graviton}"

# Resolve region from cluster ARN (same logic as 05-deploy script)
if [ -z "${AWS_REGION:-${REGION:-}}" ]; then
  CLUSTER_ARN=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || echo "")
  if [[ "$CLUSTER_ARN" == arn:aws*:eks:* ]]; then
    REGION=$(echo "$CLUSTER_ARN" | cut -d':' -f4)
  else
    REGION="us-west-2"
  fi
else
  REGION="${AWS_REGION:-${REGION:-us-west-2}}"
fi

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-${AWS_ACCOUNT:-$(aws sts get-caller-identity --query Account --output text)}}"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
ECR_REPO="${ECR_REPO:-openclaw-provisioning}"
BILLING_SIDECAR_REPO="billing-sidecar"
IMAGE_TAG="${IMAGE_TAG:-latest}"
CLOUDFRONT_DIST_ID="${CLOUDFRONT_DIST_ID:-}"
K8S_NAMESPACE="openclaw-provisioning"
K8S_DEPLOYMENT="openclaw-provisioning"

# Check if running in local mode (deploy only, skip build)
LOCAL_MODE="${1:-}"

if [ "$LOCAL_MODE" == "local" ]; then
    echo -e "${BLUE}Running in LOCAL mode (deploy only)${NC}"
    echo ""
else
    echo -e "${BLUE}Running in REMOTE mode (full build + deploy)${NC}"
    echo ""

    echo "Configuration:"
    echo "  Repo Dir: $REPO_DIR"
    echo "  ECR Registry: $ECR_REGISTRY"
    echo "  ECR Repo: $ECR_REPO"
    echo "  Image Tag: $IMAGE_TAG"
    echo "  Region: $REGION"
    echo ""

    # Step 1: Update code from git
    echo -e "${YELLOW}Step 1/8: Updating code from git${NC}"
    cd "$REPO_DIR"
    git fetch origin
    git pull origin china-region
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Code updated successfully${NC}"
    else
        echo -e "${RED}❌ Failed to update code${NC}"
        exit 1
    fi
    echo ""

    # Step 2: Login to ECR
    echo -e "${YELLOW}Step 2/8: Logging in to ECR${NC}"
    aws ecr get-login-password --region "$REGION" | \
      docker login --username AWS --password-stdin "$ECR_REGISTRY"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ ECR login successful${NC}"
    else
        echo -e "${RED}❌ ECR login failed${NC}"
        exit 1
    fi
    echo ""

    # Ensure ECR repository exists
    aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" &>/dev/null || \
      aws ecr create-repository --repository-name "$ECR_REPO" --region "$REGION" --query 'repository.repositoryUri' --output text
    echo -e "${GREEN}✅ ECR repository ready${NC}"
    echo ""

    # Step 3: Build Docker image
    echo -e "${YELLOW}Step 3/8: Building Docker image (ARM64)${NC}"
    cd "$REPO_DIR/eks-pod-service"
    docker build --platform linux/arm64 -t "$ECR_REGISTRY/$ECR_REPO:$IMAGE_TAG" .
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Docker image built successfully${NC}"
    else
        echo -e "${RED}❌ Docker build failed${NC}"
        exit 1
    fi
    echo ""

    # Step 4: Push to ECR
    echo -e "${YELLOW}Step 4/8: Pushing image to ECR${NC}"
    docker push "$ECR_REGISTRY/$ECR_REPO:$IMAGE_TAG"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Image pushed to ECR${NC}"
    else
        echo -e "${RED}❌ Docker push failed${NC}"
        exit 1
    fi
    echo ""

    # Step 5: Build and push billing sidecar image
    echo -e "${YELLOW}Step 5/8: Building and pushing billing sidecar image${NC}"

    # Ensure billing sidecar ECR repo exists
    aws ecr describe-repositories --repository-names "$BILLING_SIDECAR_REPO" --region "$REGION" &>/dev/null || \
      aws ecr create-repository --repository-name "$BILLING_SIDECAR_REPO" --region "$REGION" --query 'repository.repositoryUri' --output text
    echo -e "${GREEN}✅ Billing sidecar ECR repository ready${NC}"

    BILLING_SIDECAR_DIR="$REPO_DIR/billing-service"
    if [ ! -d "$BILLING_SIDECAR_DIR" ]; then
        echo -e "${RED}❌ Billing service directory not found: $BILLING_SIDECAR_DIR${NC}"
        exit 1
    fi

    BILLING_SIDECAR_IMAGE="$ECR_REGISTRY/$BILLING_SIDECAR_REPO:$IMAGE_TAG"
    docker build --platform linux/arm64 -t "$BILLING_SIDECAR_IMAGE" "$BILLING_SIDECAR_DIR"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Billing sidecar image built successfully${NC}"
    else
        echo -e "${RED}❌ Billing sidecar build failed${NC}"
        exit 1
    fi

    docker push "$BILLING_SIDECAR_IMAGE"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Billing sidecar image pushed to ECR${NC}"
    else
        echo -e "${RED}❌ Billing sidecar push failed${NC}"
        exit 1
    fi
    echo ""
fi

# Step 6: Set billing sidecar env var on deployment
echo -e "${YELLOW}Step 6/8: Setting billing sidecar image on deployment${NC}"
BILLING_SIDECAR_IMAGE="${BILLING_SIDECAR_IMAGE:-$ECR_REGISTRY/$BILLING_SIDECAR_REPO:$IMAGE_TAG}"
kubectl set env deployment "$K8S_DEPLOYMENT" -n "$K8S_NAMESPACE" \
  BILLING_SIDECAR_IMAGE="$BILLING_SIDECAR_IMAGE"
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Billing sidecar image env var set${NC}"
else
    echo -e "${RED}❌ Failed to set billing sidecar env var${NC}"
    exit 1
fi
echo ""

# Step 7: Restart K8s deployment (works from both local and remote)
echo -e "${YELLOW}Step 7/8: Restarting Kubernetes deployment${NC}"
kubectl rollout restart deployment "$K8S_DEPLOYMENT" -n "$K8S_NAMESPACE"
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Rollout initiated${NC}"
else
    echo -e "${RED}❌ Failed to restart deployment${NC}"
    exit 1
fi

echo "   Waiting for rollout to complete (max 3 minutes)..."
kubectl rollout status deployment "$K8S_DEPLOYMENT" -n "$K8S_NAMESPACE" --timeout=3m
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Deployment rolled out successfully${NC}"
else
    echo -e "${RED}❌ Rollout failed or timed out${NC}"
    exit 1
fi
echo ""

# Step 8: Invalidate CloudFront cache (optional)
echo -e "${YELLOW}Step 8/8: Invalidating CloudFront cache${NC}"
if [ -z "$CLOUDFRONT_DIST_ID" ]; then
    echo -e "${YELLOW}⚠️  CLOUDFRONT_DIST_ID not set, skipping cache invalidation${NC}"
    INVALIDATION_ID="N/A"
else
    INVALIDATION_OUTPUT=$(aws cloudfront create-invalidation \
      --distribution-id "$CLOUDFRONT_DIST_ID" \
      --paths "/*" \
      --query 'Invalidation.{Id:Id,Status:Status}' \
      --output json 2>&1)

    if [ $? -eq 0 ]; then
        INVALIDATION_ID=$(echo "$INVALIDATION_OUTPUT" | jq -r '.Id')
        echo -e "${GREEN}✅ CloudFront cache invalidation created${NC}"
        echo "   Invalidation ID: $INVALIDATION_ID"
        echo "   Status: InProgress (will complete in 1-2 minutes)"
    else
        echo -e "${RED}❌ Failed to create invalidation${NC}"
        echo "$INVALIDATION_OUTPUT"
        exit 1
    fi
fi
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}✅ Deployment completed!${NC}"
echo "=========================================="
echo ""

if [ "$LOCAL_MODE" != "local" ]; then
    echo "📦 Images:"
    echo "   Provisioning: $ECR_REGISTRY/$ECR_REPO:$IMAGE_TAG"
    echo "   Billing Sidecar: $ECR_REGISTRY/$BILLING_SIDECAR_REPO:$IMAGE_TAG"
    echo ""
fi

echo "🚀 Kubernetes:"
kubectl get pods -n "$K8S_NAMESPACE" -o wide
echo ""

echo "🌐 CloudFront:"
echo "   Distribution: $CLOUDFRONT_DIST_ID"
echo "   Invalidation: $INVALIDATION_ID"
echo "   Status: Cache clearing (1-2 minutes)"
echo ""

echo "✅ Next steps:"
echo "   1. Wait 1-2 minutes for CloudFront cache to clear"
echo "   2. Clear your browser cache (Cmd+Shift+R)"
echo "   3. Test the application at CloudFront URL"
echo ""
echo "📝 Check logs:"
echo "   kubectl logs -n $K8S_NAMESPACE -l app=$K8S_DEPLOYMENT --tail=50 -f"
echo ""
