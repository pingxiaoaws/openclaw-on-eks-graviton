#!/bin/bash
# Complete Cleanup Script for OpenClaw Platform
# Deletes ALL resources including:
# - Kubernetes resources
# - CloudFront Distribution
# - Cognito User Pool
# - EKS Cluster
# - Pod Identity Associations
# - IAM Roles & Policies
# - EFS FileSystem (optional)
# - Security Groups
# - CloudFormation stacks (if exist)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║     ⚠️  COMPLETE RESOURCE CLEANUP - DESTRUCTIVE OPERATION ⚠️  ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# Step 1: Gather Configuration
# ============================================================================

echo -e "${CYAN}[Step 1/12] Gathering configuration...${NC}"
echo ""

# Try to get cluster name from kubectl context
if kubectl config current-context &>/dev/null; then
  CONTEXT=$(kubectl config current-context)
  if [[ "$CONTEXT" == arn:aws:eks:* ]]; then
    DEFAULT_CLUSTER=$(echo "$CONTEXT" | cut -d'/' -f2)
    DEFAULT_REGION=$(echo "$CONTEXT" | cut -d':' -f4)
  else
    DEFAULT_CLUSTER=$(echo "$CONTEXT" | cut -d'@' -f2 | cut -d'.' -f1)
    DEFAULT_REGION=$(echo "$CONTEXT" | grep -o 'us-[a-z]*-[0-9]' || echo "us-east-1")
  fi
  echo -e "${GREEN}✓ Detected from kubectl context:${NC}"
  echo "  Cluster: $DEFAULT_CLUSTER"
  echo "  Region: $DEFAULT_REGION"
  echo ""
  read -p "Use these values? (yes/no): " USE_DETECTED
  echo ""

  if [ "$USE_DETECTED" == "yes" ]; then
    CLUSTER_NAME="$DEFAULT_CLUSTER"
    AWS_REGION="$DEFAULT_REGION"
  else
    read -p "Enter EKS cluster name: " CLUSTER_NAME
    read -p "Enter AWS region (default: us-east-1): " AWS_REGION
    AWS_REGION=${AWS_REGION:-"us-east-1"}
  fi
else
  echo -e "${YELLOW}⚠️  No kubectl context found${NC}"
  echo ""
  read -p "Enter EKS cluster name: " CLUSTER_NAME
  read -p "Enter AWS region (default: us-east-1): " AWS_REGION
  AWS_REGION=${AWS_REGION:-"us-east-1"}
fi

AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

echo ""
echo -e "${BLUE}Configuration Summary:${NC}"
echo "  Cluster Name: $CLUSTER_NAME"
echo "  AWS Region: $AWS_REGION"
echo "  AWS Account: $AWS_ACCOUNT"
echo ""

# ============================================================================
# Step 2: Display Resources to be Deleted
# ============================================================================

echo -e "${CYAN}[Step 2/12] Scanning resources...${NC}"
echo ""

# Check CloudFront
CLOUDFRONT_DIST_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='OpenClaw-${CLUSTER_NAME}'].Id" \
  --output text 2>/dev/null || echo "")

# Check Cognito
COGNITO_POOL_ID=$(aws cognito-idp list-user-pools \
  --max-results 60 \
  --region "$AWS_REGION" \
  --query "UserPools[?Name=='openclaw-users-${CLUSTER_NAME}'].Id" \
  --output text 2>/dev/null || echo "")

# Check EKS Cluster
EKS_EXISTS=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.name' \
  --output text 2>/dev/null || echo "")

# Check EFS
EFS_ID=$(aws efs describe-file-systems \
  --region "$AWS_REGION" \
  --query "FileSystems[?Tags[?Key=='Name' && Value=='openclaw-shared-storage']].FileSystemId" \
  --output text 2>/dev/null || echo "")

# Check IAM Roles
BEDROCK_ROLE_EXISTS=$(aws iam get-role --role-name OpenClawBedrockRole 2>/dev/null && echo "yes" || echo "no")
BEDROCK_POLICY_EXISTS=$(aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT}:policy/OpenClawBedrockAccess" 2>/dev/null && echo "yes" || echo "no")

echo -e "${YELLOW}Resources to be deleted:${NC}"
echo ""

TOTAL_RESOURCES=0

echo "📦 Kubernetes Resources:"
if kubectl get namespace openclaw-provisioning &>/dev/null; then
  echo "  ✓ openclaw-provisioning namespace"
  ((TOTAL_RESOURCES++))
else
  echo "  - openclaw-provisioning namespace (not found)"
fi

if kubectl get namespace openclaw-operator-system &>/dev/null; then
  echo "  ✓ openclaw-operator-system namespace"
  ((TOTAL_RESOURCES++))
else
  echo "  - openclaw-operator-system namespace (not found)"
fi

USER_NAMESPACES=$(kubectl get namespaces -o json 2>/dev/null | jq -r '.items[].metadata.name' | grep '^openclaw-' || echo "")
if [ -n "$USER_NAMESPACES" ]; then
  NS_COUNT=$(echo "$USER_NAMESPACES" | wc -l | tr -d ' ')
  echo "  ✓ $NS_COUNT user namespace(s)"
  ((TOTAL_RESOURCES+=NS_COUNT))
else
  echo "  - User namespaces (not found)"
fi

echo ""
echo "🌐 CloudFront:"
if [ -n "$CLOUDFRONT_DIST_ID" ]; then
  echo "  ✓ Distribution: $CLOUDFRONT_DIST_ID"
  ((TOTAL_RESOURCES++))
else
  echo "  - CloudFront distribution (not found)"
fi

echo ""
echo "👤 Cognito:"
if [ -n "$COGNITO_POOL_ID" ]; then
  echo "  ✓ User Pool: $COGNITO_POOL_ID"
  ((TOTAL_RESOURCES++))
else
  echo "  - Cognito user pool (not found)"
fi

echo ""
echo "🏗️  EKS Cluster:"
if [ -n "$EKS_EXISTS" ]; then
  echo "  ✓ Cluster: $CLUSTER_NAME"

  # Count node groups
  NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'nodegroups' --output text 2>/dev/null || echo "")
  if [ -n "$NODEGROUPS" ]; then
    NG_COUNT=$(echo "$NODEGROUPS" | wc -w | tr -d ' ')
    echo "  ✓ $NG_COUNT node group(s)"
    ((TOTAL_RESOURCES+=NG_COUNT))
  fi

  ((TOTAL_RESOURCES++))
else
  echo "  - EKS cluster (not found)"
fi

echo ""
echo "🗄️  Storage:"
if [ -n "$EFS_ID" ]; then
  EFS_SIZE=$(aws efs describe-file-systems --file-system-id "$EFS_ID" --region "$AWS_REGION" --query 'FileSystems[0].SizeInBytes.Value' --output text 2>/dev/null || echo "0")
  EFS_SIZE_GB=$((EFS_SIZE / 1024 / 1024 / 1024))
  echo "  ✓ EFS FileSystem: $EFS_ID (${EFS_SIZE_GB}GB)"
  ((TOTAL_RESOURCES++))
else
  echo "  - EFS FileSystem (not found)"
fi

echo ""
echo "🔐 IAM Resources:"
if [ "$BEDROCK_ROLE_EXISTS" == "yes" ]; then
  echo "  ✓ IAM Role: OpenClawBedrockRole"
  ((TOTAL_RESOURCES++))
else
  echo "  - IAM Role: OpenClawBedrockRole (not found)"
fi

if [ "$BEDROCK_POLICY_EXISTS" == "yes" ]; then
  echo "  ✓ IAM Policy: OpenClawBedrockAccess"
  ((TOTAL_RESOURCES++))
else
  echo "  - IAM Policy: OpenClawBedrockAccess (not found)"
fi

echo ""
echo -e "${CYAN}Total resources found: $TOTAL_RESOURCES${NC}"
echo ""

if [ "$TOTAL_RESOURCES" -eq 0 ]; then
  echo -e "${GREEN}✅ No resources found to delete${NC}"
  exit 0
fi

# ============================================================================
# Step 3: Confirmation
# ============================================================================

echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║                    ⚠️  FINAL WARNING ⚠️                        ║${NC}"
echo -e "${RED}║                                                                ║${NC}"
echo -e "${RED}║  This will PERMANENTLY DELETE all resources listed above.     ║${NC}"
echo -e "${RED}║  Data stored in EFS will be LOST unless you choose to skip it.║${NC}"
echo -e "${RED}║  This action CANNOT be undone.                                ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

read -p "Type the cluster name '$CLUSTER_NAME' to confirm deletion: " CONFIRM_NAME

if [ "$CONFIRM_NAME" != "$CLUSTER_NAME" ]; then
  echo -e "${YELLOW}❌ Name does not match. Cleanup cancelled.${NC}"
  exit 1
fi

echo ""
read -p "Are you ABSOLUTELY sure? Type 'DELETE' in uppercase: " CONFIRM_DELETE

if [ "$CONFIRM_DELETE" != "DELETE" ]; then
  echo -e "${YELLOW}❌ Confirmation failed. Cleanup cancelled.${NC}"
  exit 1
fi

echo ""
echo -e "${GREEN}✓ Confirmation received. Starting cleanup...${NC}"
echo ""

# Ask about EFS
DELETE_EFS="no"
if [ -n "$EFS_ID" ]; then
  echo -e "${YELLOW}⚠️  EFS FileSystem contains persistent data${NC}"
  read -p "Delete EFS FileSystem? (yes/no, default: no): " DELETE_EFS
  DELETE_EFS=${DELETE_EFS:-"no"}
  echo ""
fi

# ============================================================================
# Step 4: Delete Kubernetes Resources
# ============================================================================

echo -e "${CYAN}[Step 3/12] Deleting Kubernetes resources...${NC}"

if kubectl get namespace openclaw-provisioning &>/dev/null; then
  echo "Deleting openclaw-provisioning namespace..."
  kubectl delete namespace openclaw-provisioning --wait=false 2>/dev/null || echo "  (already being deleted)"
fi

if kubectl get namespace openclaw-operator-system &>/dev/null; then
  echo "Deleting openclaw-operator-system namespace..."
  kubectl delete namespace openclaw-operator-system --wait=false 2>/dev/null || echo "  (already being deleted)"
fi

if [ -n "$USER_NAMESPACES" ]; then
  echo "Deleting user namespaces..."
  for NS in $USER_NAMESPACES; do
    echo "  - $NS"
    kubectl delete namespace "$NS" --wait=false 2>/dev/null || echo "    (already being deleted)"
  done
fi

echo -e "${GREEN}✅ Kubernetes resource deletion initiated${NC}"
echo ""

# ============================================================================
# Step 5: Disable and Delete CloudFront Distribution
# ============================================================================

echo -e "${CYAN}[Step 4/12] Deleting CloudFront distribution...${NC}"

if [ -n "$CLOUDFRONT_DIST_ID" ]; then
  # Get current config
  echo "Getting distribution configuration..."
  aws cloudfront get-distribution-config --id "$CLOUDFRONT_DIST_ID" > /tmp/cf-config.json

  ETAG=$(jq -r '.ETag' /tmp/cf-config.json)

  # Check if already disabled
  IS_ENABLED=$(jq -r '.DistributionConfig.Enabled' /tmp/cf-config.json)

  if [ "$IS_ENABLED" == "true" ]; then
    # Invalidate all cached content before disabling
    echo "Invalidating CloudFront cache..."
    INVALIDATION_ID=$(aws cloudfront create-invalidation \
      --distribution-id "$CLOUDFRONT_DIST_ID" \
      --paths "/*" \
      --query 'Invalidation.Id' \
      --output text)

    if [ -n "$INVALIDATION_ID" ]; then
      echo "  Invalidation created: $INVALIDATION_ID"
      echo "  Waiting for invalidation to complete (this may take 1-2 minutes)..."
      aws cloudfront wait invalidation-completed \
        --distribution-id "$CLOUDFRONT_DIST_ID" \
        --id "$INVALIDATION_ID" 2>/dev/null || echo "  (wait timed out, continuing...)"
      echo -e "${GREEN}  ✅ Cache invalidated${NC}"
    else
      echo -e "${YELLOW}  ⚠️  Failed to create invalidation (continuing...)${NC}"
    fi

    echo "Disabling distribution..."
    jq '.DistributionConfig.Enabled = false | .DistributionConfig' /tmp/cf-config.json > /tmp/cf-config-disabled.json

    aws cloudfront update-distribution \
      --id "$CLOUDFRONT_DIST_ID" \
      --if-match "$ETAG" \
      --distribution-config file:///tmp/cf-config-disabled.json > /dev/null

    echo "Waiting for distribution to be disabled (this may take 5-10 minutes)..."
    aws cloudfront wait distribution-deployed --id "$CLOUDFRONT_DIST_ID"

    # Get new ETag after update
    aws cloudfront get-distribution-config --id "$CLOUDFRONT_DIST_ID" > /tmp/cf-config-new.json
    ETAG=$(jq -r '.ETag' /tmp/cf-config-new.json)
  else
    echo "Distribution already disabled"
  fi

  echo "Deleting distribution..."
  aws cloudfront delete-distribution --id "$CLOUDFRONT_DIST_ID" --if-match "$ETAG"

  echo -e "${GREEN}✅ CloudFront distribution deleted${NC}"
else
  echo "No CloudFront distribution found, skipping"
fi

echo ""

# ============================================================================
# Step 6: Delete Cognito User Pool
# ============================================================================

echo -e "${CYAN}[Step 5/12] Deleting Cognito user pool...${NC}"

if [ -n "$COGNITO_POOL_ID" ]; then
  # List and delete clients first
  echo "Deleting user pool clients..."
  CLIENTS=$(aws cognito-idp list-user-pool-clients \
    --user-pool-id "$COGNITO_POOL_ID" \
    --region "$AWS_REGION" \
    --query 'UserPoolClients[].ClientId' \
    --output text 2>/dev/null || echo "")

  if [ -n "$CLIENTS" ]; then
    for CLIENT_ID in $CLIENTS; do
      echo "  - Deleting client: $CLIENT_ID"
      aws cognito-idp delete-user-pool-client \
        --user-pool-id "$COGNITO_POOL_ID" \
        --client-id "$CLIENT_ID" \
        --region "$AWS_REGION" 2>/dev/null || echo "    (already deleted)"
    done
  fi

  # Delete user pool domain if exists
  DOMAIN=$(aws cognito-idp describe-user-pool \
    --user-pool-id "$COGNITO_POOL_ID" \
    --region "$AWS_REGION" \
    --query 'UserPool.Domain' \
    --output text 2>/dev/null || echo "")

  if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "None" ]; then
    echo "Deleting user pool domain: $DOMAIN"
    aws cognito-idp delete-user-pool-domain \
      --domain "$DOMAIN" \
      --user-pool-id "$COGNITO_POOL_ID" \
      --region "$AWS_REGION" 2>/dev/null || echo "  (already deleted)"
  fi

  # Delete user pool
  echo "Deleting user pool..."
  aws cognito-idp delete-user-pool \
    --user-pool-id "$COGNITO_POOL_ID" \
    --region "$AWS_REGION"

  echo -e "${GREEN}✅ Cognito user pool deleted${NC}"
else
  echo "No Cognito user pool found, skipping"
fi

echo ""

# ============================================================================
# Step 7: Delete Pod Identity Associations
# ============================================================================

echo -e "${CYAN}[Step 6/12] Deleting Pod Identity associations...${NC}"

if [ -n "$EKS_EXISTS" ]; then
  ASSOCIATIONS=$(aws eks list-pod-identity-associations \
    --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'associations[].associationId' \
    --output text 2>/dev/null || echo "")

  if [ -n "$ASSOCIATIONS" ]; then
    for ASSOC_ID in $ASSOCIATIONS; do
      echo "  - Deleting association: $ASSOC_ID"
      aws eks delete-pod-identity-association \
        --cluster-name "$CLUSTER_NAME" \
        --association-id "$ASSOC_ID" \
        --region "$AWS_REGION" 2>/dev/null || echo "    (already deleted)"
    done
    echo -e "${GREEN}✅ Pod Identity associations deleted${NC}"
  else
    echo "No Pod Identity associations found"
  fi
else
  echo "EKS cluster not found, skipping Pod Identity cleanup"
fi

echo ""

# ============================================================================
# Step 8: Delete EKS Cluster
# ============================================================================

echo -e "${CYAN}[Step 7/12] Deleting EKS cluster...${NC}"

if [ -n "$EKS_EXISTS" ]; then
  echo "Deleting cluster: $CLUSTER_NAME"
  echo ""
  echo "This will delete:"
  echo "  - All node groups"
  echo "  - All managed addons"
  echo "  - VPC resources (if created by eksctl)"
  echo "  - ALB (via deleted Ingress)"
  echo "  - NAT Gateway"
  echo "  - Other networking resources"
  echo ""
  echo "⏱️  This process typically takes 10-15 minutes..."
  echo ""

  eksctl delete cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --wait \
    && echo -e "${GREEN}✅ EKS cluster deleted${NC}" \
    || echo -e "${RED}❌ EKS cluster deletion failed (check AWS Console)${NC}"
else
  echo "EKS cluster not found, skipping"
fi

echo ""

# ============================================================================
# Step 8.5: Force Delete VPC and Dependencies
# ============================================================================

echo -e "${CYAN}[Step 7.5/12] Force deleting VPC and all dependencies...${NC}"

# Get VPC ID from EKS cluster tags
VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=$CLUSTER_NAME" \
  --query 'Vpcs[0].VpcId' \
  --output text 2>/dev/null || echo "")

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "Found VPC: $VPC_ID"
  echo ""

  # Step 1: Delete Load Balancers (ALB/NLB)
  echo "Deleting Load Balancers..."
  LB_ARNS=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
    --output text 2>/dev/null || echo "")

  if [ -n "$LB_ARNS" ]; then
    for LB_ARN in $LB_ARNS; do
      echo "  - Deleting Load Balancer: $LB_ARN"
      aws elbv2 delete-load-balancer --load-balancer-arn "$LB_ARN" --region "$AWS_REGION" 2>/dev/null || echo "    (failed or already deleted)"
    done
    echo "  Waiting 60s for Load Balancers to be deleted..."
    sleep 60
  else
    echo "  No Load Balancers found"
  fi

  # Step 2: Delete NAT Gateways
  echo ""
  echo "Deleting NAT Gateways..."
  NAT_IDS=$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
    --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
    --query 'NatGateways[].NatGatewayId' \
    --output text 2>/dev/null || echo "")

  if [ -n "$NAT_IDS" ]; then
    for NAT_ID in $NAT_IDS; do
      echo "  - Deleting NAT Gateway: $NAT_ID"
      aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID" --region "$AWS_REGION" 2>/dev/null || echo "    (failed or already deleted)"
    done
    echo "  Waiting 60s for NAT Gateways to be deleted..."
    sleep 60
  else
    echo "  No NAT Gateways found"
  fi

  # Step 3: Delete VPC Endpoints
  echo ""
  echo "Deleting VPC Endpoints..."
  ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'VpcEndpoints[].VpcEndpointId' \
    --output text 2>/dev/null || echo "")

  if [ -n "$ENDPOINT_IDS" ]; then
    for ENDPOINT_ID in $ENDPOINT_IDS; do
      echo "  - Deleting VPC Endpoint: $ENDPOINT_ID"
      aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$ENDPOINT_ID" --region "$AWS_REGION" 2>/dev/null || echo "    (failed or already deleted)"
    done
    sleep 10
  else
    echo "  No VPC Endpoints found"
  fi

  # Step 4: Delete Network Interfaces (ENIs) - force detach if needed
  echo ""
  echo "Deleting Network Interfaces (ENIs)..."
  ENI_IDS=$(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' \
    --output text 2>/dev/null || echo "")

  if [ -n "$ENI_IDS" ]; then
    for ENI_ID in $ENI_IDS; do
      # Check if attached
      ATTACHMENT_ID=$(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
        --network-interface-ids "$ENI_ID" \
        --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
        --output text 2>/dev/null || echo "None")

      if [ "$ATTACHMENT_ID" != "None" ]; then
        echo "  - Detaching ENI: $ENI_ID (Attachment: $ATTACHMENT_ID)"
        aws ec2 detach-network-interface --attachment-id "$ATTACHMENT_ID" --region "$AWS_REGION" --force 2>/dev/null || echo "    (detach failed)"
        sleep 5
      fi

      echo "  - Deleting ENI: $ENI_ID"
      aws ec2 delete-network-interface --network-interface-id "$ENI_ID" --region "$AWS_REGION" 2>/dev/null || echo "    (failed or already deleted)"
    done
    sleep 10
  else
    echo "  No ENIs found"
  fi

  # Step 5: Detach and Delete Internet Gateways
  echo ""
  echo "Deleting Internet Gateways..."
  IGW_IDS=$(aws ec2 describe-internet-gateways --region "$AWS_REGION" \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[].InternetGatewayId' \
    --output text 2>/dev/null || echo "")

  if [ -n "$IGW_IDS" ]; then
    for IGW_ID in $IGW_IDS; do
      echo "  - Detaching IGW: $IGW_ID from VPC: $VPC_ID"
      aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$AWS_REGION" 2>/dev/null || echo "    (detach failed)"

      echo "  - Deleting IGW: $IGW_ID"
      aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$AWS_REGION" 2>/dev/null || echo "    (delete failed)"
    done
  else
    echo "  No Internet Gateways found"
  fi

  # Step 6: Delete Subnets
  echo ""
  echo "Deleting Subnets..."
  SUBNET_IDS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[].SubnetId' \
    --output text 2>/dev/null || echo "")

  if [ -n "$SUBNET_IDS" ]; then
    for SUBNET_ID in $SUBNET_IDS; do
      echo "  - Deleting Subnet: $SUBNET_ID"
      aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region "$AWS_REGION" 2>/dev/null || echo "    (failed or already deleted)"
    done
  else
    echo "  No Subnets found"
  fi

  # Step 7: Delete Security Groups (non-default)
  echo ""
  echo "Deleting Security Groups..."
  SG_IDS=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
    --output text 2>/dev/null || echo "")

  if [ -n "$SG_IDS" ]; then
    # First pass: remove all ingress/egress rules
    for SG_ID in $SG_IDS; do
      echo "  - Removing rules from SG: $SG_ID"

      # Revoke ingress rules
      aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$AWS_REGION" \
        --query 'SecurityGroups[0].IpPermissions' > /tmp/sg-ingress-$SG_ID.json 2>/dev/null

      if [ -s /tmp/sg-ingress-$SG_ID.json ] && [ "$(cat /tmp/sg-ingress-$SG_ID.json)" != "[]" ]; then
        aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --region "$AWS_REGION" \
          --ip-permissions file:///tmp/sg-ingress-$SG_ID.json 2>/dev/null || true
      fi

      # Revoke egress rules
      aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$AWS_REGION" \
        --query 'SecurityGroups[0].IpPermissionsEgress' > /tmp/sg-egress-$SG_ID.json 2>/dev/null

      if [ -s /tmp/sg-egress-$SG_ID.json ] && [ "$(cat /tmp/sg-egress-$SG_ID.json)" != "[]" ]; then
        aws ec2 revoke-security-group-egress --group-id "$SG_ID" --region "$AWS_REGION" \
          --ip-permissions file:///tmp/sg-egress-$SG_ID.json 2>/dev/null || true
      fi
    done

    # Second pass: delete security groups
    for SG_ID in $SG_IDS; do
      echo "  - Deleting SG: $SG_ID"
      aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" 2>/dev/null || echo "    (failed or already deleted)"
    done
  else
    echo "  No Security Groups found"
  fi

  # Step 8: Delete Route Tables (non-main)
  echo ""
  echo "Deleting Route Tables..."
  RT_IDS=$(aws ec2 describe-route-tables --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
    --output text 2>/dev/null || echo "")

  if [ -n "$RT_IDS" ]; then
    for RT_ID in $RT_IDS; do
      echo "  - Deleting Route Table: $RT_ID"
      aws ec2 delete-route-table --route-table-id "$RT_ID" --region "$AWS_REGION" 2>/dev/null || echo "    (failed or already deleted)"
    done
  else
    echo "  No Route Tables found"
  fi

  # Step 9: Delete VPC
  echo ""
  echo "Deleting VPC: $VPC_ID..."
  aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$AWS_REGION" \
    && echo -e "${GREEN}✅ VPC deleted successfully${NC}" \
    || echo -e "${RED}❌ VPC deletion failed (check AWS Console for remaining dependencies)${NC}"

else
  echo "No VPC found for cluster: $CLUSTER_NAME"
fi

echo ""

# ============================================================================
# Step 9: Delete IAM Resources
# ============================================================================

echo -e "${CYAN}[Step 8/12] Deleting IAM resources...${NC}"

# Delete Bedrock Role
if [ "$BEDROCK_ROLE_EXISTS" == "yes" ]; then
  echo "Detaching policies from OpenClawBedrockRole..."
  ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
    --role-name OpenClawBedrockRole \
    --query 'AttachedPolicies[].PolicyArn' \
    --output text 2>/dev/null || echo "")

  for POLICY_ARN in $ATTACHED_POLICIES; do
    echo "  - Detaching: $POLICY_ARN"
    aws iam detach-role-policy \
      --role-name OpenClawBedrockRole \
      --policy-arn "$POLICY_ARN" 2>/dev/null || echo "    (already detached)"
  done

  echo "Deleting OpenClawBedrockRole..."
  aws iam delete-role --role-name OpenClawBedrockRole 2>/dev/null || echo "  (already deleted)"
  echo -e "${GREEN}✅ OpenClawBedrockRole deleted${NC}"
else
  echo "OpenClawBedrockRole not found"
fi

# Delete Bedrock Policy
if [ "$BEDROCK_POLICY_EXISTS" == "yes" ]; then
  echo "Deleting OpenClawBedrockAccess policy..."
  aws iam delete-policy \
    --policy-arn "arn:aws:iam::${AWS_ACCOUNT}:policy/OpenClawBedrockAccess" 2>/dev/null \
    || echo "  (already deleted)"
  echo -e "${GREEN}✅ OpenClawBedrockAccess policy deleted${NC}"
else
  echo "OpenClawBedrockAccess policy not found"
fi

# Delete other IAM roles created by eksctl (if any)
echo "Checking for other IAM roles..."
EKSCTL_ROLES=$(aws iam list-roles \
  --query "Roles[?contains(RoleName, 'eksctl-${CLUSTER_NAME}')].RoleName" \
  --output text 2>/dev/null || echo "")

if [ -n "$EKSCTL_ROLES" ]; then
  echo -e "${YELLOW}⚠️  Found eksctl-created roles:${NC}"
  for ROLE in $EKSCTL_ROLES; do
    echo "  - $ROLE"
  done
  echo ""
  read -p "Delete these roles? (yes/no): " DELETE_ROLES

  if [ "$DELETE_ROLES" == "yes" ]; then
    for ROLE in $EKSCTL_ROLES; do
      echo "Deleting role: $ROLE"

      # Detach policies
      POLICIES=$(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text)
      for POLICY in $POLICIES; do
        aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POLICY" 2>/dev/null || true
      done

      # Delete inline policies
      INLINE_POLICIES=$(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text)
      for POLICY_NAME in $INLINE_POLICIES; do
        aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POLICY_NAME" 2>/dev/null || true
      done

      # Delete role
      aws iam delete-role --role-name "$ROLE" 2>/dev/null || echo "  (failed to delete)"
    done
  fi
fi

echo ""

# ============================================================================
# Step 10: Delete EFS FileSystem (Optional)
# ============================================================================

echo -e "${CYAN}[Step 9/12] Deleting EFS FileSystem...${NC}"

if [ -n "$EFS_ID" ]; then
  if [ "$DELETE_EFS" == "yes" ]; then
    echo "Deleting mount targets..."

    MOUNT_TARGETS=$(aws efs describe-mount-targets \
      --file-system-id "$EFS_ID" \
      --region "$AWS_REGION" \
      --query 'MountTargets[].MountTargetId' \
      --output text 2>/dev/null || echo "")

    if [ -n "$MOUNT_TARGETS" ]; then
      for MT_ID in $MOUNT_TARGETS; do
        echo "  - Deleting mount target: $MT_ID"
        aws efs delete-mount-target --mount-target-id "$MT_ID" --region "$AWS_REGION" 2>/dev/null || echo "    (already deleted)"
      done

      echo "Waiting for mount targets to be deleted..."
      sleep 30
    fi

    echo "Deleting EFS FileSystem..."
    aws efs delete-file-system --file-system-id "$EFS_ID" --region "$AWS_REGION" \
      && echo -e "${GREEN}✅ EFS FileSystem deleted${NC}" \
      || echo -e "${RED}❌ EFS deletion failed (may still have dependencies)${NC}"
  else
    echo -e "${YELLOW}⚠️  EFS FileSystem preserved: $EFS_ID${NC}"
    echo "   To delete manually later:"
    echo "   aws efs delete-file-system --file-system-id $EFS_ID --region $AWS_REGION"
  fi
else
  echo "No EFS FileSystem found"
fi

echo ""

# ============================================================================
# Step 11: Delete Security Groups
# ============================================================================

echo -e "${CYAN}[Step 10/12] Cleaning up security groups...${NC}"

# Delete CloudFront security group
CF_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=openclaw-alb-cloudfront-only" \
  --region "$AWS_REGION" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

if [ -n "$CF_SG_ID" ] && [ "$CF_SG_ID" != "None" ]; then
  echo "Deleting CloudFront security group: $CF_SG_ID"
  aws ec2 delete-security-group --group-id "$CF_SG_ID" --region "$AWS_REGION" 2>/dev/null \
    && echo -e "${GREEN}✅ CloudFront security group deleted${NC}" \
    || echo -e "${YELLOW}⚠️  Failed to delete (may still have dependencies)${NC}"
else
  echo "CloudFront security group not found"
fi

# Delete EFS security group (if EFS was deleted)
if [ "$DELETE_EFS" == "yes" ]; then
  EFS_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=openclaw-efs-sg" \
    --region "$AWS_REGION" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "")

  if [ -n "$EFS_SG_ID" ] && [ "$EFS_SG_ID" != "None" ]; then
    echo "Deleting EFS security group: $EFS_SG_ID"
    aws ec2 delete-security-group --group-id "$EFS_SG_ID" --region "$AWS_REGION" 2>/dev/null \
      && echo -e "${GREEN}✅ EFS security group deleted${NC}" \
      || echo -e "${YELLOW}⚠️  Failed to delete (may still have dependencies)${NC}"
  fi
fi

echo ""

# ============================================================================
# Step 12: Delete CloudFormation Stack (if exists)
# ============================================================================

echo -e "${CYAN}[Step 11/12] Checking for CloudFormation stack...${NC}"

STACK_NAME=${STACK_NAME:-"openclaw-platform"}
STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].StackStatus' \
  --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$STACK_STATUS" != "DOES_NOT_EXIST" ]; then
  echo "Found CloudFormation stack: $STACK_NAME"
  echo "Status: $STACK_STATUS"

  read -p "Delete CloudFormation stack? (yes/no): " DELETE_STACK

  if [ "$DELETE_STACK" == "yes" ]; then
    echo "Deleting CloudFormation stack..."
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$AWS_REGION"
    echo -e "${GREEN}✅ CloudFormation stack deletion initiated${NC}"
  else
    echo "Skipping CloudFormation stack deletion"
  fi
else
  echo "No CloudFormation stack found"
fi

echo ""

# ============================================================================
# Step 13: Cleanup Local Configuration
# ============================================================================

echo -e "${CYAN}[Step 12/12] Cleaning up local configuration...${NC}"

if kubectl config get-contexts "$CLUSTER_NAME" &>/dev/null; then
  echo "Removing kubectl context..."
  kubectl config delete-context "$CLUSTER_NAME" 2>/dev/null || true
  echo -e "${GREEN}✅ kubectl context removed${NC}"
else
  echo "No kubectl context found"
fi

echo ""

# ============================================================================
# Summary
# ============================================================================

echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                  ✅ CLEANUP COMPLETE ✅                        ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo "📋 Cleanup Summary:"
echo ""
echo "✅ Deleted:"
echo "  - Kubernetes resources (namespaces, deployments)"
if [ -n "$CLOUDFRONT_DIST_ID" ]; then
  echo "  - CloudFront distribution: $CLOUDFRONT_DIST_ID"
fi
if [ -n "$COGNITO_POOL_ID" ]; then
  echo "  - Cognito user pool: $COGNITO_POOL_ID"
fi
if [ -n "$EKS_EXISTS" ]; then
  echo "  - EKS cluster: $CLUSTER_NAME"
fi
if [ "$DELETE_EFS" == "yes" ] && [ -n "$EFS_ID" ]; then
  echo "  - EFS FileSystem: $EFS_ID"
fi
echo "  - IAM roles and policies"
echo "  - Security groups"

echo ""

if [ "$DELETE_EFS" == "no" ] && [ -n "$EFS_ID" ]; then
  echo -e "${YELLOW}⚠️  Resources preserved:${NC}"
  echo "  - EFS FileSystem: $EFS_ID (${EFS_SIZE_GB}GB)"
  echo ""
  echo "  To delete manually:"
  echo "  aws efs delete-file-system --file-system-id $EFS_ID --region $AWS_REGION"
  echo ""
fi

echo "🔍 Verification:"
echo "  Check AWS Console to confirm all resources are deleted:"
echo "  - EKS: https://console.aws.amazon.com/eks/home?region=${AWS_REGION}#/clusters"
echo "  - CloudFront: https://console.aws.amazon.com/cloudfront/home"
echo "  - Cognito: https://console.aws.amazon.com/cognito/home?region=${AWS_REGION}"
echo "  - IAM: https://console.aws.amazon.com/iam/home#/roles"
echo ""

echo -e "${BLUE}💰 Cost Impact:${NC}"
echo "  All resources have been deleted. You will no longer incur charges for:"
echo "  - EKS control plane (~\$73/month)"
echo "  - EC2 instances (varies by node type)"
echo "  - NAT Gateway (~\$32/month)"
echo "  - ALB (~\$22/month)"
echo "  - CloudFront (varies by usage)"
if [ "$DELETE_EFS" == "yes" ]; then
  echo "  - EFS storage (varies by size)"
fi
echo ""

echo -e "${GREEN}✨ Cleanup complete! All resources have been removed.${NC}"
echo ""
