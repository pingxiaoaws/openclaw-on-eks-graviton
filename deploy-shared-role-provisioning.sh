#!/bin/bash

# Deploy script for shared IAM role provisioning service
# Builds and deploys the updated provisioning service with shared role support

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load environment variables from .env
if [ -f .env ]; then
  set -a; source .env; set +a
else
  echo "⚠️  .env file not found! Copy .env.example to .env and fill in values."
  exit 1
fi

AWS_REGION="${AWS_REGION:-us-west-2}"
ECR_REPO="${ECR_REPO:-${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/openclaw-provisioning}"
BUILD_SERVER="${BUILD_SERVER:-ec2-user@${BUILD_SERVER_IP}}"
REMOTE_REPO_PATH="${REMOTE_REPO_PATH:-~/openclaw-on-eks-graviton}"

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
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "$BUILD_SERVER" << EOF
cd ${REMOTE_REPO_PATH}
git pull origin main
cd eks-pod-service

echo "Logging into ECR..."
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin \
  ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

echo "Building Docker image..."
docker build -t ${ECR_REPO}:latest .

echo "Pushing Docker image..."
docker push ${ECR_REPO}:latest

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
echo "  https://dxxxexample.cloudfront.net/dashboard"
echo ""
