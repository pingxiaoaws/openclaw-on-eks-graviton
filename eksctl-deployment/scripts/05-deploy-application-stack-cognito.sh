#!/bin/bash
export AWS_PAGER=""
# Phase 3: Deploy Complete Application Stack
# - OpenClaw Operator
# - Bedrock IAM Role & Pod Identity
# - Cognito User Pool & Client
# - Build & Push Docker Image
# - Provisioning Service (with full config)
# - Internet-facing ALB
# - CloudFront Distribution

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

echo -e "${BLUE}=== Phase 3: Complete Application Stack Deployment ===${NC}"
echo ""

# Get cluster info
CONTEXT=$(kubectl config current-context)
if [[ "$CONTEXT" == arn:aws:eks:* ]]; then
  AWS_REGION=$(echo "$CONTEXT" | cut -d':' -f4)
  CLUSTER_NAME=$(echo "$CONTEXT" | cut -d'/' -f2)
else
  CLUSTER_NAME=$(echo "$CONTEXT" | cut -d'@' -f2 | cut -d'.' -f1)
  AWS_REGION=$(echo "$CONTEXT" | grep -o 'us-[a-z]*-[0-9]' || echo "us-east-1")
fi
AWS_ACCOUNT=${AWS_ACCOUNT_ID:-${AWS_ACCOUNT:-$(aws sts get-caller-identity --query Account --output text)}}

echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Account: $AWS_ACCOUNT"
echo ""

# ============================================================================
# Step 1: Install OpenClaw Operator
# ============================================================================

echo -e "${BLUE}[1/9] Installing OpenClaw Operator...${NC}"

OPERATOR_DIR="$(dirname "$0")/../../k8s-operator"
if [ ! -d "$OPERATOR_DIR" ]; then
  echo -e "${YELLOW}⚠️  Operator directory not found: $OPERATOR_DIR${NC}"
  echo "Skipping operator installation (deploy manually later)"
else
  cd "$OPERATOR_DIR"

  if [ -d "charts/openclaw-operator" ]; then
    helm upgrade --install openclaw-operator charts/openclaw-operator \
      --namespace openclaw-operator-system \
      --create-namespace \
      --wait
    echo -e "${GREEN}✅ OpenClaw Operator installed${NC}"
  else
    echo "Using kustomize deployment..."
    kubectl apply -k config/default
    echo -e "${GREEN}✅ OpenClaw Operator installed (kustomize)${NC}"
  fi

  cd - > /dev/null
fi

echo ""

# ============================================================================
# Step 2: Create Bedrock IAM Policy and Role
# ============================================================================

echo -e "${BLUE}[2/9] Creating Bedrock IAM Role...${NC}"

BEDROCK_POLICY_NAME="OpenClawBedrockAccess"
BEDROCK_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT}:policy/${BEDROCK_POLICY_NAME}"

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
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": "arn:aws:bedrock:*:*:model/*"
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
# Step 3: Create Pod Identity Association
# ============================================================================

echo -e "${BLUE}[3/9] Creating Pod Identity Association...${NC}"

BEDROCK_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT}:role/${BEDROCK_ROLE_NAME}"

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
# Step 4: Create Cognito User Pool
# ============================================================================

echo -e "${BLUE}[4/9] Creating Cognito User Pool...${NC}"

COGNITO_POOL_NAME="openclaw-users-${CLUSTER_NAME}"

EXISTING_POOL_ID=$(aws cognito-idp list-user-pools \
  --max-results 60 \
  --region "$AWS_REGION" \
  --query "UserPools[?Name=='${COGNITO_POOL_NAME}'].Id" \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_POOL_ID" ]; then
  echo -e "${YELLOW}⚠️  Cognito User Pool already exists: $EXISTING_POOL_ID${NC}"
  USER_POOL_ID="$EXISTING_POOL_ID"
else
  echo "Creating Cognito User Pool..."
  USER_POOL_ID=$(aws cognito-idp create-user-pool \
    --pool-name "$COGNITO_POOL_NAME" \
    --region "$AWS_REGION" \
    --policies "PasswordPolicy={MinimumLength=8,RequireUppercase=true,RequireLowercase=true,RequireNumbers=true,RequireSymbols=false}" \
    --auto-verified-attributes email \
    --username-attributes email \
    --schema Name=email,AttributeDataType=String,Mutable=true,Required=true \
    --query 'UserPool.Id' \
    --output text)

  echo -e "${GREEN}✅ Cognito User Pool created: $USER_POOL_ID${NC}"
fi

# Create User Pool Client
COGNITO_CLIENT_NAME="openclaw-web-client"

EXISTING_CLIENT_ID=$(aws cognito-idp list-user-pool-clients \
  --user-pool-id "$USER_POOL_ID" \
  --region "$AWS_REGION" \
  --query "UserPoolClients[?ClientName=='${COGNITO_CLIENT_NAME}'].ClientId" \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_CLIENT_ID" ]; then
  echo -e "${YELLOW}⚠️  Cognito Client already exists: $EXISTING_CLIENT_ID${NC}"
  USER_POOL_CLIENT_ID="$EXISTING_CLIENT_ID"
else
  echo "Creating Cognito User Pool Client..."
  USER_POOL_CLIENT_ID=$(aws cognito-idp create-user-pool-client \
    --user-pool-id "$USER_POOL_ID" \
    --client-name "$COGNITO_CLIENT_NAME" \
    --region "$AWS_REGION" \
    --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
    --query 'UserPoolClient.ClientId' \
    --output text)

  echo -e "${GREEN}✅ Cognito Client created: $USER_POOL_CLIENT_ID${NC}"
fi

echo ""

# ============================================================================
# Step 5: Build and Push Docker Image
# ============================================================================

echo -e "${BLUE}[5/9] Building and pushing Docker image...${NC}"

BUILD_SCRIPT="$(dirname "$0")/build-and-push-image.sh"

if [ -f "$BUILD_SCRIPT" ]; then
  echo "Using standalone build script..."
  export AWS_REGION
  export AWS_ACCOUNT
  "$BUILD_SCRIPT"
  PROVISIONING_IMAGE="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/openclaw-provisioning:latest"
else
  echo -e "${RED}❌ Build script not found: $BUILD_SCRIPT${NC}"
  exit 1
fi

echo ""

# ============================================================================
# Step 6: Deploy Provisioning Service (with Cognito config)
# ============================================================================

echo -e "${BLUE}[6/9] Deploying Provisioning Service...${NC}"

PROVISIONING_DIR="$(dirname "$0")/../../open-claw-operator-on-EKS-kata/eks-pod-service"

kubectl create namespace openclaw-provisioning --dry-run=client -o yaml | kubectl apply -f -

echo "Deploying RBAC..."
kubectl apply -f "$PROVISIONING_DIR/kubernetes/rbac.yaml"

echo "Creating secret..."
kubectl create secret generic openclaw-provisioning-secret \
  -n openclaw-provisioning \
  --from-literal=secret-key="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Deploying provisioning service with Cognito configuration..."
export PROVISIONING_IMAGE BEDROCK_ROLE_ARN CLUSTER_NAME AWS_REGION AWS_ACCOUNT USER_POOL_ID USER_POOL_CLIENT_ID
envsubst < "${TEMPLATE_DIR}/k8s-manifests/provisioning-deployment-cognito.yaml.tpl" | kubectl apply -f -

kubectl apply -f "$PROVISIONING_DIR/kubernetes/service.yaml"

# Deploy initial internal ALB (will be converted to internet-facing later)
echo "Deploying initial internal ALB..."
kubectl apply -f "${TEMPLATE_DIR}/k8s-manifests/provisioning-internal-ingress.yaml"

echo "Waiting for provisioning service to be ready..."
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning --timeout=300s

kubectl apply -f "$PROVISIONING_DIR/kubernetes/hpa.yaml" 2>/dev/null || echo "HPA skipped"

echo -e "${GREEN}✅ Provisioning service deployed with Cognito configuration${NC}"
echo ""

# ============================================================================
# Step 7: Convert ALB to Internet-Facing
# ============================================================================

echo -e "${BLUE}[7/9] Converting ALB to Internet-Facing...${NC}"

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
  echo -e "${RED}❌ No public subnets found in VPC${NC}"
  exit 1
fi

echo "Creating CloudFront security group..."
CLOUDFRONT_SG_NAME="openclaw-alb-cloudfront-only"

EXISTING_SG=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$CLOUDFRONT_SG_NAME" \
  --region "$AWS_REGION" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_SG" ] && [ "$EXISTING_SG" != "None" ]; then
  CLOUDFRONT_SG_ID="$EXISTING_SG"
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
fi

ALB_MANAGED_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'SecurityGroups[?contains(GroupName, `traffic`)].GroupId' \
  --output text | head -1)

echo "Deleting internal ALB..."
kubectl delete ingress openclaw-provisioning-ingress -n openclaw-provisioning --ignore-not-found=true
sleep 30

echo "Creating internet-facing ALB..."
export PUBLIC_SUBNETS CLOUDFRONT_SG_ID ALB_MANAGED_SG
envsubst < "${TEMPLATE_DIR}/k8s-manifests/provisioning-public-ingress-cognito.yaml.tpl" | kubectl apply -f -

sleep 90

ALB_DNS=$(kubectl get ingress openclaw-provisioning-ingress -n openclaw-provisioning \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

if [ -z "$ALB_DNS" ]; then
  sleep 60
  ALB_DNS=$(kubectl get ingress openclaw-provisioning-ingress -n openclaw-provisioning \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
fi

echo -e "${GREEN}✅ ALB converted to internet-facing${NC}"
echo "ALB DNS: $ALB_DNS"
echo ""

# ============================================================================
# Step 8: Create CloudFront Distribution
# ============================================================================

echo -e "${BLUE}[8/9] Creating CloudFront Distribution...${NC}"

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
          }
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
        "Quantity": 3,
        "Items": ["Host", "Authorization", "Origin"]
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

echo -e "${BLUE}[9/9] Updating Provisioning Service with CloudFront configuration...${NC}"

kubectl set env deployment/openclaw-provisioning -n openclaw-provisioning \
  USE_PUBLIC_ALB=true \
  CLOUDFRONT_DOMAIN="$CLOUDFRONT_DOMAIN" \
  CLOUDFRONT_DISTRIBUTION_ID="$CLOUDFRONT_DIST_ID" \
  PUBLIC_ALB_DNS="$ALB_DNS"

echo "Waiting for rollout..."
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning --timeout=300s

echo -e "${GREEN}✅ Provisioning Service fully configured${NC}"
echo ""

# ============================================================================
# Summary
# ============================================================================

echo -e "${GREEN}=== Phase 3 Complete: Full Application Stack Deployed ===${NC}"
echo ""
echo "🎯 Deployed Components:"
echo "  ✅ OpenClaw Operator"
echo "  ✅ Bedrock IAM Policy: $BEDROCK_POLICY_ARN"
echo "  ✅ Bedrock IAM Role: $BEDROCK_ROLE_ARN"
echo "  ✅ Pod Identity Association"
echo "  ✅ Cognito User Pool: $USER_POOL_ID"
echo "  ✅ Cognito Client: $USER_POOL_CLIENT_ID"
echo "  ✅ Docker Image: ${PROVISIONING_IMAGE:-public.ecr.aws/u6t0z4w2/openclaw-provisioning:latest}"
echo "  ✅ Provisioning Service: openclaw-provisioning (2 replicas)"
echo "  ✅ Internet-facing ALB: $ALB_DNS"
echo "  ✅ CloudFront Distribution: $CLOUDFRONT_DIST_ID"
echo "  ✅ CloudFront Domain: $CLOUDFRONT_DOMAIN"
echo ""
echo "🌐 Access URLs:"
echo "  - Public URL: https://$CLOUDFRONT_DOMAIN"
echo "  - Login: https://$CLOUDFRONT_DOMAIN/login"
echo "  - Dashboard: https://$CLOUDFRONT_DOMAIN/dashboard"
echo ""
echo "👤 Create Test User:"
echo "  aws cognito-idp admin-create-user \\"
echo "    --user-pool-id $USER_POOL_ID \\"
echo "    --username test@example.com \\"
echo "    --temporary-password 'TempPass123!' \\"
echo "    --region $AWS_REGION"
echo ""
echo "✅ All components deployed successfully!"
echo ""
