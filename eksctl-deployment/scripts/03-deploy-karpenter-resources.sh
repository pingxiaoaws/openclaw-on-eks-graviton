#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../configs"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Karpenter Installation${NC}"
echo -e "${BLUE}  Official Guide (Existing Cluster)${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${YELLOW}ℹ${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }

# Prerequisites check
echo -e "${BLUE}[1/7] Checking prerequisites...${NC}"
for cmd in kubectl helm aws eksctl; do
    if ! command -v $cmd &> /dev/null; then
        print_error "$cmd not found"
        exit 1
    fi
done
print_status "All prerequisites installed"
echo ""

# Set environment variables (following official guide)
echo -e "${BLUE}[2/7] Setting up environment variables...${NC}"
export KARPENTER_NAMESPACE="kube-system"
export KARPENTER_VERSION="1.9.0"
export CLUSTER_NAME=$(kubectl config current-context | cut -d'/' -f2)
export AWS_DEFAULT_REGION=$(kubectl config current-context | cut -d':' -f4)
export AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:-${AWS_ACCOUNT:-$(aws sts get-caller-identity --query Account --output text)}}
export AWS_PARTITION="aws"
export TEMPOUT=$(mktemp)

print_info "CLUSTER_NAME: ${CLUSTER_NAME}"
print_info "AWS_DEFAULT_REGION: ${AWS_DEFAULT_REGION}"
print_info "AWS_ACCOUNT_ID: ${AWS_ACCOUNT_ID}"
print_info "KARPENTER_VERSION: ${KARPENTER_VERSION}"
echo ""

# CFN stack name (set via env var or default)
CFN_STACK_NAME="${CFN_STACK_NAME:-cloudlab-template-global}"

# Get CloudFormation stack output value (returns empty string if stack/key not found)
get_cfn_output() {
    local stack_name="$1"
    local output_key="$2"
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue" \
        --output text 2>/dev/null || echo ""
}

# Query CFN outputs for Karpenter resources
CFN_KARPENTER_CONTROLLER_ROLE_ARN=$(get_cfn_output "$CFN_STACK_NAME" "KarpenterControllerRoleArn")
CFN_KARPENTER_NODE_ROLE_ARN=$(get_cfn_output "$CFN_STACK_NAME" "KarpenterNodeRoleArn")
CFN_KARPENTER_QUEUE_NAME=$(get_cfn_output "$CFN_STACK_NAME" "KarpenterInterruptionQueueName")

# Determine if we can skip Karpenter IAM stack creation
USE_CFN_KARPENTER=false
if [ -n "$CFN_KARPENTER_CONTROLLER_ROLE_ARN" ] && [ "$CFN_KARPENTER_CONTROLLER_ROLE_ARN" != "None" ] \
   && [ -n "$CFN_KARPENTER_NODE_ROLE_ARN" ] && [ "$CFN_KARPENTER_NODE_ROLE_ARN" != "None" ] \
   && [ -n "$CFN_KARPENTER_QUEUE_NAME" ] && [ "$CFN_KARPENTER_QUEUE_NAME" != "None" ]; then
  USE_CFN_KARPENTER=true
  print_status "Found CFN stack '$CFN_STACK_NAME' - using pre-provisioned Karpenter IAM resources"
  print_info "  Controller Role: $CFN_KARPENTER_CONTROLLER_ROLE_ARN"
  print_info "  Node Role:       $CFN_KARPENTER_NODE_ROLE_ARN"
  print_info "  SQS Queue:       $CFN_KARPENTER_QUEUE_NAME"
else
  print_info "No CFN Karpenter outputs found - will create IAM resources from scratch"
fi
echo ""

# Step 1: Create IAM resources using CloudFormation
echo -e "${BLUE}[3/7] Creating IAM resources via CloudFormation...${NC}"

if [ "$USE_CFN_KARPENTER" = true ]; then
  print_status "Skipping Karpenter CFN stack creation (using pre-provisioned resources)"
  KARPENTER_CONTROLLER_ROLE_ARN="$CFN_KARPENTER_CONTROLLER_ROLE_ARN"
  KARPENTER_NODE_ROLE_ARN="$CFN_KARPENTER_NODE_ROLE_ARN"
  KARPENTER_QUEUE_NAME="$CFN_KARPENTER_QUEUE_NAME"
else
  print_info "Downloading CloudFormation template..."
  curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" > "${TEMPOUT}"

  if aws cloudformation describe-stacks --stack-name "Karpenter-${CLUSTER_NAME}" --region ${AWS_DEFAULT_REGION} &>/dev/null; then
      print_warning "CloudFormation stack already exists"
  else
      print_info "Deploying CloudFormation stack (this may take 2-3 minutes)..."
      aws cloudformation deploy \
        --stack-name "Karpenter-${CLUSTER_NAME}" \
        --template-file "${TEMPOUT}" \
        --capabilities CAPABILITY_NAMED_IAM \
        --parameter-overrides "ClusterName=${CLUSTER_NAME}" \
        --region ${AWS_DEFAULT_REGION}
      print_status "CloudFormation stack created"
  fi

  KARPENTER_CONTROLLER_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}"
  KARPENTER_NODE_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"
  KARPENTER_QUEUE_NAME="${CLUSTER_NAME}"
fi

# Create EC2 Spot service-linked role
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com 2>/dev/null || true
print_status "EC2 Spot service-linked role verified"

if [ "$USE_CFN_KARPENTER" = false ]; then
  # Create KarpenterControllerRole (for IRSA) - only when not using CFN
  print_info "Creating KarpenterControllerRole for IRSA..."
  OIDC_PROVIDER=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_DEFAULT_REGION} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")

  if aws iam get-role --role-name "KarpenterControllerRole-${CLUSTER_NAME}" &>/dev/null; then
      print_warning "KarpenterControllerRole already exists"
  else
      cat > /tmp/karpenter-controller-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${KARPENTER_NAMESPACE}:karpenter"
        }
      }
    }
  ]
}
EOF

      aws iam create-role \
        --role-name "KarpenterControllerRole-${CLUSTER_NAME}" \
        --assume-role-policy-document file:///tmp/karpenter-controller-trust-policy.json

      print_status "KarpenterControllerRole created"
  fi

  # Attach CloudFormation-created policy to controller role
  print_info "Attaching KarpenterControllerPolicy to controller role..."
  aws iam attach-role-policy \
    --role-name "KarpenterControllerRole-${CLUSTER_NAME}" \
    --policy-arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}" 2>/dev/null || true
fi

print_status "Controller role configured with required policies"
echo ""

# Step 2: Tag subnets and security groups
echo -e "${BLUE}[4/7] Tagging subnets and security groups...${NC}"
VPC_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_DEFAULT_REGION} --query "cluster.resourcesVpcConfig.vpcId" --output text)

print_info "Tagging subnets in VPC: ${VPC_ID}"
for SUBNET_ID in $(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query "Subnets[?MapPublicIpOnLaunch==\`false\`].SubnetId" \
  --output text); do
  aws ec2 create-tags --resources ${SUBNET_ID} \
    --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME} 2>/dev/null || true
  print_status "Tagged subnet: ${SUBNET_ID}"
done

CLUSTER_SG=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_DEFAULT_REGION} \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
aws ec2 create-tags --resources ${CLUSTER_SG} \
  --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME} 2>/dev/null || true
print_status "Tagged security group: ${CLUSTER_SG}"
echo ""

# Step 3: Add IAM identity mapping for Karpenter nodes
echo -e "${BLUE}[5/7] Adding IAM identity mapping...${NC}"

if eksctl get iamidentitymapping --cluster ${CLUSTER_NAME} --region ${AWS_DEFAULT_REGION} --arn ${KARPENTER_NODE_ROLE_ARN} &>/dev/null; then
    print_warning "IAM identity mapping already exists"
else
    print_info "Creating IAM identity mapping..."
    eksctl create iamidentitymapping \
      --cluster ${CLUSTER_NAME} \
      --region ${AWS_DEFAULT_REGION} \
      --arn "${KARPENTER_NODE_ROLE_ARN}" \
      --username system:node:{{EC2PrivateDNSName}} \
      --group system:bootstrappers \
      --group system:nodes
    print_status "IAM identity mapping created"
fi
echo ""

# Step 4: Install Karpenter using Helm
echo -e "${BLUE}[6/7] Installing Karpenter via Helm...${NC}"
export CLUSTER_ENDPOINT=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_DEFAULT_REGION} --query "cluster.endpoint" --output text)

print_info "Cluster endpoint: ${CLUSTER_ENDPOINT}"

# Logout of helm registry to perform an unauthenticated pull
helm registry logout public.ecr.aws 2>/dev/null || true

print_info "Installing Karpenter ${KARPENTER_VERSION}..."
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${KARPENTER_QUEUE_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KARPENTER_CONTROLLER_ROLE_ARN}" \
  --wait

print_status "Karpenter installed successfully"

# Wait for Karpenter to be ready
print_info "Waiting for Karpenter pods to be ready..."
kubectl wait --for=condition=ready pod -n ${KARPENTER_NAMESPACE} -l app.kubernetes.io/name=karpenter --timeout=120s
print_status "Karpenter is ready"
echo ""

# Step 5: Deploy NodePool and EC2NodeClass
echo -e "${BLUE}[7/7] Deploying NodePool and EC2NodeClass...${NC}"

if [ -f "${CONFIG_DIR}/karpenter-standard-nodeclass.yaml" ]; then
    kubectl apply -f "${CONFIG_DIR}/karpenter-standard-nodeclass.yaml"
    print_status "Applied standard-arm64 NodeClass"
else
    print_warning "Standard NodeClass not found, skipping"
fi

if [ -f "${CONFIG_DIR}/karpenter-standard-nodepool.yaml" ]; then
    kubectl apply -f "${CONFIG_DIR}/karpenter-standard-nodepool.yaml"
    print_status "Applied standard-arm64 NodePool"
else
    print_warning "Standard NodePool not found, skipping"
fi

if [ -f "${CONFIG_DIR}/karpenter-kata-nodeclass.yaml" ]; then
    kubectl apply -f "${CONFIG_DIR}/karpenter-kata-nodeclass.yaml"
    print_status "Applied kata-metal NodeClass"
fi

if [ -f "${CONFIG_DIR}/karpenter-kata-nodepool.yaml" ]; then
    kubectl apply -f "${CONFIG_DIR}/karpenter-kata-nodepool.yaml"
    print_status "Applied kata-metal NodePool"
fi

echo ""
echo "Current resources:"
echo ""
echo "EC2NodeClasses:"
kubectl get ec2nodeclass 2>/dev/null || echo "  (none)"
echo ""
echo "NodePools:"
kubectl get nodepool 2>/dev/null || echo "  (none)"
echo ""

# Create test workload
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Creating Test Workload${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-karpenter-standard
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: test-karpenter-standard
  template:
    metadata:
      labels:
        app: test-karpenter-standard
    spec:
      nodeSelector:
        workload-type: standard
      containers:
      - name: pause
        image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
        resources:
          requests:
            cpu: 1000m
            memory: 2Gi
EOF

print_status "Test deployment created (2 replicas, 1 CPU + 2Gi each)"
echo ""

# Monitor node provisioning
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Monitoring Node Provisioning${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
print_info "Watching for new nodes (120 seconds)..."
print_info "Karpenter typically provisions nodes in 30-60 seconds"
echo ""

echo -e "${YELLOW}Current nodes:${NC}"
kubectl get nodes -o wide
echo ""

echo -e "${YELLOW}Watching nodes (Ctrl+C to stop early)...${NC}"
timeout 120 kubectl get nodes -L karpenter.sh/nodepool,workload-type,karpenter.sh/initialized -w || true

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Summary & Next Steps${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

print_status "Karpenter installation complete!"
echo ""

echo -e "${YELLOW}Verify the setup:${NC}"
echo "  kubectl get nodes -L karpenter.sh/nodepool,workload-type"
echo "  kubectl get pods -n default -l app=test-karpenter-standard -o wide"
echo ""

echo -e "${YELLOW}View Karpenter logs:${NC}"
echo "  kubectl logs -f -n ${KARPENTER_NAMESPACE} -l app.kubernetes.io/name=karpenter"
echo ""

echo -e "${YELLOW}Cleanup test workload:${NC}"
echo "  kubectl delete deployment test-karpenter-standard -n default"
echo ""

echo -e "${YELLOW}Remove Karpenter (will terminate managed nodes):${NC}"
echo "  kubectl delete nodepool --all"
echo "  kubectl delete ec2nodeclass --all"
echo "  helm uninstall karpenter -n ${KARPENTER_NAMESPACE}"
echo "  aws cloudformation delete-stack --stack-name Karpenter-${CLUSTER_NAME} --region ${AWS_DEFAULT_REGION}"
echo "  aws ec2 describe-launch-templates \\"
echo "    --filters 'Name=tag:karpenter.k8s.aws/cluster,Values=${CLUSTER_NAME}' \\"
echo "    --query 'LaunchTemplates[].LaunchTemplateName' --output text | \\"
echo "    xargs -I{} aws ec2 delete-launch-template --launch-template-name {}"
echo ""
