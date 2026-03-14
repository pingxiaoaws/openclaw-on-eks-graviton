#!/usr/bin/env bash

##################################################
# Phase 1 Validation: EKS Cluster
##################################################
#
# Validates that EKS cluster was created successfully:
# - Cluster is accessible
# - All nodes are Ready
# - System DaemonSets are running
# - EBS CSI controller is ready
# - Kata nodes labeled correctly (if applicable)
#
##################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Validation counters
CHECKS_PASSED=0
CHECKS_FAILED=0

check_pass() {
    echo -e "${GREEN}✅${NC} $1"
    ((CHECKS_PASSED++))
}

check_fail() {
    echo -e "${RED}❌${NC} $1"
    ((CHECKS_FAILED++))
}

check_warning() {
    echo -e "${YELLOW}⚠️ ${NC} $1"
}

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║           Phase 1 Validation: EKS Cluster                      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Check 1: Cluster accessible
echo "Checking cluster accessibility..."
if kubectl cluster-info &>/dev/null; then
    check_pass "Cluster is accessible"
else
    check_fail "Cannot access cluster"
    exit 1
fi

# Get cluster context info
CLUSTER_NAME=$(kubectl config current-context | cut -d/ -f2 | cut -d@ -f1)
AWS_REGION=$(kubectl config current-context | cut -d: -f4)
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $AWS_REGION"
echo ""

# Check 2: Nodes are Ready
echo "Checking node status..."
NODES_TOTAL=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
NODES_READY=$(kubectl get nodes --no-headers | grep -c " Ready " || true)

if [ "$NODES_TOTAL" -eq "$NODES_READY" ]; then
    check_pass "All $NODES_TOTAL nodes are Ready"
else
    check_fail "Only $NODES_READY/$NODES_TOTAL nodes are Ready"
fi

# List nodes
kubectl get nodes -o wide
echo ""

# Check 3: System DaemonSets
echo "Checking system DaemonSets..."

# vpc-cni
VPC_CNI_DESIRED=$(kubectl get ds -n kube-system aws-node -o jsonpath='{.status.desiredNumberScheduled}' || echo "0")
VPC_CNI_READY=$(kubectl get ds -n kube-system aws-node -o jsonpath='{.status.numberReady}' || echo "0")
if [ "$VPC_CNI_DESIRED" -eq "$VPC_CNI_READY" ] && [ "$VPC_CNI_READY" -gt 0 ]; then
    check_pass "vpc-cni: $VPC_CNI_READY/$VPC_CNI_DESIRED pods ready"
else
    check_fail "vpc-cni: $VPC_CNI_READY/$VPC_CNI_DESIRED pods ready"
fi

# kube-proxy
KUBE_PROXY_DESIRED=$(kubectl get ds -n kube-system kube-proxy -o jsonpath='{.status.desiredNumberScheduled}' || echo "0")
KUBE_PROXY_READY=$(kubectl get ds -n kube-system kube-proxy -o jsonpath='{.status.numberReady}' || echo "0")
if [ "$KUBE_PROXY_DESIRED" -eq "$KUBE_PROXY_READY" ] && [ "$KUBE_PROXY_READY" -gt 0 ]; then
    check_pass "kube-proxy: $KUBE_PROXY_READY/$KUBE_PROXY_DESIRED pods ready"
else
    check_fail "kube-proxy: $KUBE_PROXY_READY/$KUBE_PROXY_DESIRED pods ready"
fi

# coredns
COREDNS_REPLICAS=$(kubectl get deployment -n kube-system coredns -o jsonpath='{.status.replicas}' || echo "0")
COREDNS_READY=$(kubectl get deployment -n kube-system coredns -o jsonpath='{.status.readyReplicas}' || echo "0")
if [ "$COREDNS_REPLICAS" -eq "$COREDNS_READY" ] && [ "$COREDNS_READY" -gt 0 ]; then
    check_pass "coredns: $COREDNS_READY/$COREDNS_REPLICAS replicas ready"
else
    check_fail "coredns: $COREDNS_READY/$COREDNS_REPLICAS replicas ready"
fi

echo ""

# Check 4: EBS CSI Controller
echo "Checking EBS CSI Controller..."
EBS_CSI_REPLICAS=$(kubectl get deployment -n kube-system ebs-csi-controller -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
EBS_CSI_READY=$(kubectl get deployment -n kube-system ebs-csi-controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

if [ "$EBS_CSI_REPLICAS" -eq "$EBS_CSI_READY" ] && [ "$EBS_CSI_READY" -gt 0 ]; then
    check_pass "ebs-csi-controller: $EBS_CSI_READY/$EBS_CSI_REPLICAS replicas ready"
else
    check_fail "ebs-csi-controller: $EBS_CSI_READY/$EBS_CSI_REPLICAS replicas ready"
fi
echo ""

# Check 5: Kata nodes (if applicable)
echo "Checking for Kata nodes..."
KATA_NODE_COUNT=$(kubectl get nodes -l workload-type=kata --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "$KATA_NODE_COUNT" -gt 0 ]; then
    check_pass "Found $KATA_NODE_COUNT Kata node(s)"
    echo "   Kata nodes:"
    kubectl get nodes -l workload-type=kata -o wide

    # Verify taints
    KATA_NODE_NAME=$(kubectl get nodes -l workload-type=kata -o jsonpath='{.items[0].metadata.name}')
    if kubectl get node "$KATA_NODE_NAME" -o jsonpath='{.spec.taints}' | grep -q "kata-dedicated"; then
        check_pass "Kata node has correct taint (kata-dedicated)"
    else
        check_warning "Kata node missing kata-dedicated taint"
    fi
else
    check_warning "No Kata nodes found (standard cluster)"
fi
echo ""

# Summary
echo "════════════════════════════════════════════════════════════════"
echo "Validation Summary:"
echo "  ✅ Passed: $CHECKS_PASSED"
echo "  ❌ Failed: $CHECKS_FAILED"
echo "════════════════════════════════════════════════════════════════"

if [ $CHECKS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ Phase 1 validation PASSED${NC}"
    exit 0
else
    echo -e "${RED}❌ Phase 1 validation FAILED${NC}"
    exit 1
fi
