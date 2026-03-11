#!/bin/bash
# Deploy OpenClaw Provisioning Service with Frontend
set -e

REGION="us-west-2"
ACCOUNT_ID="111122223333"
REPO_NAME="openclaw-provisioning"
IMAGE_TAG="latest"
NAMESPACE="openclaw-provisioning"

echo "=========================================="
echo "🚀 Building and Deploying Frontend"
echo "=========================================="
echo ""

# 1. Build Docker image for ARM64 (Graviton)
echo "📦 Step 1: Building Docker image for ARM64..."
cd "$(dirname "$0")"

docker buildx build \
  --platform linux/arm64 \
  -t ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:${IMAGE_TAG} \
  --load \
  .

echo "✅ Image built successfully"
echo ""

# 2. Login to ECR
echo "🔐 Step 2: Logging in to ECR..."
aws ecr get-login-password --region ${REGION} | \
  docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com

echo "✅ ECR login successful"
echo ""

# 3. Push image to ECR
echo "📤 Step 3: Pushing image to ECR..."
docker push ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:${IMAGE_TAG}

# Get image digest
IMAGE_DIGEST=$(docker inspect ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:${IMAGE_TAG} \
  --format='{{index .RepoDigests 0}}' | cut -d'@' -f2)

echo "✅ Image pushed successfully"
echo "   Digest: ${IMAGE_DIGEST}"
echo ""

# 4. Restart deployment
echo "🔄 Step 4: Restarting deployment..."
kubectl rollout restart deployment openclaw-provisioning -n ${NAMESPACE}

echo "⏳ Waiting for deployment to be ready..."
kubectl rollout status deployment openclaw-provisioning -n ${NAMESPACE} --timeout=300s

echo ""
echo "=========================================="
echo "✅ Deployment Complete!"
echo "=========================================="
echo ""

# Get service endpoint
ALB_DNS=$(kubectl get ingress openclaw-provisioning-ingress -n ${NAMESPACE} \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [ -n "$ALB_DNS" ]; then
    echo "🌐 Frontend URL (via ALB):"
    echo "   http://${ALB_DNS}"
    echo ""
fi

echo "📋 API Endpoints:"
echo "   GET  /              - Frontend Dashboard"
echo "   GET  /health        - Health Check"
echo "   POST /provision     - Create Instance"
echo "   GET  /status/{id}   - Instance Status"
echo "   DELETE /delete/{id} - Delete Instance"
echo ""

echo "📝 To access frontend via port-forward:"
echo "   kubectl port-forward -n ${NAMESPACE} svc/openclaw-provisioning 8080:80"
echo "   Then open: http://localhost:8080"
echo ""

echo "🔍 View logs:"
echo "   kubectl logs -n ${NAMESPACE} -l app=openclaw-provisioning -f"
echo ""
