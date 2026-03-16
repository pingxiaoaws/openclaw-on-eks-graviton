# EKS Full-Stack CloudFormation Templates

CloudFormation templates that provision a complete EKS environment with optional browser-based IDE. Supports standalone deployment or nested stack orchestration.

## Templates

| File | Description |
|------|-------------|
| `eks-full-stack.yaml` | EKS infrastructure (Global regions) - standalone |
| `eks-full-stack-china.yaml` | EKS infrastructure (China regions) - standalone |
| `ide-vscode.yaml` | Browser-based VS Code IDE (code-server) - standalone or nested |
| `parent-stack.yaml` | Nested stack orchestrator (EKS + IDE combined) |

### Deployment Options

```
Option A: Standalone (separate stacks)
  eks-full-stack.yaml  ──→  deploy independently
  ide-vscode.yaml      ──→  deploy independently, pass EKS VPC/Subnet

Option B: Nested Stack (single deploy)
  parent-stack.yaml
    ├── eks-full-stack.yaml    (child stack 1)
    └── ide-vscode.yaml        (child stack 2, optional via DeployIDE=true/false)
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| ClusterName | openclaw-prod | EKS cluster name |
| KubernetesVersion | 1.34 | EKS version |
| VpcCIDR | 172.31.0.0/16 | VPC CIDR block |
| AvailabilityZones | *(required)* | 3 AZs (e.g. us-east-1a,us-east-1b,us-east-1c) |
| SystemNodeInstanceTypes | m6g.xlarge | Managed node group instance type |
| SystemNodeDesiredCapacity | 2 | Desired node count |
| SystemNodeMinSize / MaxSize | 2 / 4 | Scaling bounds |
| NodeVolumeSize | 100 | EBS volume size (GB) |
| KarpenterVersion | 1.9.0 | Karpenter version (naming only) |

**China-only parameters:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| OIDCThumbprint | 9e99a48... | OIDC provider thumbprint (retrieve per region) |
| NodeAmiType | AL2023_ARM_64_STANDARD | AMI type (ARM64 or x86_64) |

## Resources (53 total)

### Networking (14 resources)

| Resource | Type | Description |
|----------|------|-------------|
| VPC | AWS::EC2::VPC | VPC with DNS support, tagged for EKS and Karpenter |
| InternetGateway | AWS::EC2::InternetGateway | Public internet access |
| IGWAttachment | AWS::EC2::VPCGatewayAttachment | Attach IGW to VPC |
| PublicSubnet1 | AWS::EC2::Subnet | Public subnet in AZ-1 (elb tagged) |
| PublicSubnet2 | AWS::EC2::Subnet | Public subnet in AZ-2 (elb tagged) |
| PublicSubnet3 | AWS::EC2::Subnet | Public subnet in AZ-3 (elb tagged) |
| PublicRouteTable | AWS::EC2::RouteTable | Public route table |
| PublicRoute | AWS::EC2::Route | 0.0.0.0/0 -> IGW |
| PublicSubnet1/2/3 RTA | AWS::EC2::SubnetRouteTableAssociation | Public subnet route associations (x3) |
| NATElasticIP | AWS::EC2::EIP | Elastic IP for NAT Gateway |
| NATGateway | AWS::EC2::NatGateway | Single NAT Gateway (cost-optimized) |
| PrivateSubnet1 | AWS::EC2::Subnet | Private subnet in AZ-1 (internal-elb + Karpenter tagged) |
| PrivateSubnet2 | AWS::EC2::Subnet | Private subnet in AZ-2 (internal-elb + Karpenter tagged) |
| PrivateSubnet3 | AWS::EC2::Subnet | Private subnet in AZ-3 (internal-elb + Karpenter tagged) |
| PrivateRouteTable | AWS::EC2::RouteTable | Private route table |
| PrivateRoute | AWS::EC2::Route | 0.0.0.0/0 -> NAT Gateway |
| PrivateSubnet1/2/3 RTA | AWS::EC2::SubnetRouteTableAssociation | Private subnet route associations (x3) |

### EKS Cluster (3 resources)

| Resource | Type | Description |
|----------|------|-------------|
| EKSCluster | AWS::EKS::Cluster | EKS control plane (public + private endpoint, CloudWatch logging) |
| ClusterRole | AWS::IAM::Role | Cluster IAM role (AmazonEKSClusterPolicy, VPCResourceController) |
| ClusterSecurityGroup | AWS::EC2::SecurityGroup | Cluster SG (tagged for Karpenter discovery) |

### OIDC Provider (1 resource)

| Resource | Type | Description |
|----------|------|-------------|
| OIDCProvider | AWS::IAM::OIDCProvider | OIDC identity provider for IRSA (ALB Controller, Karpenter) |

### Managed Node Group (4 resources)

| Resource | Type | Description |
|----------|------|-------------|
| SystemNodeGroup | AWS::EKS::Nodegroup | ARM64 Graviton nodes (AL2023, private subnets, labels: workload-type=standard) |
| NodeGroupRole | AWS::IAM::Role | Node IAM role (EKSWorkerNode, CNI, ECR, SSM policies) |
| NodeGroupInstanceProfile | AWS::IAM::InstanceProfile | Instance profile for node group |
| NodeLaunchTemplate | AWS::EC2::LaunchTemplate | gp3 encrypted EBS, IMDSv2 required |

### EKS Add-ons (5 resources)

| Resource | Type | Description |
|----------|------|-------------|
| VpcCniAddon | AWS::EKS::Addon | VPC CNI (Pod networking) |
| CoreDnsAddon | AWS::EKS::Addon | CoreDNS |
| KubeProxyAddon | AWS::EKS::Addon | kube-proxy |
| EbsCsiAddon | AWS::EKS::Addon | EBS CSI Driver (with Pod Identity association) |
| EbsCsiDriverRole | AWS::IAM::Role | EBS CSI IAM role (Pod Identity trust) |
| PodIdentityAddon | AWS::EKS::Addon | EKS Pod Identity Agent |

### EFS Infrastructure (6 resources)

| Resource | Type | Description |
|----------|------|-------------|
| EFSFileSystem | AWS::EFS::FileSystem | Encrypted, elastic throughput |
| EFSSecurityGroup | AWS::EC2::SecurityGroup | Allow NFS (TCP 2049) from VPC CIDR |
| EFSMountTarget1 | AWS::EFS::MountTarget | Mount target in private subnet AZ-1 |
| EFSMountTarget2 | AWS::EFS::MountTarget | Mount target in private subnet AZ-2 |
| EFSMountTarget3 | AWS::EFS::MountTarget | Mount target in private subnet AZ-3 |
| EFSCSIDriverPolicy | AWS::IAM::ManagedPolicy | EFS CSI permissions (Describe, CreateAccessPoint, DeleteAccessPoint) |
| EFSCSIDriverRole | AWS::IAM::Role | EFS CSI IAM role (Pod Identity trust) |

### ALB Controller IAM (2 resources)

| Resource | Type | Description |
|----------|------|-------------|
| ALBControllerPolicy | AWS::IAM::ManagedPolicy | Full ALB Controller policy (based on v2.11.0) |
| ALBControllerRole | AWS::IAM::Role | IRSA role for kube-system:aws-load-balancer-controller |

### Karpenter IAM & SQS (8 resources)

| Resource | Type | Description |
|----------|------|-------------|
| KarpenterNodeRole | AWS::IAM::Role | Node IAM role (EKSWorkerNode, CNI, ECR, SSM) |
| KarpenterNodeInstanceProfile | AWS::IAM::InstanceProfile | Instance profile for Karpenter-managed nodes |
| KarpenterControllerPolicy | AWS::IAM::ManagedPolicy | Scoped EC2/SQS/IAM/EKS/SSM/Pricing permissions |
| KarpenterControllerRole | AWS::IAM::Role | IRSA role for kube-system:karpenter |
| KarpenterInterruptionQueue | AWS::SQS::Queue | SQS queue for spot interruption handling |
| KarpenterInterruptionQueuePolicy | AWS::SQS::QueuePolicy | Allow EventBridge to send to SQS |
| ScheduledChangeRule | AWS::Events::Rule | AWS Health events -> SQS |
| SpotInterruptionRule | AWS::Events::Rule | EC2 Spot Interruption Warning -> SQS |
| RebalanceRule | AWS::Events::Rule | EC2 Instance Rebalance Recommendation -> SQS |
| InstanceStateChangeRule | AWS::Events::Rule | EC2 Instance State-change Notification -> SQS |

## Outputs

| Output | Description |
|--------|-------------|
| ClusterName | EKS cluster name |
| ClusterEndpoint | EKS API endpoint |
| ClusterOIDCIssuer | OIDC issuer URL |
| ClusterSecurityGroupId | Cluster SG (Karpenter tagged) |
| VpcId | VPC ID |
| PrivateSubnetIds | Private subnet IDs (comma-separated) |
| PublicSubnetIds | Public subnet IDs (comma-separated) |
| NodeGroupRoleArn | System node group IAM role ARN |
| EFSFileSystemId | EFS filesystem ID (for efs-sc StorageClass) |
| EFSCSIDriverRoleArn | EFS CSI IAM role ARN (for Pod Identity) |
| ALBControllerRoleArn | ALB Controller IAM role ARN (for Helm) |
| KarpenterControllerRoleArn | Karpenter controller IAM role ARN (for Helm) |
| KarpenterNodeRoleArn | Karpenter node IAM role ARN (for EC2NodeClass) |
| KarpenterInterruptionQueueName | SQS queue name (for Karpenter Helm) |

## Deploy

### Option A: Standalone (EKS only)

#### Global

```bash
aws cloudformation deploy \
  --stack-name openclaw-eks \
  --template-file cloudformation/eks-full-stack.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ClusterName=openclaw-prod \
    AvailabilityZones=us-east-1a,us-east-1b,us-east-1c \
  --region us-east-1
```

#### China

```bash
aws cloudformation deploy \
  --stack-name openclaw-eks \
  --template-file cloudformation/eks-full-stack-china.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ClusterName=openclaw-prod \
    AvailabilityZones=cn-northwest-1a,cn-northwest-1b,cn-northwest-1c \
    OIDCThumbprint=<your-thumbprint> \
    NodeAmiType=AL2023_ARM_64_STANDARD \
    SystemNodeInstanceTypes=m6g.xlarge \
  --region cn-northwest-1
```

### Option B: Nested Stack (EKS + IDE)

```bash
# 1. Create S3 bucket for templates
aws s3 mb s3://openclaw-cfn-templates --region us-east-1

# 2. Upload child templates
aws s3 cp cloudformation/eks-full-stack.yaml s3://openclaw-cfn-templates/
aws s3 cp cloudformation/ide-vscode.yaml s3://openclaw-cfn-templates/

# 3. Deploy parent stack
aws cloudformation deploy \
  --stack-name openclaw-platform \
  --template-file cloudformation/parent-stack.yaml \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --parameter-overrides \
    TemplateBucketName=openclaw-cfn-templates \
    ClusterName=openclaw-prod \
    AvailabilityZones=us-east-1a,us-east-1b,us-east-1c \
    DeployIDE=true \
  --region us-east-1

# 4. Grant IDE kubectl access (after deploy)
IDE_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name openclaw-platform --region us-east-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`IdeRoleArn`].OutputValue' --output text)

eksctl create iamidentitymapping \
  --cluster openclaw-prod --region us-east-1 \
  --arn "$IDE_ROLE_ARN" --username admin --group system:masters
```

### Option A+: Add IDE to existing EKS stack

```bash
# If you already deployed eks-full-stack.yaml standalone, deploy IDE separately:
VPC_ID=$(aws cloudformation describe-stacks \
  --stack-name openclaw-eks-test --region us-east-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' --output text)

PUBLIC_SUBNET=$(aws cloudformation describe-stacks \
  --stack-name openclaw-eks-test --region us-east-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`PublicSubnetIds`].OutputValue' --output text | cut -d, -f1)

aws cloudformation deploy \
  --stack-name openclaw-ide \
  --template-file cloudformation/ide-vscode.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    VpcId=$VPC_ID \
    PublicSubnetId=$PUBLIC_SUBNET \
    ClusterName=openclaw-eks-test \
  --region us-east-1
```

## Post-Deploy Steps

After stack creation, install Helm charts using values from Outputs:

```bash
# 1. Connect to cluster
aws eks update-kubeconfig --name <ClusterName> --region <region>

# 2. EFS CSI Driver
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm upgrade --install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.create=true \
  --set controller.serviceAccount.name=efs-csi-controller-sa

# Create Pod Identity association
aws eks create-pod-identity-association \
  --cluster-name <ClusterName> \
  --namespace kube-system \
  --service-account efs-csi-controller-sa \
  --role-arn <EFSCSIDriverRoleArn>

# 3. ALB Controller
helm repo add eks https://aws.github.io/eks-charts
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName=<ClusterName> \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=<ALBControllerRoleArn>"

# 4. Karpenter
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "1.9.0" \
  --namespace kube-system \
  --set "settings.clusterName=<ClusterName>" \
  --set "settings.interruptionQueue=<KarpenterInterruptionQueueName>" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=<KarpenterControllerRoleArn>"

# 5. StorageClasses
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: <EFSFileSystemId>
  directoryPerms: "700"
  basePath: /openclaw
  uid: "1000"
  gid: "1000"
mountOptions:
  - tls
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF

# 6. Karpenter NodePool + EC2NodeClass (see eksctl-deployment/configs/)
kubectl apply -f karpenter-standard-nodeclass.yaml
kubectl apply -f karpenter-standard-nodepool.yaml
```

## Cleanup

```bash
aws cloudformation delete-stack --stack-name openclaw-eks --region <region>
```

Note: Ensure all Kubernetes-created resources (LoadBalancers, EBS volumes, etc.) are deleted before stack deletion, otherwise CloudFormation may hang on VPC/subnet removal.
