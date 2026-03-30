#!/bin/bash
# Phase 2: Deploy Kubernetes Controllers and Operators
# - EKS Pod Identity Agent (MUST be first)
# - EFS CSI Driver
# - AWS Load Balancer Controller
# - Karpenter
# - Kata Containers
# - Kata RuntimeClasses

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
TEMPLATE_DIR="$(cd "${SCRIPT_DIR}/../templates"; pwd)"

echo -e "${BLUE}=== Phase 2: Controllers and Operators Deployment ===${NC}"
echo ""

# Get cluster info
CLUSTER_CONTEXT=$(kubectl config current-context)
# Extract cluster name and region (supports both ARN and eksctl formats)
if [[ "$CLUSTER_CONTEXT" == arn:aws*:eks:* ]]; then
  # ARN format: arn:aws:eks:region:account:cluster/cluster-name (or arn:aws-cn:eks:...)
  AWS_REGION=$(echo "$CLUSTER_CONTEXT" | cut -d':' -f4)
  CLUSTER_NAME=$(echo "$CLUSTER_CONTEXT" | cut -d'/' -f2)
else
  # eksctl format: user@cluster-name.region.eksctl.io
  CLUSTER_NAME=$(echo "$CLUSTER_CONTEXT" | rev | cut -d'/' -f1 | rev)
  AWS_REGION=$(echo "$CLUSTER_CONTEXT" | grep -oE 'us(-gov)?-(east|west|central)-(1|2)' | head -1)
fi
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# Detect AWS partition (aws vs aws-cn for China regions)
if [[ "$AWS_REGION" == cn-* ]]; then
  AWS_PARTITION="aws-cn"
else
  AWS_PARTITION="aws"
fi
export AWS_PARTITION

echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Account: $AWS_ACCOUNT"
echo ""

# ============================================================================
# Detect CloudFormation pre-provisioned resources
# ============================================================================

CFN_STACK_NAME="cloudlab-template-global"
USE_CFN=false
CFN_EFS_ROLE_ARN=""
CFN_ALB_ROLE_ARN=""
CFN_EFS_ID=""

echo -e "${BLUE}Checking for CloudFormation stack '${CFN_STACK_NAME}'...${NC}"

CFN_OUTPUTS=$(aws cloudformation describe-stacks \
  --stack-name "$CFN_STACK_NAME" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs' \
  --output json 2>/dev/null || echo "")

if [ -n "$CFN_OUTPUTS" ] && [ "$CFN_OUTPUTS" != "null" ] && [ "$CFN_OUTPUTS" != "None" ]; then
  USE_CFN=true
  CFN_EFS_ROLE_ARN=$(echo "$CFN_OUTPUTS" | jq -r '.[] | select(.OutputKey=="EFSCSIDriverRoleArn") | .OutputValue // empty')
  CFN_ALB_ROLE_ARN=$(echo "$CFN_OUTPUTS" | jq -r '.[] | select(.OutputKey=="ALBControllerRoleArn") | .OutputValue // empty')
  CFN_EFS_ID=$(echo "$CFN_OUTPUTS" | jq -r '.[] | select(.OutputKey=="EFSFileSystemId") | .OutputValue // empty')

  echo -e "${GREEN}Found CloudFormation stack '${CFN_STACK_NAME}' with pre-provisioned resources:${NC}"
  [ -n "$CFN_EFS_ROLE_ARN" ] && echo "  EFS CSI Driver Role ARN: $CFN_EFS_ROLE_ARN"
  [ -n "$CFN_ALB_ROLE_ARN" ] && echo "  ALB Controller Role ARN: $CFN_ALB_ROLE_ARN"
  [ -n "$CFN_EFS_ID" ]       && echo "  EFS FileSystem ID:       $CFN_EFS_ID"
else
  echo -e "${YELLOW}No CloudFormation stack found, will create all resources from scratch${NC}"
fi

echo ""

# ============================================================================
# Step 1: Install EKS Pod Identity Agent (MUST be first - required by all
#          Pod Identity associations that follow)
# ============================================================================

echo -e "${BLUE}[1/8] Installing EKS Pod Identity Agent...${NC}"

# Check if Pod Identity addon exists
POD_IDENTITY_STATUS=$(aws eks describe-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name eks-pod-identity-agent \
  --region "$AWS_REGION" \
  --query 'addon.status' \
  --output text 2>/dev/null || echo "NOT_INSTALLED")

if [ "$POD_IDENTITY_STATUS" == "ACTIVE" ]; then
  echo -e "${YELLOW}⚠️  Pod Identity addon already installed${NC}"
else
  echo "Installing Pod Identity addon..."
  aws eks create-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name eks-pod-identity-agent \
    --addon-version v1.3.10-eksbuild.2 \
    --resolve-conflicts OVERWRITE \
    --region "$AWS_REGION"

  # Wait for addon to be active
  echo "Waiting for Pod Identity addon to be active..."
  aws eks wait addon-active \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name eks-pod-identity-agent \
    --region "$AWS_REGION"

  echo -e "${GREEN}✅ Pod Identity addon installed${NC}"
fi

echo ""

# ============================================================================
# Step 2: Create EFS CSI Driver IAM Role for Pod Identity
# ============================================================================

echo -e "${BLUE}[2/8] Creating EFS CSI Driver IAM Role (Pod Identity)...${NC}"

if [ "$USE_CFN" = true ] && [ -n "$CFN_EFS_ROLE_ARN" ]; then
  echo -e "${GREEN}Using CFN pre-provisioned EFS CSI Driver Role: $CFN_EFS_ROLE_ARN${NC}"
  EFS_ROLE_ARN="$CFN_EFS_ROLE_ARN"
else
  EFS_POLICY_NAME="AmazonEKS_EFS_CSI_Driver_Policy"
  EFS_ROLE_NAME="AmazonEKS_EFS_CSI_DriverRole"
  EFS_POLICY_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:policy/${EFS_POLICY_NAME}"

  # Create IAM Policy for EFS CSI Driver
  if aws iam get-policy --policy-arn "$EFS_POLICY_ARN" &>/dev/null; then
    echo -e "${YELLOW}⚠️  EFS CSI Policy already exists${NC}"
  else
    echo "Creating EFS CSI IAM policy..."
    cat > /tmp/efs-csi-policy.json <<EOFPOLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:DescribeAccessPoints",
        "elasticfilesystem:DescribeFileSystems",
        "elasticfilesystem:DescribeMountTargets",
        "elasticfilesystem:TagResource",
        "elasticfilesystem:UntagResource"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:CreateAccessPoint"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:RequestTag/efs.csi.aws.com/cluster": "true"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": "elasticfilesystem:DeleteAccessPoint",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/efs.csi.aws.com/cluster": "true"
        }
      }
    }
  ]
}
EOFPOLICY

    aws iam create-policy \
      --policy-name "$EFS_POLICY_NAME" \
      --policy-document file:///tmp/efs-csi-policy.json \
      --description "Policy for EFS CSI Driver"

    echo -e "${GREEN}✅ EFS CSI IAM policy created${NC}"
  fi

  # Create IAM Role for EFS CSI Driver (Pod Identity)
  if aws iam get-role --role-name "$EFS_ROLE_NAME" &>/dev/null; then
    echo -e "${YELLOW}⚠️  EFS CSI Role already exists${NC}"
  else
    echo "Creating EFS CSI IAM role with Pod Identity trust policy..."
    cat > /tmp/efs-csi-trust-policy.json <<EOFTRUST
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
      --role-name "$EFS_ROLE_NAME" \
      --assume-role-policy-document file:///tmp/efs-csi-trust-policy.json \
      --description "IAM role for EFS CSI Driver via Pod Identity"

    aws iam attach-role-policy \
      --role-name "$EFS_ROLE_NAME" \
      --policy-arn "$EFS_POLICY_ARN"

    echo -e "${GREEN}✅ EFS CSI IAM role created${NC}"
  fi

  EFS_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:role/${EFS_ROLE_NAME}"
fi

echo ""

# ============================================================================
# Step 3: Install EFS CSI Driver (Pod Identity association THEN Helm install)
# ============================================================================

echo -e "${BLUE}[3/8] Installing EFS CSI Driver...${NC}"

# Create Pod Identity Association BEFORE helm install so pods pick up credentials
# EFS_ROLE_ARN is already set in Step 2 (either from CFN or freshly created)

EXISTING_EFS_ASSOC=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace kube-system \
  --service-account efs-csi-controller-sa \
  --query 'associations[0].associationId' \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_EFS_ASSOC" ] && [ "$EXISTING_EFS_ASSOC" != "None" ]; then
  echo -e "${YELLOW}⚠️  EFS CSI Pod Identity association already exists: $EXISTING_EFS_ASSOC${NC}"
else
  echo "Creating Pod Identity association for EFS CSI Driver..."
  aws eks create-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" \
    --namespace kube-system \
    --service-account efs-csi-controller-sa \
    --role-arn "$EFS_ROLE_ARN" \
    --region "$AWS_REGION"

  sleep 5

  echo -e "${GREEN}✅ EFS CSI Pod Identity association created${NC}"
fi

# Install EFS CSI Driver via Helm
if helm list -n kube-system | grep -q aws-efs-csi-driver; then
  echo -e "${YELLOW}⚠️  EFS CSI Driver already installed, upgrading...${NC}"
  helm upgrade aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
    --namespace kube-system \
    --set controller.serviceAccount.create=true \
    --set controller.serviceAccount.name=efs-csi-controller-sa \
    --reuse-values \
    --wait
else
  # Add Helm repo
  helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
  helm repo update

  # Install EFS CSI Driver (using Pod Identity)
  helm upgrade --install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
    --namespace kube-system \
    --set controller.serviceAccount.create=true \
    --set controller.serviceAccount.name=efs-csi-controller-sa \
    --wait

  echo -e "${GREEN}✅ EFS CSI Driver installed${NC}"
fi

echo ""

# ============================================================================
# Step 4: Create EFS FileSystem and StorageClass
# ============================================================================

echo -e "${BLUE}[4/8] Setting up EFS FileSystem...${NC}"

if [ "$USE_CFN" = true ] && [ -n "$CFN_EFS_ID" ]; then
  echo -e "${GREEN}Using CFN pre-provisioned EFS FileSystem: $CFN_EFS_ID${NC}"
  EFS_ID="$CFN_EFS_ID"
else
  # Check if EFS already exists
  EFS_ID=$(aws efs describe-file-systems \
    --region "$AWS_REGION" \
    --query "FileSystems[?Tags[?Key=='Name' && Value=='openclaw-shared-storage']].FileSystemId" \
    --output text 2>/dev/null || echo "")

  if [ -n "$EFS_ID" ]; then
    echo -e "${YELLOW}⚠️  EFS FileSystem already exists: $EFS_ID${NC}"
  else
  # Get VPC ID
  VPC_ID=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' \
    --output text)

  echo "VPC ID: $VPC_ID"

  # Create security group for EFS
  SG_ID=$(aws ec2 create-security-group \
    --group-name openclaw-efs-sg \
    --description "Security group for OpenClaw EFS" \
    --vpc-id "$VPC_ID" \
    --region "$AWS_REGION" \
    --query 'GroupId' \
    --output text)

  echo "Security Group: $SG_ID"

  # Allow NFS traffic from VPC CIDR
  VPC_CIDR=$(aws ec2 describe-vpcs \
    --vpc-ids "$VPC_ID" \
    --region "$AWS_REGION" \
    --query 'Vpcs[0].CidrBlock' \
    --output text)

  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 2049 \
    --cidr "$VPC_CIDR" \
    --region "$AWS_REGION"

  # Create EFS FileSystem
  EFS_ID=$(aws efs create-file-system \
    --region "$AWS_REGION" \
    --performance-mode generalPurpose \
    --throughput-mode elastic \
    --encrypted \
    --tags "Key=Name,Value=openclaw-shared-storage" \
    --query 'FileSystemId' \
    --output text)

  echo "Created EFS: $EFS_ID"

  # Wait for EFS to become available
  echo "Waiting for EFS to become available..."
  aws efs describe-file-systems \
    --file-system-id "$EFS_ID" \
    --region "$AWS_REGION" \
    --query 'FileSystems[0].LifeCycleState' \
    --output text

  sleep 10

  # Create mount targets in all subnets
  SUBNET_IDS=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.subnetIds' \
    --output text)

  for SUBNET_ID in $SUBNET_IDS; do
    echo "Creating mount target in subnet: $SUBNET_ID"
    aws efs create-mount-target \
      --file-system-id "$EFS_ID" \
      --subnet-id "$SUBNET_ID" \
      --security-groups "$SG_ID" \
      --region "$AWS_REGION" 2>/dev/null || echo "Mount target already exists"
  done

    echo -e "${GREEN}✅ EFS FileSystem created: $EFS_ID${NC}"
  fi
fi

# Create StorageClass
echo "Creating EFS StorageClass..."
export EFS_ID
envsubst < "${TEMPLATE_DIR}/k8s-manifests/efs-storageclass.yaml.tpl" | kubectl apply -f -

echo -e "${GREEN}✅ EFS StorageClass created${NC}"

# Create gp3 StorageClass for EBS volumes (higher performance than gp2)
echo "Creating gp3 StorageClass..."
kubectl apply -f "${TEMPLATE_DIR}/k8s-manifests/gp3-storageclass.yaml"

echo -e "${GREEN}✅ gp3 StorageClass created${NC}"
echo ""

# ============================================================================
# Step 5: Install AWS Load Balancer Controller
# ============================================================================

echo -e "${BLUE}[5/8] Installing AWS Load Balancer Controller...${NC}"

# Set ALB Role ARN (from CFN or default naming convention)
if [ "$USE_CFN" = true ] && [ -n "$CFN_ALB_ROLE_ARN" ]; then
  ALB_ROLE_ARN="$CFN_ALB_ROLE_ARN"
  echo -e "${GREEN}Using CFN pre-provisioned ALB Controller Role: $ALB_ROLE_ARN${NC}"
else
  ALB_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:role/AWSLoadBalancerControllerRole-${CLUSTER_NAME}"
fi

# Create Pod Identity association for ALB Controller BEFORE helm install
EXISTING_ALB_ASSOC=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace kube-system \
  --service-account aws-load-balancer-controller \
  --query 'associations[0].associationId' \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_ALB_ASSOC" ] && [ "$EXISTING_ALB_ASSOC" != "None" ]; then
  echo -e "${YELLOW}⚠️  ALB Controller Pod Identity association already exists: $EXISTING_ALB_ASSOC${NC}"
else
  echo "Creating Pod Identity association for ALB Controller..."
  aws eks create-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" \
    --namespace kube-system \
    --service-account aws-load-balancer-controller \
    --role-arn "$ALB_ROLE_ARN" \
    --region "$AWS_REGION"

  sleep 5

  echo -e "${GREEN}✅ ALB Controller Pod Identity association created${NC}"
fi

if helm list -n kube-system | grep -q aws-load-balancer-controller; then
  echo -e "${YELLOW}⚠️  ALB Controller already installed, skipping${NC}"
else
  if [ "$USE_CFN" = true ] && [ -n "$CFN_ALB_ROLE_ARN" ]; then
    echo -e "${GREEN}Skipping ALB IAM policy/role creation (provided by CFN)${NC}"
  else
    # Use local IAM policy (partition-aware: global vs China)
    if [ "$AWS_PARTITION" = "aws-cn" ]; then
      cp "${TEMPLATE_DIR}/iam-policies/alb-controller-policy-cn.json" /tmp/iam_policy.json
    else
      cp "${TEMPLATE_DIR}/iam-policies/alb-controller-policy.json" /tmp/iam_policy.json
    fi

    # Create IAM policy
    aws iam create-policy \
      --policy-name AWSLoadBalancerControllerIAMPolicy \
      --policy-document file:///tmp/iam_policy.json \
      --region "$AWS_REGION" 2>/dev/null || echo "Policy already exists"

    # Create IAM Role for ALB Controller (Pod Identity)
    ALB_ROLE_NAME="AWSLoadBalancerControllerRole-${CLUSTER_NAME}"
    ALB_POLICY_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:policy/AWSLoadBalancerControllerIAMPolicy"

    if aws iam get-role --role-name "$ALB_ROLE_NAME" &>/dev/null; then
      echo -e "${YELLOW}⚠️  ALB Controller Role already exists${NC}"
    else
      echo "Creating ALB Controller IAM role with Pod Identity trust policy..."
      cat > /tmp/alb-trust-policy.json <<EOFTRUST
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
        --role-name "$ALB_ROLE_NAME" \
        --assume-role-policy-document file:///tmp/alb-trust-policy.json \
        --description "IAM role for ALB Controller via Pod Identity"

      aws iam attach-role-policy \
        --role-name "$ALB_ROLE_NAME" \
        --policy-arn "$ALB_POLICY_ARN"

      echo -e "${GREEN}✅ ALB Controller IAM role created${NC}"
    fi

    ALB_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:role/${ALB_ROLE_NAME}"
  fi

  # Add Helm repo
  helm repo add eks https://aws.github.io/eks-charts
  helm repo update

  # Install ALB Controller
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --wait

  echo -e "${GREEN}✅ AWS Load Balancer Controller installed${NC}"
fi

echo ""

# ============================================================================
# Step 6: Install Karpenter (Optional - skip for now)
# ============================================================================

echo -e "${BLUE}[6/8] Karpenter (Optional)...${NC}"
echo "Skipping Karpenter installation (using Managed Node Groups)"
echo "To install Karpenter later, see: https://karpenter.sh/docs/getting-started/"
echo ""

# ============================================================================
# Step 7: Install Kata Containers (always install, nodes will join later)
# ============================================================================

echo -e "${BLUE}[7/8] Installing Kata Containers...${NC}"

# Always install Kata components (don't wait for nodes)
echo "Installing Kata RBAC and DaemonSet..."
echo "  (Kata nodes will be provisioned by Karpenter when needed)"

# Step 7.1: Install Kata RBAC with CRD permissions
echo ""
echo "Installing Kata RBAC..."
kubectl apply -f "${TEMPLATE_DIR}/k8s-manifests/kata-rbac.yaml"

# Step 7.2: Deploy Kata DaemonSet
echo ""
echo "Deploying Kata DaemonSet..."
kubectl apply -f "${TEMPLATE_DIR}/k8s-manifests/kata-daemonset.yaml"

# Step 7.3: Check if any Kata nodes exist
KATA_NODE_COUNT=$(kubectl get nodes -l workload-type=kata --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "$KATA_NODE_COUNT" -gt 0 ]; then
  echo ""
  echo "Found $KATA_NODE_COUNT existing Kata node(s), waiting for Kata pods..."
  kubectl -n kube-system wait --timeout=10m --for=condition=Ready -l name=kata-deploy pod || \
    echo "  (Kata pods still initializing, check status with: kubectl get pods -n kube-system -l name=kata-deploy)"

  echo ""
  echo "Kata pods status:"
  kubectl get pods -n kube-system -l name=kata-deploy -o wide
else
  echo ""
  echo "No Kata nodes yet (Karpenter will create them when needed)"
  echo "  DaemonSet will automatically deploy to nodes when they join"
fi

echo -e "${GREEN}✅ Kata Containers components installed${NC}"

echo ""

# ============================================================================
# Step 8: Create Kata RuntimeClasses (always create)
# ============================================================================

echo -e "${BLUE}[8/8] Creating Kata RuntimeClasses...${NC}"

# Always create RuntimeClasses (required for Karpenter to provision Kata nodes)
echo "Creating Kata RuntimeClasses..."
kubectl apply -f "${TEMPLATE_DIR}/k8s-manifests/kata-runtimeclasses.yaml"

echo ""
echo "Available RuntimeClasses:"
kubectl get runtimeclass | grep kata || echo "  (RuntimeClasses created but nodes not joined yet)"

echo -e "${GREEN}✅ RuntimeClasses configured${NC}"
echo ""

# ============================================================================
# Summary
# ============================================================================

echo -e "${GREEN}=== Phase 2 Complete ===${NC}"
echo ""
echo "Installed Components:"
echo "  ✅ EKS Pod Identity Agent"
echo "  ✅ EFS CSI Driver"
echo "  ✅ EFS FileSystem: $EFS_ID"
echo "  ✅ EFS StorageClass: efs-sc (ReadWriteMany, cross-AZ)"
echo "  ✅ EBS StorageClass: gp3 (ReadWriteOnce, high-performance)"
echo "  ✅ AWS Load Balancer Controller"

echo "  ✅ Kata Containers (DaemonSet ready, will auto-deploy to nodes)"
echo "  ✅ Kata RuntimeClasses (kata-fc, kata-qemu)"
KATA_NODE_COUNT=$(kubectl get nodes -l workload-type=kata --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$KATA_NODE_COUNT" -gt 0 ]; then
  echo "     Active Kata nodes: $KATA_NODE_COUNT"
else
  echo "     Note: Karpenter will create Kata nodes when workloads require them"
fi

echo ""
echo "Note: Karpenter skipped (using Managed Node Groups)"
echo ""

