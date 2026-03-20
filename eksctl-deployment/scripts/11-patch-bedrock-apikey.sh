#!/bin/bash
export AWS_PAGER=""
# 11-patch-bedrock-apikey.sh
#
# Patch an existing OpenClaw instance to use Bedrock API Key authentication.
#
# This script:
#   1. Patches the instance's existing secret to add AWS_BEARER_TOKEN_BEDROCK
#   2. Optionally adds AWS_REGION env vars to the secret
#   3. Restarts the pod to pick up the new env vars
#
# Usage:
#   INSTANCE_NAME=ping-1234 NAMESPACE=tenant-pingxiao BEDROCK_API_KEY=ABSK... ./11-patch-bedrock-apikey.sh
#
# Required env vars:
#   INSTANCE_NAME    - OpenClaw instance name (e.g. ping-1234)
#   NAMESPACE        - Kubernetes namespace (e.g. tenant-pingxiao)
#   BEDROCK_API_KEY  - Bedrock API Key (AWS_BEARER_TOKEN_BEDROCK value)
#
# Optional env vars:
#   BEDROCK_REGION   - Bedrock region (default: us-east-1)
#   SECRET_NAME      - Override secret name (default: ${INSTANCE_NAME}-keys)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Validate required env vars
if [ -z "${INSTANCE_NAME:-}" ]; then
  echo -e "${RED}Error: INSTANCE_NAME is required${NC}"
  echo "Usage: INSTANCE_NAME=ping-1234 NAMESPACE=tenant-pingxiao BEDROCK_API_KEY=ABSK... $0"
  exit 1
fi

if [ -z "${NAMESPACE:-}" ]; then
  echo -e "${RED}Error: NAMESPACE is required${NC}"
  echo "Usage: INSTANCE_NAME=ping-1234 NAMESPACE=tenant-pingxiao BEDROCK_API_KEY=ABSK... $0"
  exit 1
fi

if [ -z "${BEDROCK_API_KEY:-}" ]; then
  echo -e "${RED}Error: BEDROCK_API_KEY is required${NC}"
  echo "Usage: INSTANCE_NAME=ping-1234 NAMESPACE=tenant-pingxiao BEDROCK_API_KEY=ABSK... $0"
  exit 1
fi

BEDROCK_REGION="${BEDROCK_REGION:-us-east-1}"
SECRET_NAME="${SECRET_NAME:-${INSTANCE_NAME}-keys}"

echo -e "${CYAN}=== Patch Bedrock API Key ===${NC}"
echo ""
echo "  Instance:   $INSTANCE_NAME"
echo "  Namespace:  $NAMESPACE"
echo "  Secret:     $SECRET_NAME"
echo "  Region:     $BEDROCK_REGION"
echo ""

# ============================================================================
# Step 1: Verify instance exists
# ============================================================================

echo -e "${CYAN}[1/4] Verifying instance...${NC}"

PHASE=$(kubectl get openclawinstance "$INSTANCE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ -z "$PHASE" ]; then
  echo -e "${RED}  Instance $INSTANCE_NAME not found in namespace $NAMESPACE${NC}"
  exit 1
fi
echo -e "${GREEN}  Instance found (phase: $PHASE)${NC}"

# ============================================================================
# Step 2: Patch secret
# ============================================================================

echo -e "${CYAN}[2/4] Patching secret: $SECRET_NAME${NC}"

# Check if secret exists
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "  Secret exists, patching..."

  # Get current secret data, add new keys, apply
  kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o json | \
    python3 -c "
import json, sys, base64

secret = json.load(sys.stdin)
if 'data' not in secret:
    secret['data'] = {}

secret['data']['AWS_BEARER_TOKEN_BEDROCK'] = base64.b64encode(b'${BEDROCK_API_KEY}').decode()
secret['data']['AWS_REGION'] = base64.b64encode(b'${BEDROCK_REGION}').decode()
secret['data']['AWS_DEFAULT_REGION'] = base64.b64encode(b'${BEDROCK_REGION}').decode()

# Remove managed fields to avoid conflict
secret.get('metadata', {}).pop('managedFields', None)
secret.get('metadata', {}).pop('resourceVersion', None)

json.dump(secret, sys.stdout)
" | kubectl apply -f - >/dev/null 2>&1

  echo -e "${GREEN}  Patched: AWS_BEARER_TOKEN_BEDROCK, AWS_REGION=$BEDROCK_REGION${NC}"

else
  echo "  Secret does not exist, creating..."
  kubectl create secret generic "$SECRET_NAME" \
    -n "$NAMESPACE" \
    --from-literal=AWS_BEARER_TOKEN_BEDROCK="$BEDROCK_API_KEY" \
    --from-literal=AWS_REGION="$BEDROCK_REGION" \
    --from-literal=AWS_DEFAULT_REGION="$BEDROCK_REGION"
  echo -e "${GREEN}  Created secret $SECRET_NAME${NC}"
fi

echo ""

# ============================================================================
# Step 3: Verify envFrom references the secret
# ============================================================================

echo -e "${CYAN}[3/4] Verifying envFrom...${NC}"

ENV_FROM=$(kubectl get openclawinstance "$INSTANCE_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.envFrom[*].secretRef.name}' 2>/dev/null || echo "")

if echo "$ENV_FROM" | grep -q "$SECRET_NAME"; then
  echo -e "${GREEN}  envFrom already references $SECRET_NAME${NC}"
else
  echo -e "${YELLOW}  Warning: envFrom does not reference $SECRET_NAME${NC}"
  echo "  You may need to patch the OpenClawInstance to add:"
  echo ""
  echo "    spec:"
  echo "      envFrom:"
  echo "        - secretRef:"
  echo "            name: $SECRET_NAME"
  echo ""
  echo "  Run:"
  echo "    kubectl patch openclawinstance $INSTANCE_NAME -n $NAMESPACE --type='merge' -p '{\"spec\":{\"envFrom\":[{\"secretRef\":{\"name\":\"$SECRET_NAME\"}}]}}'"
fi

echo ""

# ============================================================================
# Step 4: Restart pod
# ============================================================================

echo -e "${CYAN}[4/4] Restarting pod...${NC}"

POD_NAME="${INSTANCE_NAME}-0"
if kubectl get pod "$POD_NAME" -n "$NAMESPACE" &>/dev/null; then
  kubectl delete pod "$POD_NAME" -n "$NAMESPACE"
  echo "  Deleted pod $POD_NAME, waiting for restart..."

  # Wait for pod to be ready
  for i in $(seq 1 12); do
    sleep 10
    READY=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="openclaw")].ready}' 2>/dev/null || echo "false")
    if [ "$READY" == "true" ]; then
      echo -e "${GREEN}  Pod $POD_NAME is ready${NC}"
      break
    fi
    echo "    Waiting... ($((i*10))s)"
  done
else
  echo -e "${YELLOW}  Pod $POD_NAME not found, skipping restart${NC}"
fi

echo ""

# ============================================================================
# Verify
# ============================================================================

echo -e "${CYAN}=== Verification ===${NC}"
echo ""

# Check env vars in pod
ENV_SET=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -c openclaw -- env 2>/dev/null | grep -c "AWS_BEARER_TOKEN_BEDROCK" || echo "0")
REGION_SET=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -c openclaw -- env 2>/dev/null | grep "AWS_REGION" | head -1 || echo "not set")

echo "  AWS_BEARER_TOKEN_BEDROCK: $([ "$ENV_SET" -gt 0 ] && echo 'set' || echo 'NOT SET')"
echo "  $REGION_SET"
echo ""

# Get gateway token
GATEWAY_TOKEN=$(kubectl get secret "${INSTANCE_NAME}-gateway-token" -n "$NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "N/A")

echo -e "${GREEN}=== Done ===${NC}"
echo ""
echo "  Gateway token: $GATEWAY_TOKEN"
echo ""
echo "  Port-forward:"
echo "    kubectl port-forward pod/${POD_NAME} -n ${NAMESPACE} 18789:18789"
echo ""
echo "  Open: http://localhost:18789"
echo ""
echo "  Approve device (if needed):"
echo "    kubectl exec -n ${NAMESPACE} ${POD_NAME} -c openclaw -- openclaw devices approve"
