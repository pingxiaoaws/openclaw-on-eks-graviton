#!/bin/bash
export AWS_PAGER=""
# Generate Bedrock API Key using IAM Service-Specific Credentials
#
# Creates an IAM user with Bedrock access and generates a long-term API key.
# The API key can be used with: Authorization: Bearer <key>
# Endpoint: https://bedrock-runtime.{region}.amazonaws.com/model/{model-id}/converse
#
# Reference: https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-generate.html

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Generate Bedrock API Key ===${NC}"
echo ""

# Config
IAM_USER_NAME="${BEDROCK_API_USER:-bedrock-api-user}"
BEDROCK_POLICY_ARN="arn:aws:iam::aws:policy/AmazonBedrockFullAccess"

# Auto-detect region
CLUSTER_ARN=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || echo "")
if [[ "$CLUSTER_ARN" == arn:aws:eks:* ]]; then
  AWS_REGION=$(echo "$CLUSTER_ARN" | cut -d':' -f4)
else
  AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
fi

AWS_ACCOUNT=${AWS_ACCOUNT_ID:-${AWS_ACCOUNT:-$(aws sts get-caller-identity --query Account --output text)}}

echo "Region:   $AWS_REGION"
echo "Account:  $AWS_ACCOUNT"
echo "IAM User: $IAM_USER_NAME"
echo ""

# ============================================================================
# Step 1: Create IAM User (if not exists)
# ============================================================================

echo -e "${BLUE}[1/4] Creating IAM user...${NC}"

if aws iam get-user --user-name "$IAM_USER_NAME" &>/dev/null; then
  echo -e "${YELLOW}  IAM user already exists: $IAM_USER_NAME${NC}"
else
  aws iam create-user --user-name "$IAM_USER_NAME" > /dev/null
  echo -e "${GREEN}  Created IAM user: $IAM_USER_NAME${NC}"
fi

echo ""

# ============================================================================
# Step 2: Attach Bedrock Policy
# ============================================================================

echo -e "${BLUE}[2/4] Attaching Bedrock policy...${NC}"

aws iam attach-user-policy \
  --user-name "$IAM_USER_NAME" \
  --policy-arn "$BEDROCK_POLICY_ARN" 2>/dev/null || true
echo -e "${GREEN}  Attached: $BEDROCK_POLICY_ARN${NC}"
echo ""

# ============================================================================
# Step 3: Generate Service-Specific Credential (API Key)
# ============================================================================

echo -e "${BLUE}[3/4] Generating Bedrock API key...${NC}"

# Check existing credentials
EXISTING_CREDS=$(aws iam list-service-specific-credentials \
  --user-name "$IAM_USER_NAME" \
  --service-name bedrock.amazonaws.com \
  --query 'ServiceSpecificCredentials[].ServiceSpecificCredentialId' \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_CREDS" ]; then
  echo -e "${YELLOW}  Existing credentials found. Delete and regenerate? (yes/no)${NC}"
  read -p "  > " REGEN
  if [[ "$REGEN" =~ ^[Yy](es)?$ ]]; then
    for CRED_ID in $EXISTING_CREDS; do
      aws iam delete-service-specific-credential \
        --user-name "$IAM_USER_NAME" \
        --service-specific-credential-id "$CRED_ID"
      echo "  Deleted old credential: $CRED_ID"
    done
  else
    echo "  Keeping existing credentials."
    # Show existing credential info
    aws iam list-service-specific-credentials \
      --user-name "$IAM_USER_NAME" \
      --service-name bedrock.amazonaws.com \
      --output table
    echo ""
    echo -e "${YELLOW}  Note: The secret is only shown at creation time.${NC}"
    echo "  If you need the secret, delete and regenerate."
    exit 0
  fi
fi

CRED_JSON=$(aws iam create-service-specific-credential \
  --user-name "$IAM_USER_NAME" \
  --service-name bedrock.amazonaws.com \
  --output json)

CRED_ALIAS=$(echo "$CRED_JSON" | jq -r '.ServiceSpecificCredential.ServiceCredentialAlias')
CRED_SECRET=$(echo "$CRED_JSON" | jq -r '.ServiceSpecificCredential.ServiceCredentialSecret')
CRED_ID=$(echo "$CRED_JSON" | jq -r '.ServiceSpecificCredential.ServiceSpecificCredentialId')

echo -e "${GREEN}  API key generated successfully${NC}"
echo ""

# ============================================================================
# Step 4: Output
# ============================================================================

echo -e "${BLUE}[4/4] API Key Details${NC}"
echo ""
echo "  Credential ID:    $CRED_ID"
echo "  Credential Alias: $CRED_ALIAS"
echo ""
echo -e "${GREEN}  API Key (save this - it won't be shown again!):${NC}"
echo ""
echo "  $CRED_SECRET"
echo ""

echo "=========================================="
echo ""
echo "Usage:"
echo ""
echo "  Endpoint: https://bedrock-runtime.${AWS_REGION}.amazonaws.com"
echo ""
echo "  curl example:"
echo "    curl -X POST \\"
echo "      https://bedrock-runtime.${AWS_REGION}.amazonaws.com/model/us.anthropic.claude-sonnet-4-5-20250929-v1:0/converse \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -H 'Authorization: Bearer ${CRED_SECRET}' \\"
echo "      -d '{\"messages\":[{\"role\":\"user\",\"content\":[{\"text\":\"Hello\"}]}]}'"
echo ""

# Optionally create K8s secret
echo -e "${BLUE}Create K8s secret for OpenClaw? (yes/no)${NC}"
read -p "> " CREATE_SECRET

if [[ "$CREATE_SECRET" =~ ^[Yy](es)?$ ]]; then
  NAMESPACE="${K8S_NAMESPACE:-openclaw-test-apikey}"
  read -p "Namespace (default: $NAMESPACE): " NS_INPUT
  NAMESPACE="${NS_INPUT:-$NAMESPACE}"

  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic bedrock-api-key \
    -n "$NAMESPACE" \
    --from-literal=BEDROCK_API_KEY="$CRED_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo -e "${GREEN}  Secret 'bedrock-api-key' created in namespace '$NAMESPACE'${NC}"
  echo ""
  echo "  Use in OpenClawInstance spec:"
  echo "    envFrom:"
  echo "      - secretRef:"
  echo "          name: bedrock-api-key"
fi

echo ""
echo -e "${GREEN}Done!${NC}"
