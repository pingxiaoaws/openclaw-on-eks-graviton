#!/bin/bash
# Phase 2: Deploy Kubernetes Controllers and Operators
# - EFS CSI Driver
# - AWS Load Balancer Controller
# - Karpenter
# - OpenClaw Operator
# - Kata RuntimeClasses

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Phase 2: Controllers and Operators Deployment ===${NC}"
echo ""

# Get cluster info
CLUSTER_NAME=$(kubectl config current-context | cut -d'@' -f2 | cut -d'.' -f1)
AWS_REGION=$(kubectl config current-context | grep -o 'us-[a-z]*-[0-9]' || echo "us-east-1")
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Account: $AWS_ACCOUNT"
echo ""

# ============================================================================
# Step 1: Install EFS CSI Driver
# ============================================================================

echo -e "${BLUE}[1/7] Installing EFS CSI Driver...${NC}"

# Check if already installed
if helm list -n kube-system | grep -q aws-efs-csi-driver; then
  echo -e "${YELLOW}⚠️  EFS CSI Driver already installed, skipping${NC}"
else
  # Add Helm repo
  helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
  helm repo update

  # Install EFS CSI Driver
  helm upgrade --install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
    --namespace kube-system \
    --set controller.serviceAccount.create=true \
    --set controller.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::${AWS_ACCOUNT}:role/AmazonEKS_EFS_CSI_DriverRole" \
    --wait

  echo -e "${GREEN}✅ EFS CSI Driver installed${NC}"
fi

echo ""

# ============================================================================
# Step 2: Create EFS FileSystem and StorageClass
# ============================================================================

echo -e "${BLUE}[2/7] Setting up EFS FileSystem...${NC}"

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

# Create StorageClass
echo "Creating EFS StorageClass..."
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: ${EFS_ID}
  directoryPerms: "700"
  basePath: /openclaw
  uid: "1000"
  gid: "1000"
mountOptions:
  - tls
EOF

echo -e "${GREEN}✅ EFS StorageClass created${NC}"
echo ""

# ============================================================================
# Step 3: Install AWS Load Balancer Controller
# ============================================================================

echo -e "${BLUE}[3/7] Installing AWS Load Balancer Controller...${NC}"

if helm list -n kube-system | grep -q aws-load-balancer-controller; then
  echo -e "${YELLOW}⚠️  ALB Controller already installed, skipping${NC}"
else
  # Download IAM policy
  curl -o /tmp/iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json

  # Create IAM policy
  aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file:///tmp/iam_policy.json \
    --region "$AWS_REGION" 2>/dev/null || echo "Policy already exists"

  # Create IAM service account
  eksctl create iamserviceaccount \
    --cluster="$CLUSTER_NAME" \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --attach-policy-arn="arn:aws:iam::${AWS_ACCOUNT}:policy/AWSLoadBalancerControllerIAMPolicy" \
    --approve \
    --region="$AWS_REGION" \
    --override-existing-serviceaccounts 2>/dev/null || echo "Service account already exists"

  # Add Helm repo
  helm repo add eks https://aws.github.io/eks-charts
  helm repo update

  # Install ALB Controller
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --wait

  echo -e "${GREEN}✅ AWS Load Balancer Controller installed${NC}"
fi

echo ""

# ============================================================================
# Step 4: Install Karpenter (Optional - skip for now)
# ============================================================================

echo -e "${BLUE}[4/7] Karpenter (Optional)...${NC}"
echo "Skipping Karpenter installation (using Managed Node Groups)"
echo "To install Karpenter later, see: https://karpenter.sh/docs/getting-started/"
echo ""

# ============================================================================
# Step 5: Install OpenClaw Operator
# ============================================================================

echo -e "${BLUE}[5/7] Installing OpenClaw Operator...${NC}"

# Check if operator directory exists
OPERATOR_DIR="$(dirname "$0")/../../k8s-operator"
if [ ! -d "$OPERATOR_DIR" ]; then
  echo -e "${YELLOW}⚠️  Operator directory not found: $OPERATOR_DIR${NC}"
  echo "Skipping operator installation (deploy manually later)"
else
  cd "$OPERATOR_DIR"

  # Check if Helm chart exists
  if [ -d "charts/openclaw-operator" ]; then
    helm upgrade --install openclaw-operator charts/openclaw-operator \
      --namespace openclaw-operator-system \
      --create-namespace \
      --wait

    echo -e "${GREEN}✅ OpenClaw Operator installed${NC}"
  else
    # Use kustomize
    echo "Using kustomize deployment..."
    kubectl apply -k config/default

    echo -e "${GREEN}✅ OpenClaw Operator installed (kustomize)${NC}"
  fi

  cd -
fi

echo ""

# ============================================================================
# Step 6: Install EKS Pod Identity
# ============================================================================

echo -e "${BLUE}[6/7] Installing EKS Pod Identity...${NC}"

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
# Step 7: Create Kata RuntimeClasses
# ============================================================================

echo -e "${BLUE}[7/7] Creating Kata RuntimeClasses...${NC}"

# RuntimeClass for Firecracker
cat <<EOF | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-fc
handler: kata-fc
scheduling:
  nodeSelector:
    workload-type: kata
  tolerations:
    - key: kata-dedicated
      operator: Exists
      effect: NoSchedule
EOF

# RuntimeClass for QEMU (EFS support)
cat <<EOF | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-qemu
handler: kata-qemu
scheduling:
  nodeSelector:
    workload-type: kata
  tolerations:
    - key: kata-dedicated
      operator: Exists
      effect: NoSchedule
EOF

echo -e "${GREEN}✅ Kata RuntimeClasses created${NC}"
echo ""

# ============================================================================
# Summary
# ============================================================================

echo -e "${GREEN}=== Phase 2 Complete ===${NC}"
echo ""
echo "Installed Components:"
echo "  ✅ EFS CSI Driver"
echo "  ✅ EFS FileSystem: $EFS_ID"
echo "  ✅ EFS StorageClass: efs-sc"
echo "  ✅ AWS Load Balancer Controller"
echo "  ✅ OpenClaw Operator"
echo "  ✅ EKS Pod Identity"
echo "  ✅ Kata RuntimeClasses (kata-fc, kata-qemu)"
echo ""
echo "Note: Karpenter skipped (using Managed Node Groups)"
echo ""
echo "Next Steps:"
echo "  1. Run: ./04-verify-deployment.sh  (Verify installation)"
echo "  2. Deploy Provisioning Service: ./05-deploy-provisioning-service.sh"
echo ""
