#!/usr/bin/env bash

##################################################
# Phase 2 Validation: Infrastructure Controllers
##################################################
#
# Validates that infrastructure controllers were deployed:
# - EFS CSI Driver
# - EFS FileSystem exists and is available
# - StorageClass efs-sc exists
# - ALB Controller
# - Pod Identity agent
# - Kata installation (if Kata nodes exist)
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
echo "║      Phase 2 Validation: Infrastructure Controllers            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Get cluster info
AWS_REGION=$(kubectl config current-context | cut -d: -f4)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Check 1: EFS CSI Driver
echo "Checking EFS CSI Driver..."

# EFS CSI Node DaemonSet
EFS_NODE_DESIRED=$(kubectl get ds -n kube-system efs-csi-node -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
EFS_NODE_READY=$(kubectl get ds -n kube-system efs-csi-node -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
if [ "$EFS_NODE_DESIRED" -eq "$EFS_NODE_READY" ] && [ "$EFS_NODE_READY" -gt 0 ]; then
    check_pass "EFS CSI Node: $EFS_NODE_READY/$EFS_NODE_DESIRED pods ready"
else
    check_fail "EFS CSI Node: $EFS_NODE_READY/$EFS_NODE_DESIRED pods ready"
fi

# EFS CSI Controller Deployment
EFS_CONTROLLER_REPLICAS=$(kubectl get deployment -n kube-system efs-csi-controller -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
EFS_CONTROLLER_READY=$(kubectl get deployment -n kube-system efs-csi-controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "$EFS_CONTROLLER_REPLICAS" -eq "$EFS_CONTROLLER_READY" ] && [ "$EFS_CONTROLLER_READY" -gt 0 ]; then
    check_pass "EFS CSI Controller: $EFS_CONTROLLER_READY/$EFS_CONTROLLER_REPLICAS replicas ready"
else
    check_fail "EFS CSI Controller: $EFS_CONTROLLER_READY/$EFS_CONTROLLER_REPLICAS replicas ready"
fi
echo ""

# Check 2: EFS FileSystem
echo "Checking EFS FileSystem..."
EFS_FS_ID=$(aws efs describe-file-systems --region "$AWS_REGION" \
    --query "FileSystems[?Tags[?Key=='Name' && Value=='openclaw-shared-storage']].FileSystemId" \
    --output text 2>/dev/null)

if [ -n "$EFS_FS_ID" ]; then
    EFS_STATE=$(aws efs describe-file-systems --file-system-id "$EFS_FS_ID" --region "$AWS_REGION" \
        --query 'FileSystems[0].LifeCycleState' --output text)
    if [ "$EFS_STATE" = "available" ]; then
        check_pass "EFS FileSystem: $EFS_FS_ID (available)"

        # Check mount targets
        MT_COUNT=$(aws efs describe-mount-targets --file-system-id "$EFS_FS_ID" --region "$AWS_REGION" \
            --query 'MountTargets[?LifeCycleState==`available`]' --output json | jq '. | length')
        check_pass "EFS Mount Targets: $MT_COUNT available"
    else
        check_fail "EFS FileSystem: $EFS_FS_ID ($EFS_STATE)"
    fi
else
    check_fail "EFS FileSystem not found"
fi
echo ""

# Check 3: StorageClass
echo "Checking StorageClass..."
if kubectl get sc efs-sc &>/dev/null; then
    PROVISIONER=$(kubectl get sc efs-sc -o jsonpath='{.provisioner}')
    if [ "$PROVISIONER" = "efs.csi.aws.com" ]; then
        check_pass "StorageClass efs-sc exists (provisioner: $PROVISIONER)"
    else
        check_fail "StorageClass efs-sc has wrong provisioner: $PROVISIONER"
    fi
else
    check_fail "StorageClass efs-sc not found"
fi
echo ""

# Check 4: ALB Controller
echo "Checking ALB Controller..."
ALB_REPLICAS=$(kubectl get deployment -n kube-system aws-load-balancer-controller -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
ALB_READY=$(kubectl get deployment -n kube-system aws-load-balancer-controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "$ALB_REPLICAS" -eq "$ALB_READY" ] && [ "$ALB_READY" -gt 0 ]; then
    check_pass "ALB Controller: $ALB_READY/$ALB_REPLICAS replicas ready"
else
    check_fail "ALB Controller: $ALB_READY/$ALB_REPLICAS replicas ready"
fi
echo ""

# Check 5: Pod Identity Agent
echo "Checking Pod Identity Agent..."
POD_IDENTITY_DESIRED=$(kubectl get ds -n kube-system eks-pod-identity-agent -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
POD_IDENTITY_READY=$(kubectl get ds -n kube-system eks-pod-identity-agent -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
if [ "$POD_IDENTITY_DESIRED" -eq "$POD_IDENTITY_READY" ] && [ "$POD_IDENTITY_READY" -gt 0 ]; then
    check_pass "Pod Identity Agent: $POD_IDENTITY_READY/$POD_IDENTITY_DESIRED pods ready"
else
    check_fail "Pod Identity Agent: $POD_IDENTITY_READY/$POD_IDENTITY_DESIRED pods ready"
fi
echo ""

# Check 6: Kata Installation (if applicable)
echo "Checking Kata installation..."
KATA_NODE_COUNT=$(kubectl get nodes -l workload-type=kata --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "$KATA_NODE_COUNT" -gt 0 ]; then
    # Check Kata DaemonSet
    KATA_DS_DESIRED=$(kubectl get ds -n kube-system kata-deploy -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    KATA_DS_READY=$(kubectl get ds -n kube-system kata-deploy -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    if [ "$KATA_DS_DESIRED" -eq "$KATA_DS_READY" ] && [ "$KATA_DS_READY" -gt 0 ]; then
        check_pass "Kata DaemonSet: $KATA_DS_READY/$KATA_DS_DESIRED pods ready"
    else
        check_fail "Kata DaemonSet: $KATA_DS_READY/$KATA_DS_DESIRED pods ready"
    fi

    # Check RuntimeClasses
    if kubectl get runtimeclass kata-fc &>/dev/null; then
        check_pass "RuntimeClass kata-fc exists"
    else
        check_fail "RuntimeClass kata-fc not found"
    fi

    if kubectl get runtimeclass kata-qemu &>/dev/null; then
        check_pass "RuntimeClass kata-qemu exists"
    else
        check_fail "RuntimeClass kata-qemu not found"
    fi

    # Test Kata runtime
    echo "   Testing Kata runtime..."
    kubectl run kata-validation-test --image=busybox --restart=Never \
        --overrides='{"spec":{"runtimeClassName":"kata-fc","nodeSelector":{"workload-type":"kata"}}}' \
        -- sh -c "uname -r && sleep 30" &>/dev/null || true

    # Wait for pod to be running
    for i in {1..30}; do
        POD_STATUS=$(kubectl get pod kata-validation-test -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$POD_STATUS" = "Running" ]; then
            break
        fi
        sleep 1
    done

    if [ "$POD_STATUS" = "Running" ]; then
        KERNEL_VERSION=$(kubectl exec kata-validation-test -- uname -r 2>/dev/null || echo "")
        if [[ "$KERNEL_VERSION" == 6.18* ]]; then
            check_pass "Kata runtime working (VM kernel: $KERNEL_VERSION)"
        else
            check_fail "Kata runtime issue (kernel: $KERNEL_VERSION, expected 6.18.x)"
        fi
    else
        check_fail "Kata test pod failed to start (status: $POD_STATUS)"
    fi

    # Cleanup test pod
    kubectl delete pod kata-validation-test --ignore-not-found &>/dev/null
else
    check_warning "No Kata nodes found (standard cluster, skipping Kata checks)"
fi
echo ""

# Summary
echo "════════════════════════════════════════════════════════════════"
echo "Validation Summary:"
echo "  ✅ Passed: $CHECKS_PASSED"
echo "  ❌ Failed: $CHECKS_FAILED"
echo "════════════════════════════════════════════════════════════════"

if [ $CHECKS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ Phase 2 validation PASSED${NC}"
    exit 0
else
    echo -e "${RED}❌ Phase 2 validation FAILED${NC}"
    exit 1
fi
