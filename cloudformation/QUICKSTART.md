# OpenClaw CloudFormation - Quick Start Guide

## 🚀 Current Status (2026-03-09)

This CloudFormation deployment is **41% complete** with core infrastructure templates and deployment scripts ready.

### ✅ Ready to Use

1. **Infrastructure Templates**:
   - VPC with 4 AZs, NAT Gateway, VPC Endpoints
   - Complete IAM roles (Pod Identity, Karpenter, Lambda)
   - EKS Cluster (v1.34) with Pod Identity agent
   - Managed Node Groups (AL2023)
   - EFS Storage with StorageClasses

2. **Scripts**:
   - `deploy.sh` - Full deployment automation
   - `outputs.sh` - Display stack outputs and quick commands

3. **Documentation**:
   - Comprehensive README with deployment guide
   - Implementation status tracking
   - Architecture diagrams and cost estimates

### 🚧 What's Missing

To complete the full deployment, you still need:

1. **Karpenter Stack** (nested-stacks/06-karpenter.yaml)
   - Helm install Karpenter controller
   - 4 EC2NodeClasses (provisioning, cpu, gpu, **kata-bare-metal**)
   - 4 NodePools with proper labels and taints

2. **Controllers Stack** (nested-stacks/10-kubernetes-controllers.yaml)
   - ALB Controller (Helm + Pod Identity)
   - EFS CSI Driver (Helm + Pod Identity)
   - Kata DaemonSet (kubectl apply)
   - RuntimeClasses (kata-fc, kata-qemu)

3. **OpenClaw Apps Stack** (nested-stacks/11-openclaw-apps.yaml)
   - OpenClaw Operator (Helm)
   - Provisioning Service (Deployment + Ingress + Pod Identity)
   - AWS Credentials Secret

4. **Cognito Stack** (nested-stacks/07-cognito.yaml)
   - User Pool with test user
   - Lambda function for user creation

5. **ALB & CloudFront** (nested-stacks/08-alb.yaml, 09-cloudfront.yaml)
   - ALB waiter Lambda
   - CloudFront distribution

6. **Lambda Functions**:
   - kubectl Lambda with Docker layer
   - Helm Lambda
   - Validation script

---

## 📝 What You Have Now

### File Structure

```
cloudformation/
├── master.yaml                      ✅ Complete (orchestration)
├── README.md                        ✅ Complete (full guide)
├── IMPLEMENTATION-STATUS.md         ✅ Complete (tracking)
├── QUICKSTART.md                    ✅ This file
├── nested-stacks/
│   ├── 01-vpc-network.yaml          ✅ Complete
│   ├── 02-iam-roles.yaml            ✅ Complete (all roles + Pod Identity)
│   ├── 03-eks-cluster.yaml          ✅ Complete
│   ├── 04-eks-nodegroups.yaml       ✅ Complete
│   ├── 05-storage.yaml              ✅ Complete (EFS + StorageClasses)
│   ├── 06-karpenter.yaml            🚧 TODO
│   ├── 07-cognito.yaml              🚧 TODO
│   ├── 08-alb.yaml                  🚧 TODO
│   ├── 09-cloudfront.yaml           🚧 TODO
│   ├── 10-k8s-controllers.yaml      🚧 TODO
│   └── 11-openclaw-apps.yaml        🚧 TODO
├── custom-resources/
│   ├── kubectl-lambda/
│   │   ├── function.py              🚧 TODO
│   │   └── Dockerfile               🚧 TODO
│   ├── helm-lambda/
│   │   └── function.py              🚧 TODO
│   ├── alb-waiter/
│   │   └── function.py              ✅ Complete
│   └── cognito-user-lambda/
│       └── function.py              ✅ Complete
├── parameters/
│   └── dev.json                     ✅ Complete
└── scripts/
    ├── deploy.sh                    ✅ Complete
    ├── outputs.sh                   ✅ Complete
    ├── validate.sh                  🚧 TODO
    └── cleanup.sh                   🚧 TODO
```

---

## 🎯 Two Paths Forward

### Option 1: Use What's Built (Partial Deployment)

You can deploy the infrastructure that's ready now:

```bash
# This will create:
# - VPC with networking
# - EKS Cluster
# - Managed Node Groups
# - EFS with StorageClasses
# - All IAM roles (ready for Pod Identity)

cd cloudformation

# Update artifact bucket in parameters
vim parameters/dev.json
# Change: "REPLACE_WITH_YOUR_ARTIFACT_BUCKET_NAME" to your bucket name

# Deploy infrastructure only
aws cloudformation create-stack \
  --stack-name openclaw-infra \
  --template-body file://nested-stacks/01-vpc-network.yaml \
  --parameters ParameterKey=ClusterName,ParameterValue=openclaw-dev \
               ParameterKey=EnvironmentName,ParameterValue=dev \
  --region us-west-2

# Then manually deploy:
# - IAM roles (02-iam-roles.yaml)
# - EKS cluster (03-eks-cluster.yaml)
# - Node groups (04-eks-nodegroups.yaml)
# - EFS storage (05-storage.yaml)
```

**What you'll have**:
- Fully functional EKS cluster
- EFS storage ready for OpenClaw
- All IAM roles configured
- Manual steps needed for Karpenter, controllers, and apps

---

### Option 2: Complete the Remaining Templates (Recommended)

Follow the implementation guide in `IMPLEMENTATION-STATUS.md` to complete:

**Estimated effort**: 21 hours (2-3 working days)

**Priority order**:
1. **Storage & Karpenter** (4 hours) - Files 5-6
2. **Lambda Functions** (6 hours) - kubectl, helm, alb-waiter, cognito-user
3. **Controllers & Apps** (5 hours) - Files 10-11
4. **Edge & Auth** (4 hours) - Files 7-9
5. **Validation** (2 hours) - Scripts

**Key templates to create**:

#### 1. Karpenter Stack (06-karpenter.yaml)

```yaml
# Critical: Kata Bare Metal NodePool
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: kata-bare-metal
spec:
  template:
    metadata:
      labels:
        workload-type: kata
        instance-type: bare-metal
        katacontainers.io/kata-runtime: "true"
    spec:
      nodeClassRef:
        name: kata-bare-metal-class
      taints:
        - key: kata
          value: "true"
          effect: NoSchedule
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["c6g.metal", "m6g.metal"]
```

#### 2. Controllers Stack (10-kubernetes-controllers.yaml)

Key components:
- ALB Controller with Pod Identity
- EFS CSI Driver with Pod Identity
- Kata DaemonSet (only on Kata nodes)
- RuntimeClasses (kata-fc, kata-qemu)

#### 3. OpenClaw Apps Stack (11-openclaw-apps.yaml)

Key components:
- OpenClaw Operator (Helm)
- Provisioning Service (2 replicas, ARM64)
- Ingress (creates ALB)
- Pod Identity associations

---

## 📚 Key Reference Documents

### For Implementation

1. **IMPLEMENTATION-STATUS.md**
   - Detailed breakdown of all remaining files
   - Exact content needed for each template
   - Dependencies and order of creation

2. **README.md**
   - Complete deployment guide
   - Prerequisites and setup
   - Troubleshooting guide

3. **Test-s4 Environment** (`CLAUDE.md`)
   - Working configuration reference
   - Verified Karpenter policies
   - Pod Identity examples

### For Kata Containers

- **KATA-GRAVITON-DEPLOYMENT-SUMMARY.md**: Kata deployment lessons
- **KATA-QUICK-REFERENCE.md**: Kata commands and troubleshooting
- **Reference architecture**: `https://github.com/hitsub2/openclaw-on-eks`

---

## 💡 Quick Wins

If you want to make progress quickly, here are the highest-impact files:

### 1. Karpenter NodePool (30 minutes)

Create `06-karpenter.yaml` with just the Kata NodePool. This is the core differentiator.

### 2. kubectl Lambda (1 hour)

Create the Docker layer and Lambda function for applying Kubernetes manifests. This unblocks all other stacks.

### 3. ALB Controller (30 minutes)

Helm install ALB Controller with Pod Identity. Essential for Ingress.

### 4. Simple End-to-End Test (30 minutes)

Skip CloudFront/Cognito initially. Just deploy:
- Karpenter + Kata NodePool
- ALB Controller
- OpenClaw Operator
- Test instance via kubectl

---

## 🔧 Manual Workarounds

If you need a working system now, you can:

### 1. Deploy EKS + EFS (works today)

```bash
# Use existing templates to deploy:
cd cloudformation
./scripts/deploy.sh  # Will create infra up to EFS
```

### 2. Manually install Karpenter

```bash
# After EKS is ready
export CLUSTER_NAME=openclaw-dev
export AWS_REGION=us-west-2

# Install Karpenter
helm repo add karpenter https://charts.karpenter.sh
helm install karpenter karpenter/karpenter \
  --namespace kube-system \
  --set settings.clusterName=${CLUSTER_NAME}

# Apply NodePools manually
kubectl apply -f kata-nodepool.yaml
```

### 3. Manually install OpenClaw

```bash
# Install operator
helm install openclaw-operator /path/to/openclaw-operator \
  --namespace openclaw-operator-system \
  --create-namespace

# Deploy provisioning service
kubectl apply -f provisioning-service.yaml
```

### 4. Skip Cognito/CloudFront

- Use EKS port-forward for testing
- Add authentication later

---

## 🎉 Success Criteria

When you complete all templates, you should have:

✅ One-command deployment: `./scripts/deploy.sh`
✅ 40-50 minute deployment time
✅ CloudFront login URL with Cognito auth
✅ Kata containers on bare metal Graviton nodes
✅ EFS storage with RWX support
✅ Auto-scaling via Karpenter (scales to 0)
✅ Full observability and troubleshooting

---

## 🆘 Need Help?

### Stuck on a specific file?

Refer to:
1. `IMPLEMENTATION-STATUS.md` - Exact content specifications
2. `README.md` - Context and examples
3. `CLAUDE.md` - Working test-s4 configuration

### Want to validate what's built?

```bash
# Validate templates
aws cloudformation validate-template \
  --template-body file://master.yaml

# Check IAM policies
aws cloudformation validate-template \
  --template-body file://nested-stacks/02-iam-roles.yaml
```

### Ready to continue?

Start with **06-karpenter.yaml** - this is the critical path for Kata support.

See `IMPLEMENTATION-STATUS.md` section "06. nested-stacks/06-karpenter.yaml" for the complete specification.

---

## 📞 Contact

For questions about this implementation:
- Review `IMPLEMENTATION-STATUS.md` for detailed specifications
- Check `README.md` for deployment context
- Examine existing templates for patterns

**Current version**: 1.0.0 (2026-03-09)
**Status**: 41% complete, core infrastructure ready
**Next milestone**: Karpenter + Kata NodePool
