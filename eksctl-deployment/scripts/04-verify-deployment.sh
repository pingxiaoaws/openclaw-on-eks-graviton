#!/bin/bash
export AWS_PAGER=""
# Verification Script for EKS Cluster Deployment
# Checks nodes, add-ons, controllers, and Kata setup

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
TEMPLATE_DIR="$(cd "${SCRIPT_DIR}/../templates"; pwd)"

echo -e "${BLUE}=== OpenClaw Platform Deployment Verification ===${NC}"
echo ""

ERRORS=0
WARNINGS=0

# ============================================================================
# Helper Functions
# ============================================================================

check_pass() {
  echo -e "${GREEN}✅ $1${NC}"
}

check_fail() {
  echo -e "${RED}❌ $1${NC}"
  ((ERRORS++))
}

check_warn() {
  echo -e "${YELLOW}⚠️  $1${NC}"
  ((WARNINGS++))
}

# ============================================================================
# 1. Cluster Access
# ============================================================================

echo -e "${BLUE}[1] Cluster Access${NC}"

if kubectl cluster-info &>/dev/null; then
  CONTEXT=$(kubectl config current-context)
  # Extract cluster name from ARN format or eksctl format
  if [[ "$CONTEXT" == arn:aws:eks:* ]]; then
    # ARN format: arn:aws:eks:region:account:cluster/cluster-name
    CLUSTER_NAME=$(echo "$CONTEXT" | cut -d'/' -f2)
  else
    # eksctl format: user@cluster-name.region.eksctl.io
    CLUSTER_NAME=$(echo "$CONTEXT" | cut -d'@' -f2 | cut -d'.' -f1)
  fi
  check_pass "Connected to cluster: $CONTEXT"
else
  check_fail "Cannot connect to cluster"
  exit 1
fi

echo ""

# ============================================================================
# 2. Nodes
# ============================================================================

echo -e "${BLUE}[2] Nodes${NC}"

# Total nodes
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
READY_NODES=$(kubectl get nodes --no-headers | grep -c " Ready" || echo "0")

if [ "$TOTAL_NODES" -ge 2 ] && [ "$READY_NODES" -eq "$TOTAL_NODES" ]; then
  check_pass "Nodes: $READY_NODES/$TOTAL_NODES Ready"
else
  check_fail "Nodes: $READY_NODES/$TOTAL_NODES Ready (expected >= 2)"
fi

# Standard nodes
STANDARD_NODES=$(kubectl get nodes -l workload-type=standard --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$STANDARD_NODES" -ge 2 ]; then
  check_pass "Standard nodes: $STANDARD_NODES (expected >= 2)"
else
  check_warn "Standard nodes: $STANDARD_NODES (expected >= 2)"
fi

# Kata nodes (optional - skip detailed check for simplified deployment)
KATA_NODES=$(kubectl get nodes -l workload-type=kata --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$KATA_NODES" -ge 1 ]; then
  check_pass "Kata nodes: $KATA_NODES"
else
  echo "  Kata nodes: $KATA_NODES (optional - not required for standard deployment)"
fi

echo ""

# ============================================================================
# 3. EKS Add-ons
# ============================================================================

echo -e "${BLUE}[3] EKS Add-ons${NC}"

# Extract cluster name and region from context (supports ARN and eksctl formats)
CONTEXT=$(kubectl config current-context)
if [[ "$CONTEXT" == arn:aws:eks:* ]]; then
  # ARN format: arn:aws:eks:region:account:cluster/cluster-name
  AWS_REGION=$(echo "$CONTEXT" | cut -d':' -f4)
  CLUSTER_NAME=$(echo "$CONTEXT" | cut -d'/' -f2)
else
  # eksctl format: user@cluster-name.region.eksctl.io
  CLUSTER_NAME=$(echo "$CONTEXT" | cut -d'@' -f2 | cut -d'.' -f1)
  AWS_REGION=$(echo "$CONTEXT" | grep -o 'us-[a-z]*-[0-9]' || echo "us-east-1")
fi

for ADDON in vpc-cni coredns kube-proxy aws-ebs-csi-driver; do
  STATUS=$(aws eks describe-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name "$ADDON" \
    --region "$AWS_REGION" \
    --query 'addon.status' \
    --output text 2>/dev/null || echo "NOT_INSTALLED")

  if [ "$STATUS" == "ACTIVE" ]; then
    check_pass "Add-on: $ADDON ($STATUS)"
  else
    check_fail "Add-on: $ADDON ($STATUS)"
  fi
done

echo ""

# ============================================================================
# 4. Controllers and Operators
# ============================================================================

echo -e "${BLUE}[4] Controllers and Operators${NC}"

# EFS CSI Driver
if kubectl get deployment -n kube-system efs-csi-controller &>/dev/null; then
  EFS_REPLICAS=$(kubectl get deployment -n kube-system efs-csi-controller -o jsonpath='{.status.readyReplicas}')
  if [ "$EFS_REPLICAS" -ge 1 ]; then
    check_pass "EFS CSI Driver: $EFS_REPLICAS replicas ready"
  else
    check_fail "EFS CSI Driver: $EFS_REPLICAS replicas ready"
  fi
else
  check_warn "EFS CSI Driver: Not installed"
fi

# AWS Load Balancer Controller
if kubectl get deployment -n kube-system aws-load-balancer-controller &>/dev/null; then
  ALB_REPLICAS=$(kubectl get deployment -n kube-system aws-load-balancer-controller -o jsonpath='{.status.readyReplicas}')
  if [ "$ALB_REPLICAS" -ge 1 ]; then
    check_pass "ALB Controller: $ALB_REPLICAS replicas ready"
  else
    check_fail "ALB Controller: $ALB_REPLICAS replicas ready"
  fi
else
  check_warn "ALB Controller: Not installed"
fi

# OpenClaw Operator
if kubectl get deployment -n openclaw-operator-system openclaw-operator &>/dev/null; then
  OP_REPLICAS=$(kubectl get deployment -n openclaw-operator-system openclaw-operator -o jsonpath='{.status.readyReplicas}')
  if [ "$OP_REPLICAS" -ge 1 ]; then
    check_pass "OpenClaw Operator: $OP_REPLICAS replicas ready"
  else
    check_fail "OpenClaw Operator: $OP_REPLICAS replicas ready"
  fi
else
  echo "  OpenClaw Operator: Not installed (deployed in Phase 4)"
fi

echo ""

# ============================================================================
# 5. Storage
# ============================================================================

echo -e "${BLUE}[5] Storage${NC}"

# EFS StorageClass
if kubectl get storageclass efs-sc &>/dev/null; then
  EFS_ID=$(kubectl get storageclass efs-sc -o jsonpath='{.parameters.fileSystemId}')
  check_pass "EFS StorageClass: efs-sc (FileSystem: $EFS_ID)"

  # Verify EFS is available
  EFS_STATE=$(aws efs describe-file-systems \
    --file-system-id "$EFS_ID" \
    --region "$AWS_REGION" \
    --query 'FileSystems[0].LifeCycleState' \
    --output text 2>/dev/null || echo "UNKNOWN")

  if [ "$EFS_STATE" == "available" ]; then
    check_pass "EFS FileSystem: $EFS_STATE"
  else
    check_warn "EFS FileSystem: $EFS_STATE"
  fi
else
  check_warn "EFS StorageClass: Not created"
fi

echo ""

# ============================================================================
# 6. Kata Containers
# ============================================================================

echo -e "${BLUE}[6] Kata Containers${NC}"

# RuntimeClasses
for RC in kata-fc kata-qemu; do
  if kubectl get runtimeclass "$RC" &>/dev/null; then
    check_pass "RuntimeClass: $RC"
  else
    echo "  RuntimeClass: $RC not found (optional for standard deployment)"
  fi
done

# Verify Kata on node (if node is ready) - Skip for standard deployment
if [ "$KATA_NODES" -ge 1 ]; then
  KATA_NODE=$(kubectl get nodes -l workload-type=kata -o jsonpath='{.items[0].metadata.name}')
  echo "  Checking Kata installation on node $KATA_NODE..."
  # Skip detailed check for now
  echo "  (Kata runtime check skipped - manual verification recommended)"
fi

echo ""

# ============================================================================
# 7. Test Kata Pod (Optional)
# ============================================================================

echo -e "${BLUE}[7] Kata Pod Test${NC}"

if [ "$KATA_NODES" -ge 1 ]; then
  echo "  Creating test Kata pod..."

  kubectl apply -f "${TEMPLATE_DIR}/k8s-manifests/kata-test-pod.yaml" &>/dev/null

  # Wait for pod
  sleep 10

  POD_STATUS=$(kubectl get pod kata-test-verify -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

  if [ "$POD_STATUS" == "Running" ]; then
    # Get kernel version from running pod
    KERNEL=$(kubectl exec kata-test-verify -- uname -r 2>/dev/null || echo "unknown")

    if echo "$KERNEL" | grep -q "^6\.18"; then
      check_pass "Kata test pod running with VM kernel: $KERNEL"
    else
      check_warn "Kata test pod running but kernel version unexpected: $KERNEL"
    fi

    # Cleanup
    kubectl delete pod kata-test-verify --wait=false &>/dev/null
  elif [ "$POD_STATUS" == "Succeeded" ]; then
    # Pod completed successfully, get kernel version from logs
    KERNEL=$(kubectl logs kata-test-verify 2>/dev/null | head -1 || echo "unknown")

    if echo "$KERNEL" | grep -q "^6\.18"; then
      check_pass "Kata test pod completed successfully with VM kernel: $KERNEL"
    else
      check_warn "Kata test pod completed but kernel version unexpected: $KERNEL"
    fi

    # Cleanup
    kubectl delete pod kata-test-verify --wait=false &>/dev/null
  elif [ "$POD_STATUS" == "Pending" ]; then
    check_warn "Kata test pod still pending (node may be initializing)"
    kubectl delete pod kata-test-verify --wait=false &>/dev/null
  else
    check_warn "Kata test pod failed to start ($POD_STATUS)"
    kubectl delete pod kata-test-verify --wait=false &>/dev/null
  fi
else
  echo "  Skipping (no Kata nodes ready)"
fi

echo ""

# ============================================================================
# Summary
# ============================================================================

echo -e "${BLUE}=== Verification Summary ===${NC}"
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
  echo -e "${GREEN}✅ All checks passed!${NC}"
  echo ""
  echo "Your OpenClaw platform is ready."
  echo ""
  echo "Next Steps:"
  echo "  1. Run: ./04-deploy-provisioning-service.sh (Deploy Operator + Provisioning Service)"
  echo "  2. Create test OpenClaw instance: kubectl apply -f openclaw-kata-bedrock.yaml"
  echo "  3. Setup Cognito and CloudFront (Phase 3)"
elif [ $ERRORS -eq 0 ]; then
  echo -e "${YELLOW}⚠️  Verification completed with $WARNINGS warnings${NC}"
  echo ""
  echo "Some components may still be initializing. Wait a few minutes and re-run this script."
else
  echo -e "${RED}❌ Verification failed with $ERRORS errors and $WARNINGS warnings${NC}"
  echo ""
  echo "Review the errors above and fix them before proceeding."
  exit 1
fi
