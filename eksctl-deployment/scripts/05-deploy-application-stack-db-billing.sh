#!/bin/bash
export AWS_PAGER=""
# Phase 3: Deploy Complete Application Stack WITH Billing
# - OpenClaw Operator
# - Bedrock IAM Role & Pod Identity
# - Build & Push Docker Image
# - Provisioning Service (with full config)
# - Internet-facing ALB
# - CloudFront Distribution
# - Billing DB Migration + Sidecar Enablement

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
TEMPLATE_DIR="$(cd "${SCRIPT_DIR}/../templates"; pwd)"

echo -e "${BLUE}=== Phase 3: Complete Application Stack Deployment (with Billing) ===${NC}"
echo ""

# Get cluster info (resolve from cluster ARN, not context name which may be an alias)
CLUSTER_ARN=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
if [[ "$CLUSTER_ARN" == arn:aws*:eks:* ]]; then
  AWS_REGION=$(echo "$CLUSTER_ARN" | cut -d':' -f4)
  CLUSTER_NAME=$(echo "$CLUSTER_ARN" | cut -d'/' -f2)
else
  # Fallback: try context name
  CONTEXT=$(kubectl config current-context)
  CLUSTER_NAME=$(echo "$CONTEXT" | cut -d'@' -f2 | cut -d'.' -f1)
  AWS_REGION=$(echo "$CONTEXT" | grep -o 'us-[a-z]*-[0-9]' || echo "us-east-1")
fi
AWS_ACCOUNT=${AWS_ACCOUNT_ID:-${AWS_ACCOUNT:-$(aws sts get-caller-identity --query Account --output text)}}
if [[ "$AWS_REGION" == cn-* ]]; then
  AWS_PARTITION="aws-cn"
else
  AWS_PARTITION="aws"
fi
export AWS_PARTITION
PROVISIONING_DIR="$(dirname "$0")/../../eks-pod-service"

echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Account: $AWS_ACCOUNT"
echo ""

# ============================================================================
# Step 1: Install OpenClaw Operator
# ============================================================================

echo -e "${BLUE}[1/11] Installing OpenClaw Operator...${NC}"

OPERATOR_DIR="$(dirname "$0")/../../openclaw-operator"
if [ ! -d "$OPERATOR_DIR" ]; then
  echo -e "${YELLOW}⚠️  Operator directory not found: $OPERATOR_DIR${NC}"
  echo "Skipping operator installation (deploy manually later)"
else
  cd "$OPERATOR_DIR"

  if [ -d "charts/openclaw-operator" ]; then
    # China regions cannot access ghcr.io; use ECR mirror instead
    HELM_EXTRA_ARGS=""
    if [[ "$AWS_REGION" == cn-* ]]; then
      HELM_EXTRA_ARGS="--set image.repository=public.ecr.aws/u6t0z4w2/openclaw --set image.tag=2026.3.13-1"
    fi

    helm upgrade --install openclaw-operator charts/openclaw-operator \
      --namespace openclaw-operator-system \
      --create-namespace \
      --wait \
      $HELM_EXTRA_ARGS
    echo -e "${GREEN}✅ OpenClaw Operator installed${NC}"
  else
    echo "Using kustomize deployment..."
    kubectl apply -k config/default
    echo -e "${GREEN}✅ OpenClaw Operator installed (kustomize)${NC}"
  fi

  cd - > /dev/null
fi

# echo ""

# ============================================================================
# Step 2: Create Bedrock IAM Policy and Role
# ============================================================================

echo -e "${BLUE}[2/11] Creating Bedrock IAM Role...${NC}"

BEDROCK_POLICY_NAME="OpenClawBedrockAccess"
BEDROCK_POLICY_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:policy/${BEDROCK_POLICY_NAME}"

if aws iam get-policy --policy-arn "$BEDROCK_POLICY_ARN" &>/dev/null; then
  echo -e "${YELLOW}⚠️  Bedrock policy already exists${NC}"
else
  echo "Creating Bedrock IAM policy..."
  cat > /tmp/bedrock-policy.json <<EOFPOLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:ListFoundationModels"
      ],
      "Resource": [
        "arn:${AWS_PARTITION}:bedrock:*:*:model/*",
        "arn:${AWS_PARTITION}:bedrock:*:*:inference-profile/*",
        "arn:${AWS_PARTITION}:bedrock:*::foundation-model/*"
      ]
    }
  ]
}
EOFPOLICY

  aws iam create-policy \
    --policy-name "$BEDROCK_POLICY_NAME" \
    --policy-document file:///tmp/bedrock-policy.json \
    --description "Allow OpenClaw instances to access AWS Bedrock"

  echo -e "${GREEN}✅ Bedrock IAM policy created${NC}"
fi

BEDROCK_ROLE_NAME="OpenClawBedrockRole"

if aws iam get-role --role-name "$BEDROCK_ROLE_NAME" &>/dev/null; then
  echo -e "${YELLOW}⚠️  Bedrock role already exists${NC}"
  # Ensure policy is attached (may have been detached by cleanup)
  aws iam attach-role-policy \
    --role-name "$BEDROCK_ROLE_NAME" \
    --policy-arn "$BEDROCK_POLICY_ARN" 2>/dev/null || true
  echo "  Ensured policy is attached to role"
else
  echo "Creating Bedrock IAM role..."
  cat > /tmp/bedrock-trust-policy.json <<EOFTRUST
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
EOFTRUST

  aws iam create-role \
    --role-name "$BEDROCK_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/bedrock-trust-policy.json \
    --description "IAM role for OpenClaw Bedrock access via Pod Identity"

  aws iam attach-role-policy \
    --role-name "$BEDROCK_ROLE_NAME" \
    --policy-arn "$BEDROCK_POLICY_ARN"

  echo -e "${GREEN}✅ Bedrock IAM role created${NC}"
fi

echo ""

# ============================================================================
# Step 2.5: Create Provisioning Service IAM Role (for managing user resources)
# ============================================================================

echo -e "${BLUE}[2.5/11] Creating Provisioning Service IAM Role...${NC}"

PROVISIONING_POLICY_NAME="OpenClawProvisioningServicePolicy"
PROVISIONING_POLICY_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:policy/${PROVISIONING_POLICY_NAME}"

if aws iam get-policy --policy-arn "$PROVISIONING_POLICY_ARN" &>/dev/null; then
  echo -e "${YELLOW}⚠️  Provisioning service policy already exists, updating...${NC}"

  # Create updated policy document
  cat > /tmp/provisioning-policy.json <<EOFPOLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageUserIAMRoles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:TagRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies"
      ],
      "Resource": "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:role/openclaw-user-*"
    },
    {
      "Sid": "PassRoleToServiceAccounts",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": [
        "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:role/OpenClawBedrockRole",
        "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:role/openclaw-user-*"
      ]
    },
    {
      "Sid": "GetSharedBedrockRole",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole"
      ],
      "Resource": "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:role/OpenClawBedrockRole"
    },
    {
      "Sid": "ManagePodIdentityAssociations",
      "Effect": "Allow",
      "Action": [
        "eks:CreatePodIdentityAssociation",
        "eks:DeletePodIdentityAssociation",
        "eks:DescribePodIdentityAssociation",
        "eks:ListPodIdentityAssociations"
      ],
      "Resource": "*"
    }
  ]
}
EOFPOLICY

  # Create new version and set as default
  aws iam create-policy-version \
    --policy-arn "$PROVISIONING_POLICY_ARN" \
    --policy-document file:///tmp/provisioning-policy.json \
    --set-as-default > /dev/null

  echo -e "${GREEN}✅ Provisioning service IAM policy updated${NC}"
else
  echo "Creating Provisioning Service IAM policy..."
  cat > /tmp/provisioning-policy.json <<EOFPOLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageUserIAMRoles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:TagRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies"
      ],
      "Resource": "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:role/openclaw-user-*"
    },
    {
      "Sid": "PassRoleToServiceAccounts",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": [
        "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:role/OpenClawBedrockRole",
        "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:role/openclaw-user-*"
      ]
    },
    {
      "Sid": "GetSharedBedrockRole",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole"
      ],
      "Resource": "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:role/OpenClawBedrockRole"
    },
    {
      "Sid": "ManagePodIdentityAssociations",
      "Effect": "Allow",
      "Action": [
        "eks:CreatePodIdentityAssociation",
        "eks:DeletePodIdentityAssociation",
        "eks:DescribePodIdentityAssociation",
        "eks:ListPodIdentityAssociations"
      ],
      "Resource": "*"
    }
  ]
}
EOFPOLICY

  aws iam create-policy \
    --policy-name "$PROVISIONING_POLICY_NAME" \
    --policy-document file:///tmp/provisioning-policy.json \
    --description "Allow OpenClaw provisioning service to manage user IAM roles and Pod Identity"

  echo -e "${GREEN}✅ Provisioning service IAM policy created${NC}"
fi

PROVISIONING_ROLE_NAME="openclaw-provisioning-service"

if aws iam get-role --role-name "$PROVISIONING_ROLE_NAME" &>/dev/null; then
  echo -e "${YELLOW}⚠️  Provisioning service role already exists${NC}"
  # Ensure policy is attached (may have been detached by cleanup)
  aws iam attach-role-policy \
    --role-name "$PROVISIONING_ROLE_NAME" \
    --policy-arn "$PROVISIONING_POLICY_ARN" 2>/dev/null || true
  echo "  Ensured policy is attached to role"
else
  echo "Creating Provisioning Service IAM role..."
  cat > /tmp/provisioning-trust-policy.json <<EOFTRUST
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
EOFTRUST

  aws iam create-role \
    --role-name "$PROVISIONING_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/provisioning-trust-policy.json \
    --description "IAM role for OpenClaw provisioning service via Pod Identity"

  aws iam attach-role-policy \
    --role-name "$PROVISIONING_ROLE_NAME" \
    --policy-arn "$PROVISIONING_POLICY_ARN"

  echo -e "${GREEN}✅ Provisioning service IAM role created${NC}"
fi

# Create Pod Identity Association for provisioning service
PROVISIONING_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:role/${PROVISIONING_ROLE_NAME}"

EXISTING_PROV_ASSOC=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace openclaw-provisioning \
  --service-account openclaw-provisioner \
  --query 'associations[0].associationId' \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_PROV_ASSOC" ] && [ "$EXISTING_PROV_ASSOC" != "None" ]; then
  echo -e "${YELLOW}⚠️  Provisioning service Pod Identity association already exists: $EXISTING_PROV_ASSOC${NC}"
else
  aws eks create-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" \
    --namespace openclaw-provisioning \
    --service-account openclaw-provisioner \
    --role-arn "$PROVISIONING_ROLE_ARN" \
    --region "$AWS_REGION"

  echo -e "${GREEN}✅ Provisioning service Pod Identity association created${NC}"
fi

echo ""

# ============================================================================
# Step 3: Create Pod Identity Association (for user instances)
# ============================================================================

echo -e "${BLUE}[3/11] Creating User Instance Pod Identity Association...${NC}"

BEDROCK_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:role/${BEDROCK_ROLE_NAME}"

EXISTING_ASSOC=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace openclaw \
  --service-account openclaw-bedrock-access \
  --query 'associations[0].associationId' \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_ASSOC" ] && [ "$EXISTING_ASSOC" != "None" ]; then
  echo -e "${YELLOW}⚠️  Pod Identity association already exists: $EXISTING_ASSOC${NC}"
else
  kubectl create namespace openclaw --dry-run=client -o yaml | kubectl apply -f -
  kubectl create serviceaccount openclaw-bedrock-access -n openclaw --dry-run=client -o yaml | kubectl apply -f -

  aws eks create-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" \
    --namespace openclaw \
    --service-account openclaw-bedrock-access \
    --role-arn "$BEDROCK_ROLE_ARN" \
    --region "$AWS_REGION"

  echo -e "${GREEN}✅ Pod Identity association created${NC}"
fi

echo ""

# ============================================================================
# Step 4: Build and Push Docker Image (Optional)
# ============================================================================

echo -e "${BLUE}[4/11] Building and pushing Docker image (optional)...${NC}"
echo ""

# Support BUILD_IMAGE env var for non-interactive use
if [ -z "${BUILD_IMAGE:-}" ]; then
  if [ -t 0 ]; then
    echo "Do you want to build and push a new Docker image?"
    echo "  yes - Build new image from source code"
    echo "  no  - Skip and use existing image (default)"
    echo ""
    read -p "Build new image? (yes/no, default: no): " BUILD_IMAGE
    BUILD_IMAGE=${BUILD_IMAGE:-no}
  else
    echo "Non-interactive mode detected, skipping image build (set BUILD_IMAGE=yes to override)"
    BUILD_IMAGE="no"
  fi
fi

if [[ "$BUILD_IMAGE" =~ ^[Yy](es)?$ ]]; then
  echo ""
  echo "Building Docker image..."
  BUILD_SCRIPT="$(dirname "$0")/build-and-push-image.sh"

  if [ -f "$BUILD_SCRIPT" ]; then
    echo "Using standalone build script..."
    export AWS_REGION
    export AWS_ACCOUNT
    "$BUILD_SCRIPT"
    PROVISIONING_IMAGE="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/openclaw-provisioning:latest"
    echo -e "${GREEN}✅ Docker image built and pushed${NC}"
  else
    echo -e "${RED}❌ Build script not found: $BUILD_SCRIPT${NC}"
    exit 1
  fi
else
  echo -e "${YELLOW}⚠️  Skipping Docker image build${NC}"
  PROVISIONING_IMAGE="public.ecr.aws/u6t0z4w2/openclaw-provisioning-chinaregion:latest"
  echo "Using existing image: ${PROVISIONING_IMAGE}"
fi

echo ""

# ============================================================================
# Step 5: Deploy PostgreSQL Database
# ============================================================================

echo -e "${BLUE}[5/11] Deploying PostgreSQL Database...${NC}"

PROVISIONING_DIR="$(dirname "$0")/../../eks-pod-service"

kubectl create namespace openclaw-provisioning --dry-run=client -o yaml | kubectl apply -f -

echo "Deploying PostgreSQL StatefulSet..."
kubectl apply -f "$PROVISIONING_DIR/kubernetes/postgres.yaml"

echo "Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=ready pod -l app=postgres -n openclaw-provisioning --timeout=300s || {
  echo -e "${YELLOW}⚠️  PostgreSQL pod not ready yet, checking status...${NC}"
  kubectl get pods -n openclaw-provisioning -l app=postgres
}

echo -e "${GREEN}✅ PostgreSQL deployed${NC}"
echo ""

# ============================================================================
# Step 6: Deploy Provisioning Service
# ============================================================================

echo -e "${BLUE}[6/11] Deploying Provisioning Service...${NC}"

echo "Deploying RBAC..."
kubectl apply -f "$PROVISIONING_DIR/kubernetes/rbac.yaml"

echo "Creating secret..."
kubectl create secret generic openclaw-provisioning-secret \
  -n openclaw-provisioning \
  --from-literal=secret-key="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Deploying provisioning service..."
# Set OpenClaw instance image for provisioning service
if [[ "$AWS_REGION" == cn-* ]]; then
  OPENCLAW_IMG_REPO="public.ecr.aws/u6t0z4w2/openclaw"
  OPENCLAW_IMG_TAG="2026.3.13-1"
else
  OPENCLAW_IMG_REPO=""
  OPENCLAW_IMG_TAG=""
fi
export PROVISIONING_IMAGE BEDROCK_ROLE_ARN CLUSTER_NAME AWS_REGION AWS_ACCOUNT OPENCLAW_IMG_REPO OPENCLAW_IMG_TAG
envsubst < "${TEMPLATE_DIR}/k8s-manifests/provisioning-deployment-db.yaml.tpl" | kubectl apply -f -

kubectl apply -f "$PROVISIONING_DIR/kubernetes/service.yaml"

echo "Waiting for provisioning service to be ready..."
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning --timeout=300s

kubectl apply -f "$PROVISIONING_DIR/kubernetes/hpa.yaml" 2>/dev/null || echo "HPA skipped"

echo -e "${GREEN}✅ Provisioning service deployed${NC}"
echo ""

# ============================================================================
# Step 7: Create Shared Internet-Facing ALB
# ============================================================================

echo -e "${BLUE}[7/11] Creating Shared Internet-Facing ALB...${NC}"
echo "All services (provisioning + OpenClaw instances) share one ALB via Ingress group"

VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text)

PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --region "$AWS_REGION" \
  --query 'Subnets[?MapPublicIpOnLaunch==`true`].SubnetId' \
  --output text | tr '\t' ',')

if [ -z "$PUBLIC_SUBNETS" ]; then
  echo -e "${RED}No public subnets found in VPC${NC}"
  exit 1
fi

echo "Public subnets: $PUBLIC_SUBNETS"

echo "Creating CloudFront security group..."
CLOUDFRONT_SG_NAME="openclaw-alb-cloudfront-only"

EXISTING_SG=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$CLOUDFRONT_SG_NAME" \
  --region "$AWS_REGION" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_SG" ] && [ "$EXISTING_SG" != "None" ]; then
  CLOUDFRONT_SG_ID="$EXISTING_SG"
  echo "CloudFront security group already exists: $CLOUDFRONT_SG_ID"
else
  CLOUDFRONT_SG_ID=$(aws ec2 create-security-group \
    --group-name "$CLOUDFRONT_SG_NAME" \
    --description "Allow traffic only from CloudFront to OpenClaw ALB" \
    --vpc-id "$VPC_ID" \
    --region "$AWS_REGION" \
    --query 'GroupId' \
    --output text)

  CLOUDFRONT_PREFIX_LIST=$(aws ec2 describe-managed-prefix-lists \
    --region "$AWS_REGION" \
    --query "PrefixLists[?PrefixListName=='com.amazonaws.global.cloudfront.origin-facing'].PrefixListId" \
    --output text)

  aws ec2 authorize-security-group-ingress \
    --group-id "$CLOUDFRONT_SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds=[{PrefixListId=$CLOUDFRONT_PREFIX_LIST}]" \
    --region "$AWS_REGION"

  aws ec2 create-tags \
    --resources "$CLOUDFRONT_SG_ID" \
    --tags "Key=Name,Value=$CLOUDFRONT_SG_NAME" \
    --region "$AWS_REGION"
  echo "CloudFront security group created: $CLOUDFRONT_SG_ID"
fi

SHARED_ALB_GROUP="openclaw-shared-instances"

# Get EKS cluster security group (nodes use this SG)
CLUSTER_SG=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
  --output text)
echo "Cluster security group: $CLUSTER_SG"

# Allow CloudFront SG to reach pods on port 8080 (provisioning) and 18789-18790 (OpenClaw gateway)
for PORT_RANGE in "8080 8080" "18789 18790"; do
  FROM_PORT=$(echo $PORT_RANGE | cut -d' ' -f1)
  TO_PORT=$(echo $PORT_RANGE | cut -d' ' -f2)
  aws ec2 authorize-security-group-ingress \
    --group-id "$CLUSTER_SG" \
    --ip-permissions "IpProtocol=tcp,FromPort=$FROM_PORT,ToPort=$TO_PORT,UserIdGroupPairs=[{GroupId=$CLOUDFRONT_SG_ID,Description=ALB-CloudFront-to-pods}]" \
    --region "$AWS_REGION" 2>/dev/null && echo "Added SG rule: CloudFront SG ($CLOUDFRONT_SG_ID) -> Cluster ($CLUSTER_SG) port $FROM_PORT-$TO_PORT" \
    || echo "SG rule already exists for port $FROM_PORT-$TO_PORT"
done

# Delete old standalone Ingress if it exists (we now use shared ALB group)
kubectl delete ingress openclaw-provisioning-ingress -n openclaw-provisioning --ignore-not-found=true

echo "Creating provisioning service Ingress (shared ALB group: $SHARED_ALB_GROUP)..."
# Use specific paths to avoid catch-all conflict with OpenClaw instance /instance/{user_id} routes
export SHARED_ALB_GROUP PUBLIC_SUBNETS CLOUDFRONT_SG_ID
envsubst < "${TEMPLATE_DIR}/k8s-manifests/provisioning-public-ingress-db.yaml.tpl" | kubectl apply -f -

echo "Waiting for shared ALB to provision (up to 3 minutes)..."
for i in $(seq 1 18); do
  ALB_DNS=$(kubectl get ingress openclaw-provisioning-public -n openclaw-provisioning \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [ -n "$ALB_DNS" ]; then
    break
  fi
  echo "  Waiting... ($((i*10))s)"
  sleep 10
done

if [ -z "$ALB_DNS" ]; then
  echo -e "${RED}ALB not provisioned after 3 minutes. Check Ingress events:${NC}"
  kubectl describe ingress openclaw-provisioning-public -n openclaw-provisioning | tail -10
  exit 1
fi

echo -e "${GREEN}Shared internet-facing ALB created${NC}"
echo "ALB DNS: $ALB_DNS"
echo "ALB Group: $SHARED_ALB_GROUP"
echo ""

# ============================================================================
# Step 8: Create CloudFront Distribution
# ============================================================================

echo -e "${BLUE}[8/11] Creating CloudFront Distribution...${NC}"

EXISTING_DIST_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='OpenClaw-${CLUSTER_NAME}'].Id" \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_DIST_ID" ]; then
  echo -e "${YELLOW}⚠️  CloudFront Distribution already exists: $EXISTING_DIST_ID${NC}"
  CLOUDFRONT_DIST_ID="$EXISTING_DIST_ID"
  CLOUDFRONT_DOMAIN=$(aws cloudfront get-distribution \
    --id "$CLOUDFRONT_DIST_ID" \
    --query 'Distribution.DomainName' \
    --output text)

  # Update CloudFront configuration to forward necessary headers for session auth
  # Also update OriginReadTimeout to 60s for WebSocket support
  echo "Updating CloudFront configuration (origin + headers + timeout)..."

  # Get current config and ETag
  aws cloudfront get-distribution-config --id "$CLOUDFRONT_DIST_ID" > /tmp/cf-current.json
  ETAG=$(jq -r '.ETag' /tmp/cf-current.json)

  # Update Origin DomainName (in case ALB DNS changed), Headers, and Timeouts
  jq --arg alb_dns "$ALB_DNS" '
    .DistributionConfig.Origins.Items[0].DomainName = $alb_dns |
    .DistributionConfig.Origins.Items[0].CustomOriginConfig.OriginReadTimeout = 60 |
    .DistributionConfig.Origins.Items[0].CustomOriginConfig.OriginKeepaliveTimeout = 60 |
    .DistributionConfig.DefaultCacheBehavior.ForwardedValues.Headers = {
      "Quantity": 8,
      "Items": [
        "Host",
        "Authorization",
        "Origin",
        "X-Forwarded-For",
        "X-Forwarded-Proto",
        "X-Forwarded-Host",
        "CloudFront-Forwarded-Proto",
        "CloudFront-Is-Desktop-Viewer"
      ]
    } |
    .DistributionConfig
  ' /tmp/cf-current.json > /tmp/cf-updated-config.json

  # Apply update
  aws cloudfront update-distribution \
    --id "$CLOUDFRONT_DIST_ID" \
    --distribution-config file:///tmp/cf-updated-config.json \
    --if-match "$ETAG" > /dev/null

  echo -e "${GREEN}✅ CloudFront configuration updated (origin: $ALB_DNS)${NC}"
  echo "Waiting for CloudFront distribution to deploy..."
  aws cloudfront wait distribution-deployed --id "$CLOUDFRONT_DIST_ID"
else
  echo "Creating CloudFront Distribution..."

  CALLER_REF="openclaw-${CLUSTER_NAME}-$(date +%s)"

  cat > /tmp/cloudfront-config.json <<EOFCF
{
  "CallerReference": "${CALLER_REF}",
  "Comment": "OpenClaw-${CLUSTER_NAME}",
  "Enabled": true,
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "openclaw-alb",
        "DomainName": "${ALB_DNS}",
        "CustomOriginConfig": {
          "HTTPPort": 80,
          "HTTPSPort": 443,
          "OriginProtocolPolicy": "http-only",
          "OriginSslProtocols": {
            "Quantity": 1,
            "Items": ["TLSv1.2"]
          },
          "OriginReadTimeout": 60,
          "OriginKeepaliveTimeout": 60
        }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "openclaw-alb",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 7,
      "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
      "CachedMethods": {
        "Quantity": 2,
        "Items": ["GET", "HEAD"]
      }
    },
    "ForwardedValues": {
      "QueryString": true,
      "Cookies": {
        "Forward": "all"
      },
      "Headers": {
        "Quantity": 8,
        "Items": [
          "Host",
          "Authorization",
          "Origin",
          "X-Forwarded-For",
          "X-Forwarded-Proto",
          "X-Forwarded-Host",
          "CloudFront-Forwarded-Proto",
          "CloudFront-Is-Desktop-Viewer"
        ]
      }
    },
    "MinTTL": 0,
    "DefaultTTL": 0,
    "MaxTTL": 0,
    "Compress": true,
    "TrustedSigners": {
      "Enabled": false,
      "Quantity": 0
    }
  }
}
EOFCF

  CLOUDFRONT_DIST_ID=$(aws cloudfront create-distribution \
    --distribution-config file:///tmp/cloudfront-config.json \
    --query 'Distribution.Id' \
    --output text)

  echo "Waiting for CloudFront distribution to deploy (this may take 10-15 minutes)..."
  aws cloudfront wait distribution-deployed --id "$CLOUDFRONT_DIST_ID"

  CLOUDFRONT_DOMAIN=$(aws cloudfront get-distribution \
    --id "$CLOUDFRONT_DIST_ID" \
    --query 'Distribution.DomainName' \
    --output text)

  echo -e "${GREEN}✅ CloudFront Distribution created${NC}"
fi

echo "CloudFront Domain: $CLOUDFRONT_DOMAIN"
echo ""

# ============================================================================
# Step 9: Update Provisioning Service with CloudFront Config
# ============================================================================

echo -e "${BLUE}[9/11] Updating Provisioning Service with CloudFront configuration...${NC}"

kubectl set env deployment/openclaw-provisioning -n openclaw-provisioning \
  USE_PUBLIC_ALB=true \
  CLOUDFRONT_DOMAIN="$CLOUDFRONT_DOMAIN" \
  CLOUDFRONT_DISTRIBUTION_ID="$CLOUDFRONT_DIST_ID" \
  PUBLIC_ALB_DNS="$ALB_DNS" \
  PUBLIC_ALB_SUBNETS="$PUBLIC_SUBNETS" \
  PUBLIC_ALB_GROUP_NAME="$SHARED_ALB_GROUP" \
  PUBLIC_ALB_SECURITY_GROUPS="$CLOUDFRONT_SG_ID"

echo "Waiting for rollout..."
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning --timeout=300s

echo -e "${GREEN}✅ Provisioning Service fully configured${NC}"
echo ""

# ============================================================================
# Step 10: Run Billing Database Migration
# ============================================================================

echo -e "${BLUE}[10/11] Running billing database migration...${NC}"

BILLING_DIR="$(cd "${SCRIPT_DIR}/../../billing-service"; pwd)"

POSTGRES_POD=$(kubectl get pods -n openclaw-provisioning -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$POSTGRES_POD" ]; then
  echo -e "${RED}❌ PostgreSQL pod not found in openclaw-provisioning namespace${NC}"
  exit 1
fi

echo "Running migration on pod: $POSTGRES_POD"
kubectl cp "$BILLING_DIR/kubernetes/billing-db-migration.sql" \
  "openclaw-provisioning/${POSTGRES_POD}:/tmp/billing-db-migration.sql"

kubectl exec -n openclaw-provisioning "$POSTGRES_POD" -- \
  psql -U openclaw -d openclaw -f /tmp/billing-db-migration.sql

echo -e "${GREEN}✅ Billing database migration complete${NC}"
echo ""

# ============================================================================
# Step 11: Enable Billing Sidecar on Provisioning Service
# ============================================================================

echo -e "${BLUE}[11/11] Enabling billing sidecar on provisioning service...${NC}"

BILLING_SIDECAR_IMAGE="public.ecr.aws/u6t0z4w2/billing-sidecar:latest"

kubectl set env deployment/openclaw-provisioning -n openclaw-provisioning \
  BILLING_SIDECAR_ENABLED=true \
  BILLING_SIDECAR_IMAGE="$BILLING_SIDECAR_IMAGE"

echo "Waiting for rollout..."
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning --timeout=300s

echo -e "${GREEN}✅ Billing sidecar enabled${NC}"
echo ""

# ============================================================================
# Summary
# ============================================================================

echo -e "${GREEN}=== Phase 3 Complete: Full Application Stack Deployed (with Billing) ===${NC}"
echo ""
echo "Deployed Components:"
echo "  ✅ OpenClaw Operator"
echo "  ✅ Bedrock IAM Policy: $BEDROCK_POLICY_ARN"
echo "  ✅ Bedrock IAM Role: $BEDROCK_ROLE_ARN"
echo "  ✅ Pod Identity Association"
echo "  ✅ PostgreSQL Database: postgres (StatefulSet with gp3 PVC)"
echo "  ✅ Docker Image: ${PROVISIONING_IMAGE}"
echo "  ✅ Provisioning Service: openclaw-provisioning (2 replicas)"
echo "  ✅ Shared Internet-facing ALB: $ALB_DNS (group: $SHARED_ALB_GROUP)"
echo "  ✅ CloudFront Distribution: $CLOUDFRONT_DIST_ID"
echo "  ✅ CloudFront Domain: $CLOUDFRONT_DOMAIN"
echo "  ✅ Billing DB Migration: usage_events table created"
echo "  ✅ Billing Sidecar: enabled (image: $BILLING_SIDECAR_IMAGE)"
echo ""
echo "Access URLs:"
echo "  - Public URL: https://$CLOUDFRONT_DOMAIN"
echo "  - Login: https://$CLOUDFRONT_DOMAIN/login"
echo "  - Dashboard: https://$CLOUDFRONT_DOMAIN/dashboard"
echo ""
echo "Billing:"
echo "  - New OpenClaw instances will include a billing-sidecar container"
echo "  - Usage data available via /billing/usage and /billing/hourly endpoints"
echo ""
echo "✅ All components deployed successfully!"
echo ""
