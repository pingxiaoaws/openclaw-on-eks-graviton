#!/bin/bash
export AWS_PAGER=""
# 09-setup-bedrock-api-key.sh
#
# Setup Bedrock API Key authentication for OpenClaw instances.
#
# This script:
#   1. Creates an IAM user with Bedrock access
#   2. Generates a Bedrock API Key (service-specific credential)
#   3. Creates a K8s Secret with AWS_BEARER_TOKEN_BEDROCK
#   4. Creates a test OpenClaw instance using the API key
#   5. Validates the deployment
#
# Background:
#   AWS Bedrock API Keys are service-specific credentials that use Bearer token
#   authentication instead of SigV4. The AWS SDK (boto3) supports this via the
#   AWS_BEARER_TOKEN_BEDROCK environment variable. OpenClaw's built-in bedrock/
#   model prefix uses the AWS SDK internally, so setting this env var enables
#   API key auth transparently.
#
# Reference:
#   - Generate: https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-generate.html
#   - Use:      https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-use.html
#
# How it works:
#   ┌─────────────────────────────────────────────────────────┐
#   │  K8s Secret (bedrock-api-key)                           │
#   │    AWS_BEARER_TOKEN_BEDROCK = <api-key>                 │
#   └──────────────────────┬──────────────────────────────────┘
#                          │ envFrom (injected as env var)
#                          ▼
#   ┌─────────────────────────────────────────────────────────┐
#   │  OpenClaw Pod                                           │
#   │    model: bedrock/us.anthropic.claude-sonnet-4-5-...    │
#   │                                                         │
#   │    AWS SDK detects AWS_BEARER_TOKEN_BEDROCK              │
#   │    → Uses Bearer token auth (NOT SigV4)                 │
#   │    → No IAM role / Pod Identity / AK-SK needed          │
#   └──────────────────────┬──────────────────────────────────┘
#                          │ Authorization: Bearer <api-key>
#                          ▼
#   ┌─────────────────────────────────────────────────────────┐
#   │  Bedrock Runtime API                                    │
#   │  https://bedrock-runtime.{region}.amazonaws.com         │
#   │  /model/{model-id}/converse                             │
#   └─────────────────────────────────────────────────────────┘
#
# Comparison with other auth methods:
#
#   | Method          | Credentials               | Rotation   | Use Case            |
#   |-----------------|---------------------------|------------|---------------------|
#   | Pod Identity    | Auto (IAM role via SA)    | Automatic  | Production (best)   |
#   | Bedrock API Key | AWS_BEARER_TOKEN_BEDROCK  | Manual     | Dev/test, simple    |
#   | AK/SK           | AWS_ACCESS_KEY_ID + SK    | Manual     | Not recommended     |
#
# Limitations:
#   - API keys are NOT supported for: InvokeModelWithBidirectionalStream,
#     Bedrock Agents APIs, Bedrock Data Automation APIs
#   - Max 2 service-specific credentials per user per service
#   - API key secret is only shown once at creation time

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}=== Setup Bedrock API Key for OpenClaw ===${NC}"
echo ""

# ============================================================================
# Auto-detect cluster info
# ============================================================================

CLUSTER_ARN=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || echo "")
if [[ "$CLUSTER_ARN" == arn:aws:eks:* ]]; then
  AWS_REGION=$(echo "$CLUSTER_ARN" | cut -d':' -f4)
  CLUSTER_NAME=$(echo "$CLUSTER_ARN" | cut -d'/' -f2)
else
  AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
  CLUSTER_NAME="unknown"
fi
AWS_ACCOUNT=${AWS_ACCOUNT_ID:-${AWS_ACCOUNT:-$(aws sts get-caller-identity --query Account --output text)}}

echo "Cluster: $CLUSTER_NAME"
echo "Region:  $AWS_REGION"
echo "Account: $AWS_ACCOUNT"
echo ""

# ============================================================================
# Configuration
# ============================================================================

IAM_USER_NAME="${BEDROCK_API_USER:-bedrock-api-user}"
BEDROCK_POLICY_ARN="arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
TEST_NAMESPACE="openclaw-test-apikey"
TEST_INSTANCE_NAME="openclaw-apikey-test"
SECRET_NAME="bedrock-api-key"
MODEL_ID="${BEDROCK_MODEL:-us.anthropic.claude-sonnet-4-5-20250929-v1:0}"

# ============================================================================
# Step 1: Create IAM User
# ============================================================================

echo -e "${CYAN}[Step 1/5] Creating IAM user: $IAM_USER_NAME${NC}"

if aws iam get-user --user-name "$IAM_USER_NAME" &>/dev/null; then
  echo -e "${YELLOW}  User already exists${NC}"
else
  aws iam create-user --user-name "$IAM_USER_NAME" > /dev/null
  echo -e "${GREEN}  Created${NC}"
fi

# Ensure policy is attached
aws iam attach-user-policy \
  --user-name "$IAM_USER_NAME" \
  --policy-arn "$BEDROCK_POLICY_ARN" 2>/dev/null || true
echo "  Policy attached: AmazonBedrockFullAccess"
echo ""

# ============================================================================
# Step 2: Generate Bedrock API Key
# ============================================================================

echo -e "${CYAN}[Step 2/5] Generating Bedrock API Key${NC}"

# Check existing credentials
EXISTING_CREDS=$(aws iam list-service-specific-credentials \
  --user-name "$IAM_USER_NAME" \
  --service-name bedrock.amazonaws.com \
  --query 'ServiceSpecificCredentials[].ServiceSpecificCredentialId' \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_CREDS" ]; then
  echo -e "${YELLOW}  Existing credential(s) found: $EXISTING_CREDS${NC}"
  echo "  Delete and regenerate? (yes/no, default: no)"
  read -p "  > " REGEN
  REGEN=${REGEN:-no}

  if [[ "$REGEN" =~ ^[Yy](es)?$ ]]; then
    for CRED_ID in $EXISTING_CREDS; do
      aws iam delete-service-specific-credential \
        --user-name "$IAM_USER_NAME" \
        --service-specific-credential-id "$CRED_ID"
      echo "  Deleted: $CRED_ID"
    done
  else
    echo -e "${YELLOW}  Keeping existing credential. Secret was only shown at creation time.${NC}"
    echo "  If you need a new key, re-run with 'yes' to regenerate."
    echo ""
    echo "  To use an existing key, set it manually:"
    echo "    kubectl create secret generic $SECRET_NAME -n <namespace> \\"
    echo "      --from-literal=AWS_BEARER_TOKEN_BEDROCK=<your-api-key>"
    exit 0
  fi
fi

CRED_JSON=$(aws iam create-service-specific-credential \
  --user-name "$IAM_USER_NAME" \
  --service-name bedrock.amazonaws.com \
  --output json)

CRED_SECRET=$(echo "$CRED_JSON" | jq -r '.ServiceSpecificCredential.ServiceCredentialSecret')
CRED_ID=$(echo "$CRED_JSON" | jq -r '.ServiceSpecificCredential.ServiceSpecificCredentialId')
CRED_ALIAS=$(echo "$CRED_JSON" | jq -r '.ServiceSpecificCredential.ServiceCredentialAlias')

echo -e "${GREEN}  API Key generated${NC}"
echo "  Credential ID:    $CRED_ID"
echo "  Credential Alias: $CRED_ALIAS"
echo ""
echo -e "${RED}  Save this key - it will NOT be shown again:${NC}"
echo "  $CRED_SECRET"
echo ""

# Quick validation with curl
echo "  Validating API key with Bedrock..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "https://bedrock-runtime.${AWS_REGION}.amazonaws.com/model/${MODEL_ID}/converse" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CRED_SECRET" \
  -d '{"messages":[{"role":"user","content":[{"text":"hi"}]}]}')

if [ "$HTTP_CODE" == "200" ]; then
  echo -e "${GREEN}  API key validated successfully (HTTP 200)${NC}"
else
  echo -e "${RED}  API key validation failed (HTTP $HTTP_CODE)${NC}"
  echo "  Check IAM permissions and model access in Bedrock console."
  exit 1
fi

echo ""

# ============================================================================
# Step 3: Create K8s Secret
# ============================================================================

echo -e "${CYAN}[Step 3/5] Creating K8s Secret${NC}"

kubectl create namespace "$TEST_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic "$SECRET_NAME" \
  -n "$TEST_NAMESPACE" \
  --from-literal=AWS_BEARER_TOKEN_BEDROCK="$CRED_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "${GREEN}  Secret '$SECRET_NAME' created in namespace '$TEST_NAMESPACE'${NC}"
echo ""

# ============================================================================
# Step 4: Create Test OpenClaw Instance
# ============================================================================

echo -e "${CYAN}[Step 4/5] Creating test OpenClaw instance${NC}"
echo "  Instance: $TEST_INSTANCE_NAME"
echo "  Model:    bedrock/$MODEL_ID"
echo "  Auth:     AWS_BEARER_TOKEN_BEDROCK (from secret)"
echo ""

# Set image spec based on region (China needs ECR Public mirror, global uses chart default)
if [[ "$AWS_REGION" == cn-* ]]; then
  OPENCLAW_IMAGE_SPEC="
    repository: public.ecr.aws/u6t0z4w2/openclaw
    tag: \"2026.3.13-1\""
else
  OPENCLAW_IMAGE_SPEC=""
fi

cat <<EOFINSTANCE | kubectl apply -f -
apiVersion: openclaw.rocks/v1alpha1
kind: OpenClawInstance
metadata:
  name: ${TEST_INSTANCE_NAME}
  namespace: ${TEST_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: bedrock-apikey-setup
spec:
  image:${OPENCLAW_IMAGE_SPEC}
    pullPolicy: IfNotPresent
  config:
    raw:
      gateway:
        controlUi:
          allowedOrigins:
            - "http://localhost:18789"
            - "http://127.0.0.1:18789"
        trustedProxies:
          - "0.0.0.0/0"
      agents:
        defaults:
          model:
            primary: "bedrock/${MODEL_ID}"
  envFrom:
    - secretRef:
        name: ${SECRET_NAME}
  env:
    - name: AWS_REGION
      value: "${AWS_REGION}"
    - name: AWS_DEFAULT_REGION
      value: "${AWS_REGION}"
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "2"
      memory: "4Gi"
  storage:
    persistence:
      enabled: true
      size: 10Gi
      storageClass: gp3
      accessModes:
        - ReadWriteOnce
  networking:
    service:
      type: ClusterIP
  security:
    podSecurityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
      runAsNonRoot: true
    containerSecurityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: false
      capabilities:
        drop:
          - ALL
    networkPolicy:
      enabled: true
      allowDNS: true
    rbac:
      createServiceAccount: true
  selfConfigure:
    enabled: true
  observability:
    metrics:
      enabled: true
      port: 9090
    logging:
      level: info
      format: json
EOFINSTANCE

echo "  Waiting for pod to be ready..."
for i in $(seq 1 12); do
  READY=$(kubectl get pod "${TEST_INSTANCE_NAME}-0" -n "$TEST_NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="openclaw")].ready}' 2>/dev/null || echo "false")
  if [ "$READY" == "true" ]; then
    break
  fi
  echo "    Waiting... ($((i*10))s)"
  sleep 10
done

kubectl get pods -n "$TEST_NAMESPACE"
echo ""

# ============================================================================
# Step 5: Verify & Output
# ============================================================================

echo -e "${CYAN}[Step 5/5] Verification${NC}"

POD_STATUS=$(kubectl get pod "${TEST_INSTANCE_NAME}-0" -n "$TEST_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
CONTAINERS_READY=$(kubectl get pod "${TEST_INSTANCE_NAME}-0" -n "$TEST_NAMESPACE" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null || echo "")

# Check env var is set
ENV_SET=$(kubectl exec "${TEST_INSTANCE_NAME}-0" -n "$TEST_NAMESPACE" -c openclaw -- env 2>/dev/null | grep -c "AWS_BEARER_TOKEN_BEDROCK" || echo "0")

echo "  Pod status:       $POD_STATUS"
echo "  Containers ready: $CONTAINERS_READY"
echo "  API key env set:  $([ "$ENV_SET" -gt 0 ] && echo 'yes' || echo 'no')"
echo ""

GATEWAY_TOKEN=$(kubectl get secret "${TEST_INSTANCE_NAME}-gateway-token" -n "$TEST_NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "")

echo -e "${GREEN}=== Setup Complete ===${NC}"
echo ""
echo "To access the OpenClaw Gateway UI:"
echo ""
echo "  1. Port-forward:"
echo "     kubectl port-forward pod/${TEST_INSTANCE_NAME}-0 -n ${TEST_NAMESPACE} 18789:18789"
echo ""
echo "  2. Open: http://localhost:18789"
echo ""
echo "  3. Gateway token:"
echo "     $GATEWAY_TOKEN"
echo ""
echo "  4. Approve device pairing (after connecting from browser):"
echo "     kubectl exec -n ${TEST_NAMESPACE} ${TEST_INSTANCE_NAME}-0 -c openclaw -- openclaw devices approve"
echo ""
echo "To use this in your own namespace:"
echo ""
echo "  # Create the secret"
echo "  kubectl create secret generic $SECRET_NAME -n <your-namespace> \\"
echo "    --from-literal=AWS_BEARER_TOKEN_BEDROCK='$CRED_SECRET'"
echo ""
echo "  # Add to OpenClawInstance spec:"
echo "  #   envFrom:"
echo "  #     - secretRef:"
echo "  #         name: $SECRET_NAME"
echo "  #   env:"
echo "  #     - name: AWS_REGION"
echo "  #       value: \"$AWS_REGION\""
echo ""
echo "To cleanup:"
echo "  kubectl delete openclawinstance $TEST_INSTANCE_NAME -n $TEST_NAMESPACE"
echo "  kubectl delete namespace $TEST_NAMESPACE"
echo "  aws iam delete-service-specific-credential --user-name $IAM_USER_NAME --service-specific-credential-id $CRED_ID"
echo "  aws iam detach-user-policy --user-name $IAM_USER_NAME --policy-arn $BEDROCK_POLICY_ARN"
echo "  aws iam delete-user --user-name $IAM_USER_NAME"
echo ""
