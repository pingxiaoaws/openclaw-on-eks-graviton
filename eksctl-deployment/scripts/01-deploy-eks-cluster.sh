#!/bin/bash
export AWS_PAGER=""
# Phase 1: Deploy EKS Cluster using eksctl
# Creates VPC, EKS cluster, node groups, and managed add-ons
# Supports both standard and Kata Containers configurations

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Phase 1: EKS Cluster Deployment ===${NC}"
echo ""

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../configs"
AWS_REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}

# ============================================================================
# Step 1: Select Configuration
# ============================================================================

echo -e "${CYAN}Select cluster configuration:${NC}"
echo ""
echo "  1) Standard cluster (without Kata Containers)"
echo "     - Only standard nodes (m6g.xlarge/2xlarge, Graviton ARM64)"
echo "     - Amazon Linux 2023"
echo "     - Suitable for: Standard containerized workloads"
echo "     - Cost: Lower (standard instance types)"
echo ""
echo "  2) Cluster with Kata Containers support"
echo "     - Standard nodes + Kata nodes (m5.metal, Ubuntu 24.04)"
echo "     - VM-level isolation for multi-tenant workloads"
echo "     - Suitable for: Multi-tenant AI agents, security-sensitive workloads"
echo "     - Cost: Higher (bare metal instances required)"
echo ""

read -p "Enter your choice (1 or 2): " CHOICE

case $CHOICE in
  1)
    CONFIG_FILE="${CONFIG_DIR}/openclaw-cluster.yaml"
    DEPLOYMENT_TYPE="standard"
    echo -e "${GREEN}✓ Selected: Standard cluster (without Kata)${NC}"
    ;;
  2)
    CONFIG_FILE="${CONFIG_DIR}/openclaw-cluster-kata.yaml"
    DEPLOYMENT_TYPE="kata"
    echo -e "${GREEN}✓ Selected: Cluster with Kata Containers${NC}"
    ;;
  *)
    echo -e "${RED}❌ Invalid choice. Exiting.${NC}"
    exit 1
    ;;
esac

echo ""

# ============================================================================
# Step 2: Validate Prerequisites
# ============================================================================

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
AWS_ACCOUNT=${AWS_ACCOUNT_ID:-${AWS_ACCOUNT:-$(aws sts get-caller-identity --query Account --output text)}}
echo -e "${GREEN}✅ AWS CLI: Account $AWS_ACCOUNT${NC}"

# Check config file
if [ ! -f "$CONFIG_FILE" ]; then
  echo -e "${RED}❌ Config file not found: $CONFIG_FILE${NC}"
  exit 1
fi
echo -e "${GREEN}✅ Config file: $(basename $CONFIG_FILE)${NC}"

# Additional check for Kata deployment
if [ "$DEPLOYMENT_TYPE" == "kata" ]; then
  echo ""
  echo -e "${YELLOW}⚠️  Kata Containers deployment requires:${NC}"
  echo "   - Bare metal instances (c6g.metal) - higher cost"
  echo "   - ~30-35 minutes deployment time (vs ~20 minutes for standard)"
fi

echo ""

# ============================================================================
# Step 3: Display Cluster Configuration
# ============================================================================

echo -e "${YELLOW}Cluster Configuration:${NC}"
CLUSTER_NAME=$(grep 'name:' "$CONFIG_FILE" | head -1 | awk '{print $2}')
CLUSTER_REGION=$(grep 'region:' "$CONFIG_FILE" | head -1 | awk '{print $2}')
CLUSTER_VERSION=$(grep 'version:' "$CONFIG_FILE" | head -1 | awk '{print $2}')

echo "  Cluster Name: $CLUSTER_NAME"
echo "  Region: $CLUSTER_REGION"
echo "  Kubernetes Version: $CLUSTER_VERSION"
echo ""
echo "  Node Groups:"
grep -E '^\s+- name:' "$CONFIG_FILE" | grep -v 'vpc-cni\|coredns\|kube-proxy\|aws-ebs' | sed 's/- name:/  -/' | sed 's/^/    /'
echo ""

if [ "$DEPLOYMENT_TYPE" == "kata" ]; then
  echo -e "${CYAN}  Kata Features:${NC}"
  echo "    - VM-level isolation with Firecracker"
  echo "    - Devmapper snapshotter (350GB thin pool)"
  echo "    - Automated Kata runtime installation"
  echo "    - Ubuntu 24.04 EKS-optimized AMI"
  echo ""
fi

# ============================================================================
# Step 4: Confirm Deployment
# ============================================================================

ESTIMATED_TIME="20-25"
if [ "$DEPLOYMENT_TYPE" == "kata" ]; then
  ESTIMATED_TIME="30-35"
fi

echo -e "${YELLOW}Estimated deployment time: $ESTIMATED_TIME minutes${NC}"
echo ""
read -p "Proceed with cluster deployment? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo -e "${YELLOW}Deployment cancelled${NC}"
  exit 0
fi

# ============================================================================
# Step 5: Deploy Cluster
# ============================================================================

echo ""
echo -e "${BLUE}Starting eksctl cluster creation...${NC}"
echo "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

START_TIME=$(date +%s)

# Create log file with timestamp
LOG_FILE="/tmp/eksctl-create-$(date +%Y%m%d-%H%M%S).log"

eksctl create cluster -f "$CONFIG_FILE" 2>&1 | tee "$LOG_FILE"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo ""
echo -e "${GREEN}✅ Cluster creation completed in ${MINUTES}m ${SECONDS}s${NC}"
echo ""

# ============================================================================
# Step 6: Verify Cluster Access
# ============================================================================

echo "Verifying cluster access..."
echo ""

# Update kubeconfig
eksctl utils write-kubeconfig --cluster="$CLUSTER_NAME" --region="$CLUSTER_REGION"

# Display cluster info
kubectl cluster-info

echo ""
echo "Nodes:"
kubectl get nodes -o wide

echo ""

# Kata-specific verification
if [ "$DEPLOYMENT_TYPE" == "kata" ]; then
  echo -e "${CYAN}Verifying Kata nodes...${NC}"
  
  KATA_NODE_COUNT=$(kubectl get nodes -l workload-type=kata --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$KATA_NODE_COUNT" -ge 1 ]; then
    echo -e "${GREEN}✅ Kata nodes: $KATA_NODE_COUNT node(s) ready${NC}"
    
    # Get Kata node name
    KATA_NODE=$(kubectl get nodes -l workload-type=kata -o jsonpath='{.items[0].metadata.name}')
    echo "   Node: $KATA_NODE"
    
    # Check labels
    echo ""
    echo "   Labels:"
    kubectl get node "$KATA_NODE" --show-labels | grep -o 'workload-type=kata\|kata-runtime=configured\|os=ubuntu' | sed 's/^/     - /'
  else
    echo -e "${YELLOW}⚠️  Kata nodes not ready yet (may still be initializing)${NC}"
    echo "   Check status with: kubectl get nodes -l workload-type=kata -w"
  fi
  echo ""
fi

# ============================================================================
# Step 7: Summary
# ============================================================================

echo -e "${GREEN}=== Phase 1 Complete ===${NC}"
echo ""
echo "Cluster Details:"
echo "  Name: $CLUSTER_NAME"
echo "  Region: $CLUSTER_REGION"
echo "  Context: $(kubectl config current-context)"
echo "  Configuration: $DEPLOYMENT_TYPE"
echo ""

if [ "$DEPLOYMENT_TYPE" == "kata" ]; then
  echo -e "${CYAN}Kata Containers Information:${NC}"
  echo "  - Kata nodes will automatically install Kata runtime on first boot (~5 min)"
  echo "  - Check installation progress: kubectl get nodes -l workload-type=kata -w"
  echo "  - View setup logs on node: /var/log/kata-setup.log"
  echo "  - RuntimeClass 'kata-fc' will be created in Phase 2"
  echo ""
fi

echo "Logs saved to: $LOG_FILE"
echo ""
echo "Next Steps:"
echo "  1. Run: ./02-deploy-controllers.sh  (Phase 2 - Install EFS CSI, ALB Controller, etc.)"
echo "  2. Run: ./03-verify-deployment.sh   (Verification)"

if [ "$DEPLOYMENT_TYPE" == "kata" ]; then
  echo ""
  echo -e "${YELLOW}Note: Wait for Kata nodes to complete setup before proceeding to Phase 2${NC}"
  echo "      Check with: kubectl get nodes -l workload-type=kata"
fi

echo ""
