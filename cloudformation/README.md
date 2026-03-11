# OpenClaw Platform - CloudFormation Deployment Guide

## 🎯 Overview

This CloudFormation template deploys a complete OpenClaw multi-tenant platform on AWS EKS with:

- **EKS Cluster** (Kubernetes 1.34) with Pod Identity
- **Kata Containers** via Karpenter on bare metal Graviton nodes (AL2023)
- **EFS Storage** with RWX support
- **Cognito Authentication**
- **CloudFront CDN** for global edge access
- **ALB** for internal routing
- **OpenClaw Operator** and Provisioning Service

## 📋 Prerequisites

### Required Tools

```bash
# Install AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Install kubectl
curl -LO "https://dl.k8s.io/release/v1.34.0/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# Install helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install jq
sudo apt-get install jq  # Ubuntu/Debian
brew install jq          # macOS
```

### AWS Permissions

Your AWS IAM user/role must have permissions to create:
- VPC, Subnets, Route Tables, NAT Gateway, IGW
- EKS Cluster, Node Groups
- IAM Roles, Policies, Instance Profiles
- EFS File Systems, Mount Targets
- ALB, CloudFront Distributions
- Cognito User Pools
- Lambda Functions
- Secrets Manager Secrets
- CloudFormation Stacks

### AWS Account Quotas

Verify the following service quotas in your AWS account:

| Service | Quota | Required |
|---------|-------|----------|
| VPC | VPCs per Region | 1 |
| EKS | Clusters per Region | 1 |
| EC2 | c6g.metal instances | 2+ |
| EC2 | m6g.metal instances | 2+ |
| EFS | File Systems per Region | 1 |
| Cognito | User Pools per Region | 1 |
| CloudFront | Distributions per Account | 1 |

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         CloudFront CDN                           │
│                  (Global Edge Distribution)                      │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Application Load Balancer                    │
│                 (Internal Routing + SSL Termination)             │
└─────────────────────────┬───────────────────────────────────────┘
                          │
        ┌─────────────────┴─────────────────┐
        │                                   │
        ▼                                   ▼
┌──────────────────┐             ┌──────────────────────┐
│  Provisioning    │             │   OpenClaw Operator  │
│    Service       │             │   (Helm Deployed)    │
│  (2 replicas)    │             └──────────────────────┘
└──────────────────┘                       │
        │                                  │
        │    ┌───────────────────────────┐ │
        └────┤  EKS Cluster (1.34)       ├─┘
             │  - Pod Identity Enabled   │
             │  - AL2023 Node Groups     │
             │  - Karpenter Autoscaler   │
             └───────────┬───────────────┘
                         │
        ┌────────────────┼────────────────┐
        │                │                │
        ▼                ▼                ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────────┐
│ Standard     │  │  Karpenter   │  │  Kata NodePool   │
│ Node Group   │  │  NodePools   │  │  (Bare Metal)    │
│ (m5/m6g)     │  │ (CPU/GPU)    │  │  - c6g.metal     │
└──────────────┘  └──────────────┘  │  - m6g.metal     │
                                    │  - AL2023        │
                                    │  - NVMe RAID0    │
                                    └──────────────────┘
        │                                  │
        └──────────────┬───────────────────┘
                       │
                       ▼
        ┌──────────────────────────────┐
        │  EFS Elastic File System     │
        │  - 4 Mount Targets (4 AZs)   │
        │  - RWX StorageClass          │
        └──────────────────────────────┘
```

## 📦 Deployment Steps

### Step 1: Prepare Artifacts Bucket

```bash
# Set variables
export AWS_REGION=us-west-2
export STACK_NAME=openclaw-platform
export ARTIFACT_BUCKET="${STACK_NAME}-artifacts-$(date +%s)"

# Create S3 bucket
aws s3 mb s3://${ARTIFACT_BUCKET} --region ${AWS_REGION}

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket ${ARTIFACT_BUCKET} \
  --versioning-configuration Status=Enabled \
  --region ${AWS_REGION}

# Upload CloudFormation templates
cd cloudformation
aws s3 sync . s3://${ARTIFACT_BUCKET}/cloudformation/ \
  --exclude ".git/*" \
  --exclude "*.md" \
  --region ${AWS_REGION}
```

### Step 2: Build and Upload Lambda Layers

#### kubectl Lambda Layer

```bash
cd custom-resources/kubectl-lambda

# Build Docker image
docker build -t kubectl-lambda-layer .

# Extract layer
docker create --name kubectl-temp kubectl-lambda-layer
docker cp kubectl-temp:/opt/layer.zip kubectl-layer.zip
docker rm kubectl-temp

# Upload to S3
aws s3 cp kubectl-layer.zip \
  s3://${ARTIFACT_BUCKET}/lambda-layers/kubectl-layer.zip \
  --region ${AWS_REGION}

# Publish Lambda layer
aws lambda publish-layer-version \
  --layer-name kubectl-layer \
  --description "kubectl and helm for EKS management" \
  --license-info "Apache-2.0" \
  --content S3Bucket=${ARTIFACT_BUCKET},S3Key=lambda-layers/kubectl-layer.zip \
  --compatible-runtimes python3.12 \
  --region ${AWS_REGION} \
  | jq -r '.LayerVersionArn' > kubectl-layer-arn.txt

export KUBECTL_LAYER_ARN=$(cat kubectl-layer-arn.txt)
echo "kubectl Layer ARN: ${KUBECTL_LAYER_ARN}"
```

#### Helm Lambda Layer

```bash
cd ../helm-lambda

# Package Lambda function
zip -r helm-lambda.zip function.py requirements.txt
aws s3 cp helm-lambda.zip \
  s3://${ARTIFACT_BUCKET}/lambda-functions/helm-lambda.zip \
  --region ${AWS_REGION}
```

#### ALB Waiter Lambda

```bash
cd ../alb-waiter

zip -r alb-waiter-lambda.zip function.py
aws s3 cp alb-waiter-lambda.zip \
  s3://${ARTIFACT_BUCKET}/lambda-functions/alb-waiter-lambda.zip \
  --region ${AWS_REGION}
```

#### Cognito User Lambda

```bash
cd ../cognito-user-lambda

zip -r cognito-user-lambda.zip function.py
aws s3 cp cognito-user-lambda.zip \
  s3://${ARTIFACT_BUCKET}/lambda-functions/cognito-user-lambda.zip \
  --region ${AWS_REGION}
```

### Step 3: Configure Deployment Parameters

Edit `parameters/dev.json`:

```json
[
  {
    "ParameterKey": "EnvironmentName",
    "ParameterValue": "dev"
  },
  {
    "ParameterKey": "ArtifactBucket",
    "ParameterValue": "YOUR_ARTIFACT_BUCKET_NAME"
  },
  {
    "ParameterKey": "ClusterName",
    "ParameterValue": "openclaw-dev"
  },
  {
    "ParameterKey": "ClusterVersion",
    "ParameterValue": "1.34"
  },
  {
    "ParameterKey": "StandardNodeInstanceType",
    "ParameterValue": "m5.large"
  },
  {
    "ParameterKey": "StandardNodeDesiredSize",
    "ParameterValue": "2"
  },
  {
    "ParameterKey": "StandardNodeMinSize",
    "ParameterValue": "2"
  },
  {
    "ParameterKey": "StandardNodeMaxSize",
    "ParameterValue": "5"
  },
  {
    "ParameterKey": "KataInstanceTypes",
    "ParameterValue": "c6g.metal,m6g.metal"
  },
  {
    "ParameterKey": "KataNodePoolCpuLimit",
    "ParameterValue": "1000"
  },
  {
    "ParameterKey": "KataNodePoolMemoryLimit",
    "ParameterValue": "1000Gi"
  },
  {
    "ParameterKey": "TestUserEmail",
    "ParameterValue": "testuser@example.com"
  },
  {
    "ParameterKey": "OpenClawProvisioningImage",
    "ParameterValue": "111122223333.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest"
  },
  {
    "ParameterKey": "OpenClawOperatorVersion",
    "ParameterValue": "0.10.7"
  }
]
```

Replace `YOUR_ARTIFACT_BUCKET_NAME` with the bucket name from Step 1.

### Step 4: Deploy CloudFormation Stack

```bash
# Validate template
aws cloudformation validate-template \
  --template-body file://master.yaml \
  --region ${AWS_REGION}

# Create stack
aws cloudformation create-stack \
  --stack-name ${STACK_NAME} \
  --template-body file://master.yaml \
  --parameters file://parameters/dev.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${AWS_REGION} \
  --on-failure DELETE \
  --tags Key=Environment,Value=dev Key=Project,Value=openclaw

# Monitor stack creation (40-50 minutes)
aws cloudformation wait stack-create-complete \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION}

# Check status
aws cloudformation describe-stacks \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'Stacks[0].StackStatus'
```

### Step 5: Retrieve Outputs

```bash
# Get all outputs
aws cloudformation describe-stacks \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'Stacks[0].Outputs' \
  --output table

# Get specific outputs
export CLOUDFRONT_URL=$(aws cloudformation describe-stacks \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDomainName`].OutputValue' \
  --output text)

export USER_POOL_ID=$(aws cloudformation describe-stacks \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`UserPoolId`].OutputValue' \
  --output text)

export TEST_PASSWORD_SECRET_ARN=$(aws cloudformation describe-stacks \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`TestUserPasswordSecretArn`].OutputValue' \
  --output text)

# Get test user password
export TEST_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id ${TEST_PASSWORD_SECRET_ARN} \
  --query SecretString \
  --output text \
  --region ${AWS_REGION})

echo "============================================"
echo "OpenClaw Platform Deployed Successfully!"
echo "============================================"
echo "Login URL: https://${CLOUDFRONT_URL}/login"
echo "Email: testuser@example.com"
echo "Password: ${TEST_PASSWORD}"
echo "============================================"
```

### Step 6: Configure kubectl Access

```bash
# Update kubeconfig
aws eks update-kubeconfig \
  --name $(aws cloudformation describe-stacks \
    --stack-name ${STACK_NAME} \
    --region ${AWS_REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`ClusterName`].OutputValue' \
    --output text) \
  --region ${AWS_REGION}

# Verify cluster access
kubectl get nodes
kubectl get pods -A
```

## 🔍 Verification

### Check Cluster Health

```bash
# Verify nodes
kubectl get nodes -o wide

# Expected output:
# NAME                                         STATUS   ROLES    AGE   VERSION
# ip-172-31-xx-xx.us-west-2.compute.internal   Ready    <none>   5m    v1.34.x
# ip-172-31-yy-yy.us-west-2.compute.internal   Ready    <none>   5m    v1.34.x
```

### Check Kata RuntimeClasses

```bash
kubectl get runtimeclass

# Expected output:
# NAME         HANDLER      AGE
# kata-fc      kata-fc      10m
# kata-qemu    kata-qemu    10m
```

### Check Controllers

```bash
# ALB Controller
kubectl get deployment -n kube-system aws-load-balancer-controller

# EFS CSI Driver
kubectl get daemonset -n kube-system efs-csi-node

# Karpenter
kubectl get deployment -n kube-system karpenter

# OpenClaw Operator
kubectl get deployment -n openclaw-operator-system openclaw-operator

# Provisioning Service
kubectl get deployment -n openclaw-provisioning openclaw-provisioner
```

### Verify EFS Storage

```bash
# Check StorageClass
kubectl get storageclass efs-sc

# Test PVC creation
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-efs-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 10Gi
EOF

kubectl get pvc test-efs-pvc
# Expected: STATUS=Bound
```

### Test Kata Container

```bash
# Create test pod with Kata runtime
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-kata
  namespace: default
spec:
  runtimeClassName: kata-qemu
  nodeSelector:
    workload-type: kata
  tolerations:
    - key: kata
      operator: Exists
      effect: NoSchedule
  containers:
    - name: test
      image: busybox:latest
      command: ['sh', '-c', 'uname -a && sleep 3600']
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
EOF

# Wait for pod to be scheduled (Karpenter will create a bare metal node)
kubectl wait --for=condition=Ready pod/test-kata --timeout=10m

# Verify VM kernel
kubectl exec test-kata -- uname -a
# Expected: Linux test-kata 6.18.x ... (Kata VM kernel, not host kernel)

# Check node
kubectl get pod test-kata -o jsonpath='{.spec.nodeName}'
kubectl get node <NODE_NAME> -o jsonpath='{.metadata.labels}' | jq
# Expected labels: workload-type=kata, instance-type=bare-metal
```

### Test CloudFront Access

```bash
# Test CloudFront endpoint
curl -I https://${CLOUDFRONT_URL}/health

# Expected: HTTP/2 200
```

## 🎨 Creating Your First OpenClaw Instance

### Via kubectl

```bash
cat <<EOF | kubectl apply -f -
apiVersion: openclaw.rocks/v1alpha1
kind: OpenClawInstance
metadata:
  name: my-first-instance
  namespace: openclaw
spec:
  config:
    raw:
      agents:
        defaults:
          model:
            primary: "bedrock/us.anthropic.claude-opus-4-6-v1:0"

  # Use Kata runtime for VM isolation
  availability:
    runtimeClassName: kata-qemu
    nodeSelector:
      workload-type: kata
    tolerations:
      - key: kata
        operator: Exists
        effect: NoSchedule

  # Use EFS for persistent storage
  storage:
    persistence:
      enabled: true
      size: 10Gi
      storageClassName: efs-sc
      accessModes:
        - ReadWriteMany

  resources:
    requests:
      cpu: "600m"
      memory: "1.2Gi"
    limits:
      cpu: "2"
      memory: "4Gi"

  networking:
    service:
      type: ClusterIP

  security:
    podSecurityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
      runAsNonRoot: true
    containerSecurityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: false
      capabilities:
        drop:
          - ALL
EOF

# Monitor instance creation
kubectl get openclawinstance my-first-instance -n openclaw -w

# Check pod
kubectl get pod -n openclaw -l app.kubernetes.io/instance=my-first-instance

# Verify it's running in Kata
kubectl get pod -n openclaw -l app.kubernetes.io/instance=my-first-instance \
  -o jsonpath='{.items[0].spec.runtimeClassName}'
# Expected: kata-qemu
```

### Via UI (Provisioning Service)

1. Login to CloudFront URL with test user credentials
2. Navigate to "Create Instance"
3. Fill in instance details:
   - Name: `my-first-instance`
   - Model: `bedrock/us.anthropic.claude-opus-4-6-v1:0`
   - Runtime: `kata-qemu` (for VM isolation)
   - Storage: `10Gi` (EFS)
4. Click "Create"
5. Monitor creation progress
6. Access instance via UI

## 🔧 Troubleshooting

### Stack Creation Failed

```bash
# Get failed resources
aws cloudformation describe-stack-events \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION} \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`]' \
  --output table

# Check CloudWatch logs for Lambda errors
aws logs tail /aws/lambda/kubectl-lambda --follow
```

### Kata Nodes Not Created

```bash
# Check Karpenter logs
kubectl logs -n kube-system deployment/karpenter --tail=100

# Verify NodePool
kubectl get nodepool kata-bare-metal -o yaml

# Check EC2 instances
aws ec2 describe-instances \
  --filters "Name=tag:karpenter.sh/nodepool,Values=kata-bare-metal" \
  --region ${AWS_REGION} \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,Type:InstanceType}' \
  --output table
```

### EFS Mount Issues

```bash
# Check EFS mount targets
aws efs describe-mount-targets \
  --file-system-id $(aws cloudformation describe-stacks \
    --stack-name ${STACK_NAME} \
    --region ${AWS_REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`EfsFileSystemId`].OutputValue' \
    --output text) \
  --region ${AWS_REGION}

# Check EFS CSI driver pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-efs-csi-driver
```

### ALB Not Created

```bash
# Check ALB Controller logs
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=100

# Verify Ingress
kubectl get ingress -n openclaw-provisioning openclaw-provisioner-ingress -o yaml

# Check ALB in AWS Console
aws elbv2 describe-load-balancers \
  --region ${AWS::Region} \
  --query 'LoadBalancers[?Tags[?Key==`elbv2.k8s.aws/cluster`&&Value==`openclaw-dev`]]'
```

### CloudFront 502/504 Errors

```bash
# Check ALB health
aws elbv2 describe-target-health \
  --target-group-arn <TARGET_GROUP_ARN> \
  --region ${AWS_REGION}

# Check CloudFront distribution status
aws cloudfront get-distribution \
  --id <DISTRIBUTION_ID> \
  --query 'Distribution.Status'
```

## 🧹 Cleanup

### Delete CloudFormation Stack

```bash
# Delete stack (this will delete all resources)
aws cloudformation delete-stack \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION}

# Wait for deletion
aws cloudformation wait stack-delete-complete \
  --stack-name ${STACK_NAME} \
  --region ${AWS_REGION}
```

### Manual Cleanup (if needed)

```bash
# Delete artifact bucket
aws s3 rm s3://${ARTIFACT_BUCKET} --recursive
aws s3 rb s3://${ARTIFACT_BUCKET}

# Delete Lambda layers
aws lambda list-layer-versions --layer-name kubectl-layer \
  | jq -r '.LayerVersions[].LayerVersionArn' \
  | xargs -I {} aws lambda delete-layer-version --version-number {} --layer-name kubectl-layer
```

## 📊 Cost Estimation

Approximate monthly costs for dev environment (us-west-2):

| Resource | Quantity | Unit Cost | Monthly Cost |
|----------|----------|-----------|--------------|
| EKS Cluster | 1 | $0.10/hour | $73 |
| c6g.metal (on-demand) | 0-2 | $3.264/hour | $0-$470 (Karpenter scales to 0) |
| m5.large (managed nodes) | 2 | $0.096/hour | $140 |
| NAT Gateway | 1 | $0.045/hour + data | $33 + data |
| EFS (elastic) | 50GB | $0.30/GB-month | $15 |
| ALB | 1 | $0.0225/hour + LCU | $16 + LCU |
| CloudFront | 1 | Data transfer + requests | Variable |
| Cognito | < 50K MAU | Free | $0 |
| **Total (base)** | | | **~$277/month** |

**Note**: Kata nodes (bare metal) only run when instances are scheduled, significantly reducing costs when idle.

## 🔒 Security Considerations

### Pod Identity vs IRSA

This deployment uses **EKS Pod Identity** (not IRSA):
- ✅ No OIDC provider required
- ✅ Simpler trust policies (`pods.eks.amazonaws.com`)
- ✅ Native EKS addon (`eks-pod-identity-agent`)
- ✅ Per-pod IAM role associations

### Network Security

- Private subnets for all compute
- Security groups with least privilege
- VPC endpoints for AWS services (S3, ECR)
- CloudFront with HTTPS only

### Kata Containers Isolation

- VM-level isolation for workloads
- Separate guest kernel (6.18.x)
- Secure by default (no privileged containers)

## 📚 References

- [EKS Documentation](https://docs.aws.amazon.com/eks/)
- [Kata Containers](https://katacontainers.io/)
- [Karpenter](https://karpenter.sh/)
- [OpenClaw Operator](https://github.com/openclaw/openclaw-operator)

## 🤝 Support

For issues and questions:
- GitHub Issues: [openclaw-cloudformation-issues](https://github.com/openclaw/cloudformation/issues)
- Slack: [#openclaw-support](https://openclaw.slack.com)
- Email: support@openclaw.io

---

**Last Updated**: 2026-03-09
**Version**: 1.0.0
**Maintainer**: OpenClaw Team
