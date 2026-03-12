#!/bin/bash
# Phase 1: Deploy EKS Cluster using eksctl
# Creates VPC, EKS cluster, node groups, and managed add-ons

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Phase 1: EKS Cluster Deployment ===${NC}"
echo ""

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../configs/openclaw-cluster.yaml"
AWS_REGION=${AWS_REGION:-"us-east-1"}

# Validate prerequisites
echo "Checking prerequisites..."

# Check eksctl
if ! command -v eksctl &> /dev/null; then
  echo -e "${RED}❌ eksctl not found. Install from: https://eksctl.io/${NC}"
  exit 1
fi
echo -e "${GREEN}✅ eksctl: $(eksctl version)${NC}"

# Check kubectl
if ! command -v kubectl &> /dev/null; then
  echo -e "${RED}❌ kubectl not found${NC}"
  exit 1
fi
echo -e "${GREEN}✅ kubectl: $(kubectl version --client --short 2>/dev/null | head -1)${NC}"

# Check AWS CLI
if ! command -v aws &> /dev/null; then
  echo -e "${RED}❌ aws CLI not found${NC}"
  exit 1
fi
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo -e "${GREEN}✅ AWS CLI: Account $AWS_ACCOUNT${NC}"

# Check config file
if [ ! -f "$CONFIG_FILE" ]; then
  echo -e "${RED}❌ Config file not found: $CONFIG_FILE${NC}"
  exit 1
fi
echo -e "${GREEN}✅ Config file: $CONFIG_FILE${NC}"

echo ""
echo -e "${YELLOW}Cluster Configuration:${NC}"
grep -E "name:|region:|version:" "$CONFIG_FILE" | head -3
echo ""

# Confirm deployment
read -p "Proceed with cluster deployment? This will take ~20-25 minutes (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo -e "${YELLOW}Deployment cancelled${NC}"
  exit 0
fi

# Deploy cluster
echo ""
echo -e "${BLUE}Starting eksctl cluster creation...${NC}"
echo "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

START_TIME=$(date +%s)

eksctl create cluster -f "$CONFIG_FILE" 2>&1 | tee /tmp/eksctl-create.log

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo ""
echo -e "${GREEN}✅ Cluster creation completed in ${MINUTES}m ${SECONDS}s${NC}"
echo ""

# Verify cluster access
echo "Verifying cluster access..."
CLUSTER_NAME=$(grep 'name:' "$CONFIG_FILE" | head -1 | awk '{print $2}')
CLUSTER_REGION=$(grep 'region:' "$CONFIG_FILE" | head -1 | awk '{print $2}')

kubectl cluster-info
kubectl get nodes -o wide

echo ""
echo -e "${GREEN}=== Phase 1 Complete ===${NC}"
echo ""
echo "Cluster Details:"
echo "  Name: $CLUSTER_NAME"
echo "  Region: $CLUSTER_REGION"
echo "  Context: $(kubectl config current-context)"
echo ""
echo "Next Steps:"
echo "  1. Run: ./03-deploy-controllers.sh  (Phase 2 - Install EFS CSI, ALB Controller, etc.)"
echo "  2. Run: ./04-verify-deployment.sh   (Verification)"
echo ""
