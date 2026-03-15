#!/bin/bash
#
# Build, Push, Deploy OpenClaw Provisioning Service
# One-command deployment script for code changes
#
# Usage:
#   Run on Graviton EC2: ./build-and-push-image.sh
#   Run from local (deploys only): ./build-and-push-image.sh local
#

set -e

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

# Configuration
REPO_DIR="$HOME/openclaw-on-eks-graviton"
ECR_REGISTRY="970547376847.dkr.ecr.us-west-2.amazonaws.com"
ECR_REPO="openclaw-provisioning-chinaregion"
IMAGE_TAG="latest"
REGION="us-west-2"
CLOUDFRONT_DIST_ID="EVL5DO4JCHMXB"
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
    echo -e "${YELLOW}Step 1/7: Updating code from git${NC}"
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
    echo -e "${YELLOW}Step 2/7: Logging in to ECR${NC}"
    aws ecr get-login-password --region "$REGION" | \
      docker login --username AWS --password-stdin "$ECR_REGISTRY"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ ECR login successful${NC}"
    else
        echo -e "${RED}❌ ECR login failed${NC}"
        exit 1
    fi
    echo ""

    # Step 3: Build Docker image
    echo -e "${YELLOW}Step 3/7: Building Docker image (ARM64)${NC}"
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
    echo -e "${YELLOW}Step 4/7: Pushing image to ECR${NC}"
    docker push "$ECR_REGISTRY/$ECR_REPO:$IMAGE_TAG"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Image pushed to ECR${NC}"
    else
        echo -e "${RED}❌ Docker push failed${NC}"
        exit 1
    fi
    echo ""

    # Step 5: Verify image
    echo -e "${YELLOW}Step 5/7: Verifying image in ECR${NC}"
    IMAGE_DIGEST=$(aws ecr describe-images \
      --repository-name "$ECR_REPO" \
      --image-ids imageTag="$IMAGE_TAG" \
      --region "$REGION" \
      --query 'imageDetails[0].imageDigest' \
      --output text)

    if [ -n "$IMAGE_DIGEST" ] && [ "$IMAGE_DIGEST" != "None" ]; then
        echo -e "${GREEN}✅ Image verified in ECR${NC}"
        echo "   Digest: $IMAGE_DIGEST"
    else
        echo -e "${RED}❌ Image verification failed${NC}"
        exit 1
    fi
    echo ""
fi

# Step 6: Restart K8s deployment (works from both local and remote)
echo -e "${YELLOW}Step 6/7: Restarting Kubernetes deployment${NC}"
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

# Step 7: Invalidate CloudFront cache
echo -e "${YELLOW}Step 7/7: Invalidating CloudFront cache${NC}"
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
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}✅ Deployment completed!${NC}"
echo "=========================================="
echo ""

if [ "$LOCAL_MODE" != "local" ]; then
    echo "📦 Image:"
    echo "   URI: $ECR_REGISTRY/$ECR_REPO:$IMAGE_TAG"
    echo "   Digest: $IMAGE_DIGEST"
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
