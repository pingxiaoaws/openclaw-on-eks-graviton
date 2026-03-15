# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**OpenClaw Platform - eksctl Deployment System**

This directory contains the production-ready deployment automation for OpenClaw multi-tenant AI Agent platform on Amazon EKS. It replaces a failed CloudFormation approach (0% success rate) with eksctl (>95% success rate), reducing deployment time from 90+ minutes to 35 minutes.

**Current Status**: ✅ Production-ready, battle-tested with E2E test suite

**Key Technologies**:
- **Orchestration**: eksctl (declarative EKS cluster management)
- **Container Runtime**: containerd (runc) + Kata Containers (Firecracker/QEMU)
- **Storage**: EFS (cross-AZ, encrypted, dynamic provisioning)
- **Networking**: AWS Load Balancer Controller (internet-facing ALB)
- **Authentication**: Cognito JWT + CloudFront
- **Infrastructure**: ARM64 Graviton (m6g) for standard workloads, bare metal (c6g.metal) for Kata isolation

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Phase 1: EKS Cluster (20-35 min)                               │
│  01-deploy-eks-cluster.sh                                        │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  VPC (172.31.0.0/16, Single NAT)                          │  │
│  │  EKS 1.34 Control Plane                                   │  │
│  │  Node Groups:                                              │  │
│  │   - standard-nodes (m6g.xlarge/2xlarge, AL2023)           │  │
│  │   - kata-nodes (c6g.metal, Ubuntu 24.04) [optional]       │  │
│  │  Managed Add-ons:                                          │  │
│  │   - vpc-cni, coredns, kube-proxy, ebs-csi-driver          │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────────┐
│  Phase 2: Infrastructure Controllers (10-15 min)                │
│  02-deploy-controllers.sh                                        │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  EFS CSI Driver + FileSystem                              │  │
│  │   → StorageClass: efs-sc (dynamic provisioning)           │  │
│  │  AWS Load Balancer Controller                             │  │
│  │   → Creates internet-facing ALB                           │  │
│  │  EKS Pod Identity Agent                                    │  │
│  │   → IAM for Pods (IRSA replacement)                       │  │
│  │  Kata Containers [if kata nodes exist]                    │  │
│  │   → RuntimeClass: kata-fc, kata-qemu                      │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────────┐
│  Phase 3: Verification (1-2 min)                                │
│  03-verify-deployment.sh                                         │
│  → Validates 7 critical components                              │
└─────────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────────┐
│  Phase 4: Application Stack (20-30 min)                         │
│  04-deploy-application-stack.sh                                  │
│                                                                   │
│  [1/9] OpenClaw Operator (Helm/Kustomize)                       │
│  [2/9] Bedrock IAM Policy & Role (Pod Identity)                 │
│  [3/9] Pod Identity Association                                 │
│  [4/9] Cognito User Pool & Client                               │
│  [5/9] Docker Image Build (local or remote)                     │
│  [6/9] Provisioning Service Deployment                          │
│  [7/9] Convert ALB to internet-facing                           │
│  [8/9] CloudFront Distribution (HTTPS frontend)                 │
│  [9/9] Update Service with CloudFront config                    │
└─────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
eksctl-deployment/
├── configs/
│   ├── openclaw-cluster.yaml          # Standard cluster (m6g, no Kata)
│   └── openclaw-cluster-kata.yaml     # Kata cluster (+ c6g.metal)
│
├── scripts/
│   ├── 01-deploy-eks-cluster.sh       # Interactive cluster deployment
│   ├── 02-deploy-controllers.sh       # EFS, ALB, Pod Identity, Kata
│   ├── 03-verify-deployment.sh        # Comprehensive validation (7 checks)
│   ├── 04-deploy-application-stack.sh # Unified app deployment (9 steps)
│   ├── build-and-push-image.sh        # Standalone image builder
│   └── 06-cleanup-all-resources.sh    # Complete resource cleanup
│
├── testing/
│   ├── run-e2e-test.sh                # Automated E2E test orchestrator
│   ├── validate-phase1.sh             # Phase 1 validation
│   ├── validate-phase2.sh             # Phase 2 validation
│   ├── validate-phase4.sh             # Phase 4 validation
│   ├── test-user-access.sh            # Create test user, validate UI
│   ├── create-test-instance.sh        # Deploy and validate instance
│   ├── E2E-TEST-PLAN.md               # Complete test documentation
│   └── reports/                       # Automated test reports
│
├── examples/
│   └── openclaw-test-instance.yaml    # Sample instance (Kata + EFS)
│
└── docs/
    ├── README.md                       # Complete deployment guide
    ├── GETTING-STARTED.md              # Quick start (30 min to prod)
    ├── IMPLEMENTATION-COMPLETE.md      # Implementation summary
    └── CLEANUP-SCRIPT-GUIDE.md         # Cleanup documentation
```

## Common Commands

### Full Deployment Workflow

```bash
cd scripts

# Step 1: Deploy EKS cluster (interactive, choose standard or kata)
./01-deploy-eks-cluster.sh
# Prompts:
#   1) Standard cluster (m6g nodes only)
#   2) Kata cluster (m6g + c6g.metal)
# Time: 20-35 minutes

# Step 2: Install infrastructure controllers
./02-deploy-controllers.sh
# Installs: EFS, ALB Controller, Pod Identity, Kata (auto-detect)
# Time: 10-15 minutes

# Step 3: Verify deployment
./03-verify-deployment.sh
# Checks:
#   ✅ Cluster accessible
#   ✅ All nodes Ready
#   ✅ EFS CSI Driver + FileSystem
#   ✅ StorageClass efs-sc
#   ✅ ALB Controller
#   ✅ Pod Identity
#   ✅ Kata (if applicable)
# Time: 1-2 minutes

# Step 4: Deploy application stack (unified)
./04-deploy-application-stack.sh
# Deploys: Operator, Bedrock IAM, Cognito, Image, Service, CloudFront
# Time: 20-30 minutes
# Output: CloudFront URL, Cognito credentials

# Step 5: Create test user
aws cognito-idp admin-create-user \
  --user-pool-id <from-phase4-output> \
  --username test@example.com \
  --temporary-password 'TempPass123!' \
  --region <region>

# Step 6: Access UI
# Open: https://<cloudfront-domain>/login
```

### Testing and Validation

```bash
cd testing

# Automated E2E test (standard cluster)
./run-e2e-test.sh standard
# Runs all phases + validation + generates report
# Time: ~1.5-2 hours
# Cost: ~$5-10

# Automated E2E test (kata cluster)
./run-e2e-test.sh kata
# Requires SSH key: openclaw-kata-key
# Time: ~2-2.5 hours
# Cost: ~$30

# Manual validation (run after each phase)
./validate-phase1.sh   # After 01-deploy-eks-cluster.sh
./validate-phase2.sh   # After 02-deploy-controllers.sh
./validate-phase4.sh   # After 04-deploy-application-stack.sh

# Test user access
./test-user-access.sh  # Creates test user, validates UI

# Test instance creation
./create-test-instance.sh standard  # Standard runtime (runc)
./create-test-instance.sh kata      # Kata runtime (requires kata nodes)
```

### Cleanup

```bash
cd scripts

# Complete automated cleanup (RECOMMENDED)
./06-cleanup-all-resources.sh
# Deletes (in order):
#   - Kubernetes resources (all namespaces)
#   - CloudFront distribution (auto-disable + delete)
#   - Cognito User Pool
#   - Pod Identity associations
#   - EKS cluster (all node groups, addons)
#   - IAM roles & policies
#   - Security groups
#   - EFS FileSystem (optional, prompted)
# Time: 15-30 minutes
# Interactive: Requires cluster name + "DELETE" confirmation

# Quick cleanup (EKS only, NOT RECOMMENDED)
eksctl delete cluster --name <cluster-name> --region <region>
# ⚠️ Leaves orphaned: CloudFront, Cognito, IAM, EFS (ongoing costs!)
```

### Debugging

```bash
# Check script prerequisites
./01-deploy-eks-cluster.sh
# Validates: eksctl, kubectl, aws CLI, config file, SSH key (Kata)

# Check cluster context
kubectl config current-context
# Format: arn:aws:eks:<region>:<account>:cluster/<cluster-name>

# Get cluster info
CLUSTER_NAME=$(kubectl config current-context | cut -d'/' -f2)
AWS_REGION=$(kubectl config current-context | cut -d':' -f4)
aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION

# Check node status
kubectl get nodes -o wide
kubectl get nodes -l workload-type=kata   # Kata nodes only

# Check controllers
kubectl get pods -n kube-system | grep -E "efs-csi|aws-load-balancer|eks-pod-identity"

# Check EFS
aws efs describe-file-systems --region $AWS_REGION
kubectl get storageclass efs-sc

# Check application stack
kubectl get deployment -n openclaw-operator-system
kubectl get deployment -n openclaw-provisioning
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning

# Check environment variables (critical for phase 4)
kubectl get deployment openclaw-provisioning -n openclaw-provisioning \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq .

# Check CloudFront
aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='OpenClaw-$CLUSTER_NAME']" \
  --output table

# Check Cognito
aws cognito-idp list-user-pools --max-results 60 --region $AWS_REGION \
  --query "UserPools[?Name=='openclaw-users-$CLUSTER_NAME']"

# Check OpenClaw instances
kubectl get openclawinstances -A
kubectl describe openclawinstance -n <namespace>
```

### Development Workflow

```bash
# Modify cluster configuration
vim configs/openclaw-cluster.yaml
# Common changes:
#   - metadata.region: Target AWS region
#   - managedNodeGroups[].desiredCapacity: Node count
#   - managedNodeGroups[].instanceTypes: Instance types
#   - vpc.cidr: VPC CIDR range

# Update provisioning service code
cd ../eks-pod-service
# Make changes to app/

# Rebuild and redeploy image
cd ../eksctl-deployment/scripts
./build-and-push-image.sh
# Options:
#   1) Local build (requires Docker + ECR access)
#   2) Remote build (requires SSH to builder host)

# Update provisioning service deployment
kubectl rollout restart deployment openclaw-provisioning -n openclaw-provisioning
kubectl rollout status deployment openclaw-provisioning -n openclaw-provisioning

# Check logs
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning -f

# Test changes
cd ../testing
./validate-phase4.sh
./test-user-access.sh
```

## Configuration Files

### Cluster Configuration (`configs/openclaw-cluster.yaml`)

**Standard cluster** (no Kata):
- **Nodes**: 2-6x m6g.xlarge/2xlarge (ARM64 Graviton)
- **OS**: Amazon Linux 2023
- **Runtime**: containerd (runc)
- **Use case**: Development, testing, trusted single-tenant
- **Cost**: ~$300/month (2 nodes)

**Kata cluster** (`configs/openclaw-cluster-kata.yaml`):
- **Standard nodes**: 2-6x m6g.xlarge (system workloads)
- **Kata nodes**: 1-3x c6g.metal (VM-isolated workloads)
- **OS**: AL2023 (standard), Ubuntu 24.04 (Kata)
- **Runtime**: runc (standard), kata-fc/kata-qemu (Kata)
- **Use case**: Production multi-tenant, security-sensitive
- **Cost**: ~$4,000/month (2 standard + 1 Kata)

**Key configuration sections**:

```yaml
metadata:
  name: openclaw-prod
  region: us-east-1      # Deployment region
  version: "1.34"        # EKS version

vpc:
  cidr: 172.31.0.0/16    # VPC CIDR
  nat:
    gateway: Single      # Cost: ~$32/month

iam:
  withOIDC: true         # Required for Pod Identity

managedNodeGroups:
  - name: standard-nodes
    instanceTypes:
      - m6g.xlarge       # 4 vCPU, 16 GB RAM
      - m6g.2xlarge      # 8 vCPU, 32 GB RAM
    desiredCapacity: 2   # Min nodes for HA
    labels:
      workload-type: standard
      arch: arm64

# Kata nodegroup (only in openclaw-cluster-kata.yaml)
nodeGroups:
  - name: kata-nodes
    instanceType: c6g.metal    # Bare metal required for nested virt
    desiredCapacity: 1
    ssh:
      publicKeyName: openclaw-kata-key  # Must exist in region!
    preBootstrapCommands:      # Kata installation via user data
      - |
        #!/bin/bash
        # Install Kata Containers 3.27.0
        # Full script in config file

addons:
  - name: vpc-cni              # Pod networking
  - name: coredns              # DNS
  - name: kube-proxy           # kube-proxy
  - name: aws-ebs-csi-driver   # EBS volumes
```

### Instance Configuration (`examples/openclaw-test-instance.yaml`)

```yaml
apiVersion: openclaw.rocks/v1alpha1
kind: OpenClawInstance
metadata:
  name: test-instance
  namespace: openclaw

spec:
  config:
    raw:
      agents:
        defaults:
          model:
            primary: "bedrock/us.anthropic.claude-sonnet-4-5-..."

  envFrom:
    - secretRef:
        name: aws-credentials   # Or use Pod Identity

  availability:
    runtimeClassName: kata-qemu  # Options: null (runc), kata-fc, kata-qemu
    nodeSelector:
      workload-type: kata        # Remove for runc
    tolerations:
      - key: kata-dedicated
        operator: Exists

  resources:
    requests:
      cpu: "600m"       # +100m overhead for kata-qemu
      memory: "1.2Gi"   # +200Mi overhead for kata-qemu

  storage:
    persistence:
      enabled: true
      size: 10Gi
      storageClass: efs-sc    # EFS (ReadWriteMany, cross-AZ)
```

## Critical Implementation Details

### Runtime Selection: kata-fc vs kata-qemu vs runc

| Runtime | Start Time | Memory | EFS Persistence | Use Case |
|---------|-----------|--------|----------------|----------|
| **runc** (default) | ~1s | Base | ✅ Full (NFS4) | Standard workloads |
| **kata-fc** (Firecracker) | ~125ms | Base + 5MB | ❌ tmpfs (read-only from EFS) | Stateless, fast boot |
| **kata-qemu** (QEMU) | ~500ms | Base + 30MB | ✅ Full (virtiofs) | Stateful, VM isolation |

**⚠️ CRITICAL**: For persistent storage with Kata, **MUST use kata-qemu**. kata-fc uses tmpfs and **writes are not persisted to EFS**.

### Deployment Script Execution Order

Scripts MUST be run in sequence:

1. **01-deploy-eks-cluster.sh**
   - Creates VPC, EKS cluster, node groups
   - Installs managed add-ons (vpc-cni, coredns, kube-proxy, ebs-csi)
   - Kata user data runs on node boot (if Kata nodes)

2. **02-deploy-controllers.sh**
   - Creates EFS FileSystem + Mount Targets (one per AZ)
   - Installs EFS CSI Driver + StorageClass
   - Installs ALB Controller (for Ingress → ALB)
   - Installs Pod Identity agent
   - Deploys Kata DaemonSet (if Kata nodes detected)

3. **03-verify-deployment.sh**
   - Validates all components from Phase 1 & 2
   - **MUST pass all 7 checks** before proceeding to Phase 4

4. **04-deploy-application-stack.sh**
   - Installs OpenClaw Operator
   - Creates IAM resources (Bedrock policy + role + Pod Identity)
   - Creates Cognito User Pool + Client
   - Builds Docker image (provisioning service)
   - Deploys provisioning service with **ALL environment variables**
   - Converts ALB to internet-facing
   - Creates CloudFront distribution

### Environment Variables in Provisioning Service

**Critical**: Phase 4 sets these environment variables in the provisioning service deployment. **Missing any of these will cause failures**:

```bash
# Cognito (set by Phase 4)
COGNITO_REGION=<region>
COGNITO_USER_POOL_ID=us-west-2_ExAmPlE
COGNITO_CLIENT_ID=xxxxxxxxxxxxxxxxxxxxxxxxxx

# CloudFront (set by Phase 4)
CLOUDFRONT_DOMAIN=d1234567890abc.cloudfront.net
CLOUDFRONT_DISTRIBUTION_ID=E1234567890ABC

# AWS Infrastructure (set by Phase 4)
PUBLIC_ALB_DNS=internal-k8s-openclaw-....elb.amazonaws.com
SHARED_BEDROCK_ROLE_ARN=arn:aws:iam::111122223333:role/OpenClawBedrockRole
EKS_CLUSTER_NAME=openclaw-prod
AWS_ACCOUNT_ID=111122223333

# OpenClaw defaults (optional, defaults in config.py)
OPENCLAW_RUNTIME_CLASS=kata-fc
OPENCLAW_STORAGE_CLASS=efs-sc
```

**Validation**:
```bash
kubectl get deployment openclaw-provisioning -n openclaw-provisioning \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq .
```

### Troubleshooting Common Issues

**Issue**: Script fails with "eksctl not found"
```bash
# Install eksctl
brew install eksctl   # macOS
# Or: https://eksctl.io/installation/
```

**Issue**: Phase 1 fails with "SSH key not found" (Kata deployment)
```bash
# Create key in target region
aws ec2 create-key-pair --key-name openclaw-kata-key --region <region>
```

**Issue**: Phase 2 fails with "EFS mount timeout"
```bash
# Check security groups (NFS port 2049 must be open from VPC CIDR)
aws efs describe-mount-target-security-groups \
  --mount-target-id <mt-id> --region <region>
```

**Issue**: Phase 4 Cognito creation fails with "UserPool already exists"
```bash
# Delete existing pool
aws cognito-idp list-user-pools --max-results 60 --region <region>
aws cognito-idp delete-user-pool --user-pool-id <pool-id> --region <region>
```

**Issue**: CloudFront returns 502/503
```bash
# Check ALB security group (must allow TCP 80 from CloudFront prefix list)
aws ec2 describe-security-groups --group-ids <alb-sg> --region <region>

# Check ALB target health
aws elbv2 describe-target-health --target-group-arn <tg-arn> --region <region>

# Check provisioning service logs
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning
```

**Issue**: Instance creation fails with "RuntimeClass kata-fc not found"
```bash
# Check if Kata nodes exist and DaemonSet deployed
kubectl get nodes -l workload-type=kata
kubectl get ds -n kube-system -l name=kata-deploy
kubectl get runtimeclass kata-fc

# If missing, re-run Phase 2
cd scripts
./02-deploy-controllers.sh
```

**Issue**: EFS PVC stuck in Pending
```bash
# Check EFS CSI controller
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-efs-csi-driver

# Check StorageClass
kubectl get storageclass efs-sc -o yaml

# Check PVC events
kubectl describe pvc -n <namespace>
```

## Testing Framework

### Automated E2E Testing

```bash
cd testing

# Run full E2E test (standard cluster)
./run-e2e-test.sh standard

# What it does:
# 1. Runs 01-deploy-eks-cluster.sh (non-interactive)
# 2. Validates with validate-phase1.sh
# 3. Runs 02-deploy-controllers.sh
# 4. Validates with validate-phase2.sh
# 5. Runs 03-verify-deployment.sh
# 6. Runs 04-deploy-application-stack.sh
# 7. Validates with validate-phase4.sh
# 8. Creates test user with test-user-access.sh
# 9. Creates test instance with create-test-instance.sh
# 10. Prompts for cleanup
# 11. Generates test report in ./reports/

# Test report includes:
# - Execution timeline
# - All validation results
# - Component versions
# - Resource IDs
# - Pass/fail summary
```

### Validation Scripts

Each validation script checks specific components:

**validate-phase1.sh**:
- Cluster accessible (kubectl context)
- All nodes Ready
- System DaemonSets running (kube-proxy, aws-node)
- EBS CSI Controller ready
- (Kata) Kata nodes labeled `workload-type=kata`

**validate-phase2.sh**:
- EFS CSI Driver deployed (controller + node pods)
- EFS FileSystem available (via AWS API)
- StorageClass `efs-sc` exists
- ALB Controller ready
- Pod Identity agent running
- (Kata) RuntimeClass exists, test pod runs in VM

**validate-phase4.sh**:
- OpenClaw Operator deployed
- Bedrock IAM Role + Policy exist
- Pod Identity association created
- Cognito User Pool + Client exist
- Provisioning Service has **ALL** environment variables
- ALB is internet-facing
- CloudFront distribution deployed

## Cost Management

### Resource Costs (us-east-1, monthly estimates)

**Standard Cluster**:
| Resource | Config | Cost |
|----------|--------|------|
| EKS Control Plane | 1 cluster | $73 |
| m6g.xlarge | 2 nodes | $222 |
| NAT Gateway | Single | $32 |
| EFS | 50GB | $15 |
| EBS (gp3) | 200GB | $16 |
| ALB | 1 | $22 |
| **Total** | | **~$380/month** |

**Kata Cluster**:
| Resource | Config | Cost |
|----------|--------|------|
| EKS Control Plane | 1 cluster | $73 |
| m6g.xlarge | 2 standard | $222 |
| c6g.metal | 1 Kata | $3,528 |
| NAT Gateway | Single | $32 |
| EFS | 100GB | $30 |
| EBS (gp3) | 700GB | $56 |
| ALB | 1 | $22 |
| CloudFront | <1TB | $85 |
| Cognito | <50K MAU | Free |
| **Total** | | **~$4,048/month** |

**Cost Optimization**:
- Use Spot instances for standard nodes (save ~70%)
- Replace NAT Gateway with NAT instance (save ~$25/month)
- Remove CloudFront for internal-only access (save $85/month)
- Use c6g.2xlarge instead of c6g.metal for Kata (save ~$3,100/month, but limited capacity)

### Cleanup to Stop All Costs

```bash
cd scripts
./06-cleanup-all-resources.sh
# Deletes: EKS, CloudFront, Cognito, IAM, Security Groups
# Optional: EFS (prompted separately)
# Time: 15-30 minutes
```

## Related Documentation

- **Parent project**: `../CLAUDE.md` - Multi-tenant platform architecture
- **Operator**: `../../k8s-operator/CLAUDE.md` - OpenClaw Operator development
- **Provisioning service**: `../eks-pod-service/` - Multi-tenant API service
- **Kata deployment**: `../../kata-containers/` - Kata reference implementation

## Support and Debugging

**When things go wrong**:

1. **Check prerequisites** (Phase 1 script validates):
   ```bash
   eksctl version    # >= 0.150.0
   kubectl version   # >= 1.28
   aws --version     # >= 2.x
   ```

2. **Run verification script**:
   ```bash
   cd scripts
   ./03-verify-deployment.sh
   ```

3. **Check recent events**:
   ```bash
   kubectl get events -A --sort-by='.lastTimestamp' | tail -20
   ```

4. **Check specific component logs**:
   ```bash
   kubectl logs -n kube-system -l app.kubernetes.io/name=aws-efs-csi-driver
   kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
   kubectl logs -n openclaw-operator-system deployment/openclaw-operator
   kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning
   ```

5. **Validate specific phase**:
   ```bash
   cd testing
   ./validate-phase1.sh
   ./validate-phase2.sh
   ./validate-phase4.sh
   ```

6. **Consult troubleshooting docs**:
   - `README.md` - Section "故障排查" (comprehensive troubleshooting)
   - `E2E-TEST-PLAN.md` - Test-specific issues
   - `CLEANUP-SCRIPT-GUIDE.md` - Cleanup issues

---

**Last Updated**: 2026-03-15
**Maintained By**: Claude Code
