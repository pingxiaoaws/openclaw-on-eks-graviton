#!/bin/bash

# Deploy script for shared IAM role provisioning service
# Builds and deploys the updated provisioning service with shared role support

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

AWS_REGION="${AWS_REGION:-us-west-2}"
ECR_REPO="970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning"
BUILD_SERVER="ec2-user@44.252.48.166"
REMOTE_REPO_PATH="~/openclaw-on-eks-graviton"

echo "=================================="
echo "Deploy Shared Role Provisioning Service"
echo "=================================="
echo "ECR Repo: $ECR_REPO:latest"
echo "Build Server: $BUILD_SERVER"
echo ""

# Step 1: Commit changes
echo "Step 1: Committing code changes..."
cd eks-pod-service
git add -A
git status

read -p "Commit message [feat: use shared IAM role for Pod Identity]: " COMMIT_MSG
COMMIT_MSG=${COMMIT_MSG:-"feat: use shared IAM role for Pod Identity with dynamic associations"}

git commit -m "$COMMIT_MSG

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>" || echo "No changes to commit"

# Step 2: Push to remote
echo ""
echo "Step 2: Pushing to remote..."
git push origin main

# Step 3: Build on remote server
echo ""
echo "Step 3: Building Docker image on remote server..."
ssh -i ~/.ssh/pingec2.key -o StrictHostKeyChecking=no "$BUILD_SERVER" << 'EOF'
cd ~/openclaw-on-eks-graviton
git pull origin main
cd eks-pod-service

echo "Logging into ECR..."
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin \
  970547376847.dkr.ecr.us-west-2.amazonaws.com

echo "Building Docker image..."
docker build -t 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest .

echo "Pushing Docker image..."
docker push 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest

echo "Build complete!"
EOF

# Step 4: Apply deployment
echo ""
echo "Step 4: Applying deployment configuration..."
kubectl apply -f kubernetes/deployment.yaml

# Step 5: Rollout restart
echo ""
echo "Step 5: Rolling out new deployment..."
kubectl rollout restart deployment openclaw-provisioning -n openclaw-provisioning
kubectl rollout status deployment openclaw-provisioning -n openclaw-provisioning

# Step 6: Verify pods
echo ""
echo "Step 6: Verifying pods..."
kubectl get pods -n openclaw-provisioning

# Step 7: Check environment variables
echo ""
echo "Step 7: Checking environment variables in pod..."
POD_NAME=$(kubectl get pods -n openclaw-provisioning -l app=openclaw-provisioning -o jsonpath='{.items[0].metadata.name}')
echo "Pod: $POD_NAME"
echo ""
echo "Pod Identity Configuration:"
kubectl exec -n openclaw-provisioning "$POD_NAME" -- env | grep -E "(USE_POD_IDENTITY|CREATE_IAM_ROLE|SHARED_BEDROCK_ROLE|EKS_CLUSTER|AWS_REGION)"

# Step 8: Show logs
echo ""
echo "Step 8: Showing recent logs..."
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=20

echo ""
echo "=================================="
echo "Deployment Complete!"
echo "=================================="
echo ""
echo "Verify with:"
echo "  kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning -f"
echo ""
echo "Test by creating a new instance via Dashboard:"
echo "  https://d3ik6njnl847zd.cloudfront.net/dashboard"
echo ""
