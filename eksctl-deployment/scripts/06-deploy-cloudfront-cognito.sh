#!/bin/bash
# Phase 5: Deploy CloudFront + Cognito + Public ALB Integration
# - Convert ALB to internet-facing
# - Create Cognito User Pool
# - Create CloudFront Distribution
# - Configure integration

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Phase 5: CloudFront + Cognito Deployment ===${NC}"
echo ""

# Get cluster info
CONTEXT=$(kubectl config current-context)
if [[ "$CONTEXT" == arn:aws:eks:* ]]; then
  # Context is ARN format: arn:aws:eks:region:account:cluster/name
  AWS_REGION=$(echo "$CONTEXT" | cut -d':' -f4)
  CLUSTER_NAME=$(echo "$CONTEXT" | cut -d'/' -f2)
else
  # Context is standard format: user@cluster.region.eksctl.io
  CLUSTER_NAME=$(echo "$CONTEXT" | cut -d'@' -f2 | cut -d'.' -f1)
  AWS_REGION=$(echo "$CONTEXT" | grep -o 'us-[a-z]*-[0-9]' || echo "us-east-1")
fi
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Account: $AWS_ACCOUNT"
echo ""

# ============================================================================
# Step 1: Convert ALB to Internet-Facing with CloudFront Security
# ============================================================================

echo -e "${BLUE}[1/5] Converting ALB to Internet-Facing...${NC}"

# Get VPC and subnets
echo "Getting VPC configuration..."
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
  echo "Please ensure VPC has public subnets with MapPublicIpOnLaunch=true"
  exit 1
fi

echo "VPC ID: $VPC_ID"
echo "Public subnets: $PUBLIC_SUBNETS"

# Create CloudFront-only security group
echo "Creating security group for CloudFront access..."
CLOUDFRONT_SG_NAME="openclaw-alb-cloudfront-only"

# Check if security group exists
EXISTING_SG=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$CLOUDFRONT_SG_NAME" \
  --region "$AWS_REGION" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_SG" ] && [ "$EXISTING_SG" != "None" ]; then
  echo -e "${YELLOW}⚠️  Security group already exists: $EXISTING_SG${NC}"
  CLOUDFRONT_SG_ID="$EXISTING_SG"
else
  # Create security group
  CLOUDFRONT_SG_ID=$(aws ec2 create-security-group \
    --group-name "$CLOUDFRONT_SG_NAME" \
    --description "Allow traffic only from CloudFront to OpenClaw ALB" \
    --vpc-id "$VPC_ID" \
    --region "$AWS_REGION" \
    --query 'GroupId' \
    --output text)

  echo "Created security group: $CLOUDFRONT_SG_ID"

  # Get CloudFront managed prefix list
  CLOUDFRONT_PREFIX_LIST=$(aws ec2 describe-managed-prefix-lists \
    --region "$AWS_REGION" \
    --query "PrefixLists[?PrefixListName=='com.amazonaws.global.cloudfront.origin-facing'].PrefixListId" \
    --output text)

  echo "CloudFront prefix list: $CLOUDFRONT_PREFIX_LIST"

  # Allow HTTP from CloudFront (CloudFront → ALB uses HTTP, User → CloudFront uses HTTPS)
  aws ec2 authorize-security-group-ingress \
    --group-id "$CLOUDFRONT_SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds=[{PrefixListId=$CLOUDFRONT_PREFIX_LIST,Description='CloudFront HTTP'}]" \
    --region "$AWS_REGION"

  # Tag security group
  aws ec2 create-tags \
    --resources "$CLOUDFRONT_SG_ID" \
    --tags "Key=Name,Value=$CLOUDFRONT_SG_NAME" "Key=ManagedBy,Value=openclaw-deployment" \
    --region "$AWS_REGION"

  echo -e "${GREEN}✅ CloudFront security group created${NC}"
fi

# Get ALB Controller managed security group (for backend access)
echo "Getting ALB Controller managed security group..."
ALB_MANAGED_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'SecurityGroups[?contains(GroupName, `traffic`)].GroupId' \
  --output text | head -1)

if [ -z "$ALB_MANAGED_SG" ]; then
  echo -e "${RED}❌ ALB Controller managed security group not found${NC}"
  exit 1
fi

echo "ALB managed security group (for backend): $ALB_MANAGED_SG"

# Delete and recreate Ingress (ALB Controller doesn't support changing scheme from internal to internet-facing)
echo "Deleting existing internal Ingress..."
kubectl delete ingress openclaw-provisioning-ingress -n openclaw-provisioning --ignore-not-found=true

echo "Waiting for ALB to be deleted..."
sleep 30

# Create internet-facing Ingress with both security groups
echo "Creating internet-facing Ingress with CloudFront + backend security..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: openclaw-provisioning-ingress
  namespace: openclaw-provisioning
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/subnets: ${PUBLIC_SUBNETS}
    alb.ingress.kubernetes.io/security-groups: ${CLOUDFRONT_SG_ID},${ALB_MANAGED_SG}
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
    alb.ingress.kubernetes.io/success-codes: "200"
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
  labels:
    app: openclaw-provisioning
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /login
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /dashboard
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /static
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /provision
        pathType: Exact
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /status
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /delete
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /health
        pathType: Exact
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
EOF

echo "Waiting for internet-facing ALB to be provisioned..."
sleep 90

# Get ALB DNS name
ALB_DNS=$(kubectl get ingress openclaw-provisioning-ingress -n openclaw-provisioning \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

if [ -z "$ALB_DNS" ]; then
  echo -e "${YELLOW}⚠️  ALB DNS not ready yet, waiting...${NC}"
  sleep 60
  ALB_DNS=$(kubectl get ingress openclaw-provisioning-ingress -n openclaw-provisioning \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
fi

echo -e "${GREEN}✅ ALB configured as internet-facing${NC}"
echo "ALB DNS: $ALB_DNS"
echo ""

# ============================================================================
# Step 2: Create Cognito User Pool
# ============================================================================

echo -e "${BLUE}[2/5] Creating Cognito User Pool...${NC}"

COGNITO_POOL_NAME="openclaw-users-${CLUSTER_NAME}"

# Check if User Pool exists
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
# Step 3: Create CloudFront Distribution
# ============================================================================

echo -e "${BLUE}[3/5] Creating CloudFront Distribution...${NC}"

# Check if distribution exists
EXISTING_DIST_ID=$(aws cloudfront list-distributions \
  --region "$AWS_REGION" \
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

  # Generate unique caller reference
  CALLER_REF="openclaw-${CLUSTER_NAME}-$(date +%s)"

  # Create distribution config
  cat > /tmp/cloudfront-config.json <<EOF
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
EOF

  CLOUDFRONT_DIST_ID=$(aws cloudfront create-distribution \
    --distribution-config file:///tmp/cloudfront-config.json \
    --query 'Distribution.Id' \
    --output text)

  echo "Waiting for CloudFront distribution to deploy..."
  aws cloudfront wait distribution-deployed --id "$CLOUDFRONT_DIST_ID"

  CLOUDFRONT_DOMAIN=$(aws cloudfront get-distribution \
    --id "$CLOUDFRONT_DIST_ID" \
    --query 'Distribution.DomainName' \
    --output text)

  echo -e "${GREEN}✅ CloudFront Distribution created: $CLOUDFRONT_DIST_ID${NC}"
fi

echo "CloudFront Domain: $CLOUDFRONT_DOMAIN"
echo ""

# ============================================================================
# Step 4: Update Provisioning Service Configuration
# ============================================================================

echo -e "${BLUE}[4/5] Updating Provisioning Service Configuration...${NC}"

# Update deployment with CloudFront and Cognito settings
kubectl set env deployment/openclaw-provisioning -n openclaw-provisioning \
  USE_PUBLIC_ALB=true \
  CLOUDFRONT_DOMAIN="$CLOUDFRONT_DOMAIN" \
  CLOUDFRONT_DISTRIBUTION_ID="$CLOUDFRONT_DIST_ID" \
  PUBLIC_ALB_DNS="$ALB_DNS" \
  COGNITO_REGION="$AWS_REGION" \
  COGNITO_USER_POOL_ID="$USER_POOL_ID" \
  COGNITO_CLIENT_ID="$USER_POOL_CLIENT_ID"

echo "Waiting for rollout..."
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning --timeout=300s

echo -e "${GREEN}✅ Provisioning Service updated${NC}"
echo ""

# ============================================================================
# Summary
# ============================================================================

echo -e "${GREEN}=== Phase 5 Complete ===${NC}"
echo ""
echo "Deployed Components:"
echo "  ✅ CloudFront Security Group: $CLOUDFRONT_SG_ID (CloudFront-only access)"
echo "  ✅ Internet-Facing ALB: $ALB_DNS"
echo "  ✅ Cognito User Pool: $USER_POOL_ID"
echo "  ✅ Cognito Client: $USER_POOL_CLIENT_ID"
echo "  ✅ CloudFront Distribution: $CLOUDFRONT_DIST_ID"
echo "  ✅ CloudFront Domain: $CLOUDFRONT_DOMAIN"
echo ""
echo "Access URLs:"
echo "  - CloudFront: https://$CLOUDFRONT_DOMAIN"
echo "  - Login: https://$CLOUDFRONT_DOMAIN/login"
echo "  - Dashboard: https://$CLOUDFRONT_DOMAIN/dashboard"
echo ""
echo "Next Steps:"
echo "  1. Create test user: aws cognito-idp admin-create-user --user-pool-id $USER_POOL_ID --username test@example.com --region $AWS_REGION"
echo "  2. Access UI: https://$CLOUDFRONT_DOMAIN/login"
echo "  3. Test provisioning via dashboard"
echo ""
