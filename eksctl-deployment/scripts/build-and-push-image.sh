#!/bin/bash
# Build and Push Docker Image for Provisioning Service
# Supports both local and remote build

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Docker Image Build and Push ===${NC}"
echo ""

# ============================================================================
# Configuration
# ============================================================================

# Get AWS info
AWS_REGION=${AWS_REGION:-$(kubectl config current-context | grep -o 'us-[a-z]*-[0-9]' || echo "us-east-1")}
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# Docker image configuration
ECR_REPO="openclaw-provisioning"
IMAGE_TAG="latest"
FULL_IMAGE="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:${IMAGE_TAG}"

# Source code directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/../../open-claw-operator-on-EKS-kata/eks-pod-service"

# Remote build configuration (optional)
REMOTE_HOST="${REMOTE_BUILD_HOST:-}"
REMOTE_USER="${REMOTE_BUILD_USER:-ec2-user}"
REMOTE_KEY="${REMOTE_BUILD_KEY:-}"
REMOTE_REPO_DIR="${REMOTE_BUILD_REPO:-~/openclaw-on-eks-graviton}"

# ============================================================================
# Step 1: Select Build Mode
# ============================================================================

echo -e "${CYAN}Select build mode:${NC}"
echo ""
echo "  1) Local build (requires Docker on this machine)"
echo "     - Build locally and push to ECR"
echo "     - Suitable for: ARM64 Mac, Linux with Docker"
echo ""
echo "  2) Remote build (requires SSH access to remote host)"
echo "     - Build on remote EC2 instance"
echo "     - Suitable for: Building ARM64 images from x86 machines"
echo "     - Requires: SSH key and remote host IP"
echo ""

read -p "Enter your choice (1 or 2): " BUILD_MODE

# ============================================================================
# Step 2: Validate Prerequisites
# ============================================================================

echo ""
echo "Validating prerequisites..."

# Check AWS CLI
if ! command -v aws &> /dev/null; then
  echo -e "${RED}❌ aws CLI not found${NC}"
  exit 1
fi
echo -e "${GREEN}✅ AWS CLI${NC}"

# Check Docker (for local build)
if [ "$BUILD_MODE" == "1" ]; then
  if ! command -v docker &> /dev/null; then
    echo -e "${RED}❌ Docker not found (required for local build)${NC}"
    exit 1
  fi
  echo -e "${GREEN}✅ Docker: $(docker --version | head -1)${NC}"
  
  # Check if Docker daemon is running
  if ! docker info &> /dev/null; then
    echo -e "${RED}❌ Docker daemon is not running${NC}"
    exit 1
  fi
  echo -e "${GREEN}✅ Docker daemon is running${NC}"
fi

# Check source directory
if [ ! -d "$SOURCE_DIR" ]; then
  echo -e "${RED}❌ Source directory not found: $SOURCE_DIR${NC}"
  exit 1
fi
echo -e "${GREEN}✅ Source directory: $SOURCE_DIR${NC}"

# For remote build, validate SSH configuration
if [ "$BUILD_MODE" == "2" ]; then
  echo ""
  echo -e "${CYAN}Remote build configuration:${NC}"
  
  # Get remote host
  if [ -z "$REMOTE_HOST" ]; then
    read -p "Enter remote host IP: " REMOTE_HOST
  fi
  echo "  Host: $REMOTE_HOST"
  
  # Get SSH key
  if [ -z "$REMOTE_KEY" ]; then
    read -p "Enter SSH key path [~/.ssh/id_rsa]: " REMOTE_KEY
    REMOTE_KEY=${REMOTE_KEY:-~/.ssh/id_rsa}
  fi
  
  # Expand ~ to full path
  REMOTE_KEY="${REMOTE_KEY/#\~/$HOME}"
  
  if [ ! -f "$REMOTE_KEY" ]; then
    echo -e "${RED}❌ SSH key not found: $REMOTE_KEY${NC}"
    exit 1
  fi
  echo "  SSH Key: $REMOTE_KEY"
  
  # Test SSH connection
  echo ""
  echo "Testing SSH connection..."
  if ssh -i "$REMOTE_KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "echo 'Connection successful'" &>/dev/null; then
    echo -e "${GREEN}✅ SSH connection successful${NC}"
  else
    echo -e "${RED}❌ Cannot connect to remote host${NC}"
    exit 1
  fi
fi

echo ""

# ============================================================================
# Step 3: Create ECR Repository (if not exists)
# ============================================================================

echo "Ensuring ECR repository exists..."
if aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$AWS_REGION" &>/dev/null; then
  echo -e "${YELLOW}⚠️  ECR repository already exists: $ECR_REPO${NC}"
else
  aws ecr create-repository \
    --repository-name "$ECR_REPO" \
    --region "$AWS_REGION" \
    --image-scanning-configuration scanOnPush=true
  echo -e "${GREEN}✅ ECR repository created: $ECR_REPO${NC}"
fi

echo ""

# ============================================================================
# Step 4: Build and Push Image
# ============================================================================

if [ "$BUILD_MODE" == "1" ]; then
  # ===== LOCAL BUILD =====
  echo -e "${BLUE}Building Docker image locally...${NC}"
  echo ""
  
  # Login to ECR
  echo "Logging in to ECR..."
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  
  # Build image
  echo ""
  echo "Building image: $FULL_IMAGE"
  cd "$SOURCE_DIR"
  docker build -t "$FULL_IMAGE" .
  
  # Push image
  echo ""
  echo "Pushing image to ECR..."
  docker push "$FULL_IMAGE"
  
  echo ""
  echo -e "${GREEN}✅ Image built and pushed successfully (local)${NC}"
  
elif [ "$BUILD_MODE" == "2" ]; then
  # ===== REMOTE BUILD =====
  echo -e "${BLUE}Building Docker image on remote host...${NC}"
  echo ""
  
  # Check if source is in git repo
  cd "$SOURCE_DIR"
  if [ -d ".git" ]; then
    echo "Pushing local changes to GitHub..."
    git add -A
    git commit -m "build: update provisioning service for deployment" || echo "No changes to commit"
    git push origin main || echo "Push failed or no changes"
  else
    echo -e "${YELLOW}⚠️  Source directory is not a git repo, using existing code on remote${NC}"
  fi
  
  echo ""
  echo "Executing remote build on $REMOTE_HOST..."
  
  ssh -i "$REMOTE_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" << REMOTE_EOF
set -e

echo "=== Remote Build Started ==="
echo ""

# Navigate to repo
cd ${REMOTE_REPO_DIR}
echo "Working directory: \$(pwd)"

# Pull latest code (if git repo)
if [ -d ".git" ]; then
  echo "Pulling latest code..."
  git pull origin main || echo "Pull failed, using existing code"
else
  echo "Not a git repo, using existing code"
fi

# Navigate to eks-pod-service
cd eks-pod-service || cd open-claw-operator-on-EKS-kata/eks-pod-service
echo "Service directory: \$(pwd)"

# Login to ECR
echo ""
echo "Logging in to ECR..."
aws ecr get-login-password --region ${AWS_REGION} | \\
  docker login --username AWS --password-stdin ${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Build Docker image
echo ""
echo "Building Docker image..."
docker build -t ${FULL_IMAGE} .

# Push to ECR
echo ""
echo "Pushing image to ECR..."
docker push ${FULL_IMAGE}

echo ""
echo "=== Remote Build Complete ==="
REMOTE_EOF

  if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✅ Image built and pushed successfully (remote)${NC}"
  else
    echo ""
    echo -e "${RED}❌ Remote build failed${NC}"
    exit 1
  fi
  
else
  echo -e "${RED}❌ Invalid build mode${NC}"
  exit 1
fi

# ============================================================================
# Step 5: Verify Image
# ============================================================================

echo ""
echo "Verifying image in ECR..."
IMAGE_DIGEST=$(aws ecr describe-images \
  --repository-name "$ECR_REPO" \
  --region "$AWS_REGION" \
  --query 'imageDetails[?imageTags[?contains(@, `latest`)]].imageDigest' \
  --output text)

if [ -n "$IMAGE_DIGEST" ]; then
  echo -e "${GREEN}✅ Image verified in ECR${NC}"
  echo "   Digest: $IMAGE_DIGEST"
else
  echo -e "${YELLOW}⚠️  Could not verify image${NC}"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo -e "${GREEN}=== Build Complete ===${NC}"
echo ""
echo "Image Details:"
echo "  Repository: $ECR_REPO"
echo "  Tag: $IMAGE_TAG"
echo "  Full URI: $FULL_IMAGE"
echo "  Region: $AWS_REGION"
echo "  Build Mode: $([ "$BUILD_MODE" == "1" ] && echo "Local" || echo "Remote ($REMOTE_HOST)")"
echo ""
echo "Next Steps:"
echo "  1. Deploy or update the service with this image"
echo "  2. Run: kubectl set image deployment/openclaw-provisioning \\"
echo "       provisioning=$FULL_IMAGE -n openclaw-provisioning"
echo ""
