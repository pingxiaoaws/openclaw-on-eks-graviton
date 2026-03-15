#!/bin/bash
# Phase 2: Deploy Kubernetes Controllers and Operators
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

echo -e "${BLUE}=== Phase 2: Controllers and Operators Deployment ===${NC}"
echo ""

# Get cluster info
CLUSTER_CONTEXT=$(kubectl config current-context)
# Extract cluster name and region (supports both ARN and eksctl formats)
if [[ "$CLUSTER_CONTEXT" == arn:aws:eks:* ]]; then
  # ARN format: arn:aws:eks:region:account:cluster/cluster-name
  AWS_REGION=$(echo "$CLUSTER_CONTEXT" | cut -d':' -f4)
  CLUSTER_NAME=$(echo "$CLUSTER_CONTEXT" | cut -d'/' -f2)
else
  # eksctl format: user@cluster-name.region.eksctl.io
  CLUSTER_NAME=$(echo "$CLUSTER_CONTEXT" | rev | cut -d'/' -f1 | rev)
  AWS_REGION=$(echo "$CLUSTER_CONTEXT" | grep -oE 'us(-gov)?-(east|west|central)-(1|2)' | head -1)
fi
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
# Step 5: Install EKS Pod Identity
# ============================================================================

echo -e "${BLUE}[5/7] Installing EKS Pod Identity...${NC}"

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
# Step 6: Install Kata Containers (if Kata nodes exist)
# ============================================================================

echo -e "${BLUE}[6/7] Installing Kata Containers...${NC}"

# Check if Kata nodes exist
KATA_NODE_COUNT=$(kubectl get nodes -l workload-type=kata --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "$KATA_NODE_COUNT" -eq 0 ]; then
  echo -e "${YELLOW}⚠️  No Kata nodes found, skipping Kata installation${NC}"
  echo "   (Cluster was deployed without Kata support)"
else
  echo "Found $KATA_NODE_COUNT Kata node(s), installing Kata Containers..."
  
  # Wait for Kata nodes to be Ready
  echo "Waiting for Kata nodes to be ready..."
  kubectl wait --for=condition=Ready nodes -l workload-type=kata --timeout=600s || \
    echo "  (Some nodes may still be initializing)"
  
  # Step 6.1: Install Kata RBAC with CRD permissions
  echo ""
  echo "Installing Kata RBAC..."
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kata-deploy-sa
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kata-deploy-role
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "patch"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kata-deploy-rb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kata-deploy-role
subjects:
- kind: ServiceAccount
  name: kata-deploy-sa
  namespace: kube-system
EOF

  # Step 6.2: Deploy Kata DaemonSet (fixed version)
  echo ""
  echo "Deploying Kata DaemonSet..."
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kata-deploy
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: kata-deploy
  template:
    metadata:
      labels:
        name: kata-deploy
    spec:
      serviceAccountName: kata-deploy-sa
      hostPID: true
      tolerations:
      - key: kata-dedicated
        operator: Exists
        effect: NoSchedule
      containers:
      - name: kube-kata
        image: quay.io/kata-containers/kata-deploy:3.27.0
        imagePullPolicy: Always
        securityContext:
          privileged: true
        command:
        - /usr/bin/kata-deploy
        - install
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: DEBUG
          value: "false"
        - name: SHIMS_AARCH64
          value: "fc"
        - name: DEFAULT_SHIM_AARCH64
          value: "fc"
        - name: SNAPSHOTTER_HANDLER_MAPPING_AARCH64
          value: "fc:devmapper"
        - name: INSTALLATION_PREFIX
          value: ""
        volumeMounts:
        - name: crio-conf
          mountPath: /etc/crio/
        - name: containerd-conf
          mountPath: /etc/containerd/
        - name: host
          mountPath: /host/
        lifecycle:
          preStop:
            exec:
              command:
              - /usr/bin/kata-deploy
              - cleanup
      terminationGracePeriodSeconds: 120
      volumes:
      - name: crio-conf
        hostPath:
          path: /etc/crio/
      - name: containerd-conf
        hostPath:
          path: /etc/containerd/
      - name: host
        hostPath:
          path: /
EOF
  
  # Step 6.3: Wait for Kata pods to be ready
  echo ""
  echo "Waiting for Kata deployment to complete (this may take 5-10 minutes)..."
  kubectl -n kube-system wait --timeout=10m --for=condition=Ready -l name=kata-deploy pod || \
    echo "  (Kata pods still initializing, check status with: kubectl get pods -n kube-system -l name=kata-deploy)"
  
  # Step 6.4: Verify Kata pods
  echo ""
  echo "Kata pods status:"
  kubectl get pods -n kube-system -l name=kata-deploy -o wide
  
  echo -e "${GREEN}✅ Kata Containers installed${NC}"
  echo "   Pods: Running on $KATA_NODE_COUNT node(s)"
fi

echo ""

# ============================================================================
# Step 7: Create/Verify Kata RuntimeClasses
# ============================================================================

echo -e "${BLUE}[7/7] Creating Kata RuntimeClasses...${NC}"

if [ "$KATA_NODE_COUNT" -gt 0 ]; then
  # Create Kata RuntimeClasses
  echo "Creating Kata RuntimeClasses..."
  cat <<EOF | kubectl apply -f -
---
# Kata Firecracker RuntimeClass
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-fc
  labels:
    kata-deploy/instance: default
handler: kata-fc
overhead:
  podFixed:
    cpu: 250m
    memory: 130Mi
scheduling:
  nodeSelector:
    katacontainers.io/kata-runtime: "true"
  tolerations:
    - key: kata-dedicated
      operator: Exists
      effect: NoSchedule
---
# Kata QEMU RuntimeClass
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

  echo ""
  echo "Available RuntimeClasses:"
  kubectl get runtimeclass | grep kata || echo "  (No kata runtimeclasses found)"
else
  echo -e "${YELLOW}⚠️  No Kata nodes, skipping RuntimeClass creation${NC}"
fi

echo -e "${GREEN}✅ RuntimeClasses configured${NC}"
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
echo "  ✅ EKS Pod Identity"

if [ "$KATA_NODE_COUNT" -gt 0 ]; then
  echo "  ✅ Kata Containers (DaemonSet on $KATA_NODE_COUNT node(s))"
  echo "  ✅ Kata RuntimeClasses (kata-fc, kata-qemu, etc.)"
else
  echo "  ⊗ Kata Containers (not installed - no Kata nodes)"
fi

echo ""
echo "Note: Karpenter skipped (using Managed Node Groups)"
echo ""
echo "Next Steps:"
echo "  1. Run: ./03-verify-deployment.sh  (Verify installation)"
echo "  2. Deploy Provisioning Service: ./04-deploy-provisioning-service.sh"
echo ""
