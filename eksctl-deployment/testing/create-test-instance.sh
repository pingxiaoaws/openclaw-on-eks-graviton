#!/usr/bin/env bash

##################################################
# Phase 6: OpenClaw Instance Creation
##################################################
#
# Creates a test OpenClaw instance and validates
# that it's running correctly with proper storage
# and runtime configuration.
#
# Usage:
#   ./create-test-instance.sh [standard|kata]
#
##################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

TEST_MODE="${1:-standard}"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          Phase 6: OpenClaw Instance Creation                   ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

echo "Test Mode: $TEST_MODE"
echo ""

# Generate user ID for test user
TEST_EMAIL="test@example.com"
USER_ID=$(echo -n "$TEST_EMAIL" | shasum -a 256 | cut -c1-16)
NAMESPACE="openclaw-$USER_ID"
INSTANCE_NAME="openclaw-$USER_ID"

echo -e "${BLUE}Step 1/6: Creating test OpenClaw instance${NC}"
echo "   User ID: $USER_ID"
echo "   Namespace: $NAMESPACE"
echo "   Instance: $INSTANCE_NAME"
echo ""

# Determine runtime configuration
if [ "$TEST_MODE" = "kata" ]; then
    RUNTIME_CLASS="kata-qemu"
    NODE_SELECTOR='{"workload-type":"kata"}'
    TOLERATIONS='[{"key":"kata-dedicated","operator":"Exists","effect":"NoSchedule"}]'
    echo "   Runtime: Kata Containers (VM isolation)"
else
    RUNTIME_CLASS=""
    NODE_SELECTOR='{}'
    TOLERATIONS='[]'
    echo "   Runtime: containerd (runc)"
fi

# Create namespace
if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo -e "${YELLOW}⚠️  Namespace $NAMESPACE already exists, deleting...${NC}"
    kubectl delete namespace "$NAMESPACE" --wait=true --timeout=60s || true
    sleep 5
fi

kubectl create namespace "$NAMESPACE"
echo -e "${GREEN}✅ Namespace created${NC}"
echo ""

# Create AWS credentials secret
echo -e "${BLUE}Step 2/6: Creating AWS credentials secret${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: aws-credentials
  namespace: $NAMESPACE
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "dummy-key-id"
  AWS_SECRET_ACCESS_KEY: "dummy-secret-key"
  AWS_REGION: "us-west-2"
EOF
echo -e "${GREEN}✅ Secret created${NC}"
echo ""

# Create OpenClawInstance
echo -e "${BLUE}Step 3/6: Creating OpenClawInstance${NC}"

RUNTIME_CLASS_FIELD=""
if [ -n "$RUNTIME_CLASS" ]; then
    RUNTIME_CLASS_FIELD="runtimeClassName: $RUNTIME_CLASS"
fi

cat <<EOF | kubectl apply -f -
apiVersion: openclaw.rocks/v1alpha1
kind: OpenClawInstance
metadata:
  name: $INSTANCE_NAME
  namespace: $NAMESPACE
spec:
  config:
    raw:
      agents:
        defaults:
          model:
            primary: "bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0"

  envFrom:
    - secretRef:
        name: aws-credentials

  availability:
    ${RUNTIME_CLASS_FIELD}
    nodeSelector: $(echo "$NODE_SELECTOR" | jq -c .)
    tolerations: $(echo "$TOLERATIONS" | jq -c .)

  resources:
    requests:
      cpu: "600m"
      memory: "1.2Gi"
    limits:
      cpu: "2"
      memory: "4Gi"

  storage:
    persistence:
      enabled: true
      size: 10Gi
      storageClass: efs-sc
      accessModes:
        - ReadWriteMany

  networking:
    service:
      type: ClusterIP

  observability:
    metrics:
      enabled: true
    logging:
      level: info
      format: json
EOF

echo -e "${GREEN}✅ OpenClawInstance created${NC}"
echo ""

# Wait for instance to be ready
echo -e "${BLUE}Step 4/6: Waiting for instance to be ready (max 5 minutes)${NC}"
TIMEOUT=300
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    PHASE=$(kubectl get openclawinstance "$INSTANCE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    READY=$(kubectl get openclawinstance "$INSTANCE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")

    if [ "$PHASE" = "Running" ] && [ "$READY" = "true" ]; then
        echo -e "${GREEN}✅ Instance is ready (Phase: $PHASE, Ready: $READY)${NC}"
        break
    fi

    echo "   Waiting... (Phase: $PHASE, Ready: $READY, ${ELAPSED}s elapsed)"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo -e "${RED}❌ Instance did not become ready within $TIMEOUT seconds${NC}"
    echo "   Checking events..."
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -10
    exit 1
fi
echo ""

# Validate deployment
echo -e "${BLUE}Step 5/6: Validating deployment${NC}"

CHECKS_PASSED=0
CHECKS_FAILED=0

# Check StatefulSet
STATEFULSET_READY=$(kubectl get statefulset "$INSTANCE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "$STATEFULSET_READY" -eq 1 ]; then
    echo -e "${GREEN}✅ StatefulSet ready (1/1)${NC}"
    ((CHECKS_PASSED++))
else
    echo -e "${RED}❌ StatefulSet not ready ($STATEFULSET_READY/1)${NC}"
    ((CHECKS_FAILED++))
fi

# Check Pod
POD_NAME="${INSTANCE_NAME}-0"
POD_STATUS=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "$POD_STATUS" = "Running" ]; then
    echo -e "${GREEN}✅ Pod is Running${NC}"
    ((CHECKS_PASSED++))
else
    echo -e "${RED}❌ Pod status: $POD_STATUS${NC}"
    ((CHECKS_FAILED++))
fi

# Check PVC
PVC_STATUS=$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
if [ "$PVC_STATUS" = "Bound" ]; then
    PVC_STORAGECLASS=$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{.items[0].spec.storageClassName}')
    PVC_SIZE=$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{.items[0].spec.resources.requests.storage}')
    echo -e "${GREEN}✅ PVC is Bound (StorageClass: $PVC_STORAGECLASS, Size: $PVC_SIZE)${NC}"
    ((CHECKS_PASSED++))
else
    echo -e "${RED}❌ PVC status: $PVC_STATUS${NC}"
    ((CHECKS_FAILED++))
fi

# Verify EFS mount
if [ "$POD_STATUS" = "Running" ]; then
    MOUNT_INFO=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -c openclaw -- df -h /home/openclaw/.openclaw 2>/dev/null | tail -1 || echo "")
    if echo "$MOUNT_INFO" | grep -q "nfs"; then
        MOUNT_SIZE=$(echo "$MOUNT_INFO" | awk '{print $2}')
        echo -e "${GREEN}✅ EFS mounted (Size: $MOUNT_SIZE, Type: NFS)${NC}"
        ((CHECKS_PASSED++))
    else
        echo -e "${RED}❌ EFS mount not found or not NFS${NC}"
        echo "   Mount info: $MOUNT_INFO"
        ((CHECKS_FAILED++))
    fi
fi

# Check runtime class (if Kata)
if [ "$TEST_MODE" = "kata" ]; then
    POD_RUNTIME_CLASS=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.runtimeClassName}' 2>/dev/null || echo "")
    if [ "$POD_RUNTIME_CLASS" = "$RUNTIME_CLASS" ]; then
        echo -e "${GREEN}✅ Runtime class: $POD_RUNTIME_CLASS${NC}"
        ((CHECKS_PASSED++))
    else
        echo -e "${RED}❌ Runtime class: $POD_RUNTIME_CLASS (expected: $RUNTIME_CLASS)${NC}"
        ((CHECKS_FAILED++))
    fi

    # Verify VM kernel
    if [ "$POD_STATUS" = "Running" ]; then
        KERNEL_VERSION=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -c openclaw -- uname -r 2>/dev/null || echo "")
        if [[ "$KERNEL_VERSION" == 6.18* ]]; then
            echo -e "${GREEN}✅ VM kernel verified: $KERNEL_VERSION${NC}"
            ((CHECKS_PASSED++))
        else
            echo -e "${RED}❌ Kernel version: $KERNEL_VERSION (expected 6.18.x for Kata VM)${NC}"
            ((CHECKS_FAILED++))
        fi
    fi
fi

echo ""

# Check logs for errors
echo -e "${BLUE}Step 6/6: Checking pod logs${NC}"
if [ "$POD_STATUS" = "Running" ]; then
    LOG_ERRORS=$(kubectl logs "$POD_NAME" -n "$NAMESPACE" -c openclaw --tail=50 2>/dev/null | grep -i "error" | wc -l || echo "0")
    if [ "$LOG_ERRORS" -eq 0 ]; then
        echo -e "${GREEN}✅ No errors in pod logs${NC}"
        ((CHECKS_PASSED++))
    else
        echo -e "${YELLOW}⚠️  Found $LOG_ERRORS error messages in logs (review manually)${NC}"
        echo "   Last 10 lines:"
        kubectl logs "$POD_NAME" -n "$NAMESPACE" -c openclaw --tail=10 2>/dev/null | sed 's/^/      /'
    fi
else
    echo -e "${RED}❌ Pod not running, cannot check logs${NC}"
    ((CHECKS_FAILED++))
fi
echo ""

# Summary
echo "════════════════════════════════════════════════════════════════"
echo "Validation Summary:"
echo "  ✅ Passed: $CHECKS_PASSED"
echo "  ❌ Failed: $CHECKS_FAILED"
echo "════════════════════════════════════════════════════════════════"
echo ""

if [ $CHECKS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ Phase 6: OpenClaw instance validation PASSED${NC}"
    echo ""
    echo "Instance Information:"
    echo "  Namespace: $NAMESPACE"
    echo "  Instance: $INSTANCE_NAME"
    echo "  Pod: $POD_NAME"
    echo "  Runtime: $([ "$TEST_MODE" = "kata" ] && echo "Kata Containers (VM)" || echo "containerd (runc)")"
    echo ""
    echo "Test gateway access (optional):"
    echo "  kubectl port-forward -n $NAMESPACE $POD_NAME 18789:18789"
    echo ""
    exit 0
else
    echo -e "${RED}❌ Phase 6: OpenClaw instance validation FAILED${NC}"
    echo ""
    echo "Debug commands:"
    echo "  kubectl describe openclawinstance $INSTANCE_NAME -n $NAMESPACE"
    echo "  kubectl describe pod $POD_NAME -n $NAMESPACE"
    echo "  kubectl logs $POD_NAME -n $NAMESPACE -c openclaw"
    echo "  kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp'"
    echo ""
    exit 1
fi
