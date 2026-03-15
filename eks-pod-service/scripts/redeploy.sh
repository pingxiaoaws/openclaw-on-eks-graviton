#!/bin/bash
#
# Quick redeploy script for openclaw-provisioning
# Rebuilds Docker image and redeploys to K8s
#

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "========================================"
echo "OpenClaw Provisioning - Redeploy"
echo "========================================"
echo ""

# Configuration
ECR_REPO="${ECR_REPO:-111122223333.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
NAMESPACE="${NAMESPACE:-openclaw-provisioning}"
DEPLOYMENT="${DEPLOYMENT:-openclaw-provisioning}"

echo "Configuration:"
echo "  ECR Repo: $ECR_REPO"
echo "  Image Tag: $IMAGE_TAG"
echo "  Namespace: $NAMESPACE"
echo "  Deployment: $DEPLOYMENT"
echo ""

# Step 1: ECR Login
echo -e "${YELLOW}Step 1: Login to ECR${NC}"
AWS_REGION=$(echo $ECR_REPO | cut -d'.' -f4)
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $ECR_REPO
echo -e "${GREEN}✅ ECR login successful${NC}"
echo ""

# Step 2: Build Docker image
echo -e "${YELLOW}Step 2: Building Docker image${NC}"
docker build -t $ECR_REPO:$IMAGE_TAG .
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Docker image built successfully${NC}"
else
    echo -e "${RED}❌ Docker build failed${NC}"
    exit 1
fi
echo ""

# Step 3: Push to ECR
echo -e "${YELLOW}Step 3: Pushing to ECR${NC}"
docker push $ECR_REPO:$IMAGE_TAG
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Image pushed to ECR${NC}"
else
    echo -e "${RED}❌ Docker push failed${NC}"
    exit 1
fi
echo ""

# Step 4: Restart deployment
echo -e "${YELLOW}Step 4: Restarting K8s deployment${NC}"
kubectl rollout restart deployment/$DEPLOYMENT -n $NAMESPACE
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Deployment restart triggered${NC}"
else
    echo -e "${RED}❌ Deployment restart failed${NC}"
    exit 1
fi
echo ""

# Step 5: Wait for rollout
echo -e "${YELLOW}Step 5: Waiting for rollout to complete${NC}"
kubectl rollout status deployment/$DEPLOYMENT -n $NAMESPACE --timeout=5m
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Deployment rollout completed${NC}"
else
    echo -e "${RED}❌ Deployment rollout failed${NC}"
    echo ""
    echo "Check logs with:"
    echo "  kubectl logs -n $NAMESPACE -l app=$DEPLOYMENT --tail=50"
    exit 1
fi
echo ""

# Step 6: Verify deployment
echo -e "${YELLOW}Step 6: Verifying deployment${NC}"

# Check pod status
POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=$DEPLOYMENT -o jsonpath='{.items[0].metadata.name}')
POD_STATUS=$(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.phase}')

echo "Pod: $POD_NAME"
echo "Status: $POD_STATUS"

if [ "$POD_STATUS" = "Running" ]; then
    echo -e "${GREEN}✅ Pod is running${NC}"
else
    echo -e "${RED}❌ Pod is not running (status: $POD_STATUS)${NC}"
    echo ""
    echo "Check logs with:"
    echo "  kubectl logs -n $NAMESPACE $POD_NAME --tail=50"
    exit 1
fi

# Check for errors in logs
echo ""
echo "Checking recent logs for errors..."
ERRORS=$(kubectl logs -n $NAMESPACE $POD_NAME --tail=50 | grep -i "error" | wc -l)

if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}✅ No errors in recent logs${NC}"
else
    echo -e "${YELLOW}⚠️  Found $ERRORS error(s) in logs${NC}"
    echo "Recent logs:"
    kubectl logs -n $NAMESPACE $POD_NAME --tail=20
fi

echo ""
echo "========================================"
echo -e "${GREEN}✅ Redeploy completed successfully!${NC}"
echo "========================================"
echo ""
echo "Next steps:"
echo "1. Test health endpoint:"
echo "   kubectl port-forward -n $NAMESPACE svc/$DEPLOYMENT 8080:80"
echo "   curl http://localhost:8080/health"
echo ""
echo "2. Test billing API:"
echo "   curl http://localhost:8080/billing/plans | jq ."
echo ""
echo "3. Check full logs:"
echo "   kubectl logs -n $NAMESPACE -l app=$DEPLOYMENT -f"
