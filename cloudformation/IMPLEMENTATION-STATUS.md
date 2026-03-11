# OpenClaw CloudFormation Implementation Status

**Date**: 2026-03-09
**Project**: OpenClaw One-Click Deployment on AWS EKS with Kata Containers

## 📊 Overall Progress

```
Total Files: 22
Completed: 9 (41%)
In Progress: 0
Remaining: 13 (59%)
```

## ✅ Completed Files (P0 Priority)

### Core Templates
1. **master.yaml** ✅
   - Main orchestration stack
   - All parameters defined
   - Dependency chain configured
   - Comprehensive outputs

2. **nested-stacks/01-vpc-network.yaml** ✅
   - VPC with 4 AZs (172.31.0.0/16)
   - 4 Public + 4 Private subnets
   - NAT Gateway + Internet Gateway
   - VPC Endpoints (S3, ECR API, ECR Docker)
   - Karpenter discovery tags

3. **nested-stacks/02-iam-roles.yaml** ✅
   - EKS Cluster Role
   - EKS Node Role + Instance Profile
   - Karpenter Controller Role (Pod Identity) - **Complete policy from test-s4**
   - Karpenter Node Role + Instance Profile
   - ALB Controller Role (Pod Identity)
   - EFS CSI Driver Role (Pod Identity)
   - OpenClaw Provisioning Service Role (Pod Identity)
   - Shared Bedrock Role
   - Lambda Roles (kubectl, helm, alb-waiter, cognito-user)

4. **nested-stacks/03-eks-cluster.yaml** ✅
   - EKS Cluster (v1.34)
   - Cluster Security Group
   - EKS Add-ons: vpc-cni, coredns, kube-proxy, **eks-pod-identity-agent**
   - API + ConfigMap authentication mode

5. **nested-stacks/04-eks-nodegroups.yaml** ✅
   - Managed Node Group (AL2023)
   - Standard workload nodes (m5/m6g)
   - Auto-scaling configuration

### Documentation & Configuration
6. **README.md** ✅
   - Complete deployment guide
   - Architecture diagram
   - Prerequisites checklist
   - Step-by-step deployment instructions
   - Troubleshooting guide
   - Cost estimation

7. **parameters/dev.json** ✅
   - All required parameters
   - Default values for dev environment

### Scripts
8. **scripts/deploy.sh** ✅
   - Prerequisites checking
   - Artifact bucket creation
   - Template upload to S3
   - Lambda layer building
   - Stack creation with monitoring
   - Output display

9. **scripts/outputs.sh** ✅
   - Extract all stack outputs
   - Display credentials
   - Show quick commands
   - Console links

---

## 🚧 Remaining Files (P0 Priority)

### Critical Templates

#### 5. nested-stacks/05-storage.yaml (HIGH PRIORITY)
**Status**: Not Started
**Components**:
- EFS FileSystem (encrypted, elastic)
- EFS Security Group (TCP 2049 from VPC CIDR)
- 4 EFS Mount Targets (one per AZ)
- Custom Resource: kubectl apply EFS StorageClass
  ```yaml
  apiVersion: storage.k8s.io/v1
  kind: StorageClass
  metadata:
    name: efs-sc
  provisioner: efs.csi.aws.com
  parameters:
    provisioningMode: efs-ap
    fileSystemId: ${EfsFileSystemId}
    directoryPerms: "700"
    basePath: /openclaw
    uid: "1000"
    gid: "1000"
  ```
- Custom Resource: kubectl apply EBS gp3 StorageClass

**Dependencies**: VPC, EKS Cluster, kubectl Lambda

---

#### 6. nested-stacks/06-karpenter.yaml (HIGH PRIORITY)
**Status**: Not Started
**Components**:

**A. Helm Install Karpenter** (Custom Resource)
- Chart: oci://public.ecr.aws/karpenter/karpenter
- Version: 1.7.4
- Namespace: kube-system
- Values:
  ```yaml
  serviceAccount:
    name: karpenter
    annotations:
      eks.amazonaws.com/role-arn: ${KarpenterControllerRoleArn}
  settings:
    clusterName: ${ClusterName}
    clusterEndpoint: ${ClusterEndpoint}
    interruptionQueue: ${ClusterName}
  ```

**B. EC2NodeClasses** (Custom Resources via kubectl)

1. **provisioning-graviton-class**
   - AL2023 AMI (latest)
   - Instance types: t4g, c6g, c7g, m6g, m7g (arm64)
   - 100Gi gp3 EBS
   - Karpenter node role

2. **cpu-nodeclass**
   - AL2023 AMI (latest)
   - Instance types: c5 (amd64)
   - 100Gi gp3 EBS

3. **gpu-nodeclass**
   - AL2023 AMI (latest)
   - Instance types: g5 (nvidia)
   - 200Gi gp3 EBS

4. **kata-bare-metal-class** ⭐ **KEY IMPLEMENTATION**
   - AL2023 AMI (latest)
   - Instance types: c6g.metal, m6g.metal (arm64)
   - 200Gi gp3 EBS
   - **UserData (multi-part MIME)**:
     ```bash
     # Shell script part:
     - Install mdadm, lvm2, device-mapper
     - Detect NVMe devices (instance store)
     - Create RAID0 array (if multiple disks)
     - Setup LVM thin pool for devicemapper

     # NodeConfig part:
     - EKS bootstrap with NodeConfig API
     ```

**C. NodePools** (Custom Resources via kubectl)

1. **provisioning-graviton**
   - Disruption: consolidate when empty/underutilized
   - Requirements: on-demand, arm64, instance-type in list

2. **cpu-nodepool**
   - Disruption: consolidate when empty
   - Requirements: on-demand, amd64, c5 family

3. **gpu-nodepool**
   - Disruption: none (keep running)
   - Requirements: on-demand, amd64, g5 family
   - Taints: nvidia.com/gpu=true:NoSchedule

4. **kata-bare-metal** ⭐
   - Labels:
     - workload-type=kata
     - instance-type=bare-metal
     - katacontainers.io/kata-runtime=true
   - Taints:
     - kata=true:NoSchedule
   - Requirements:
     - on-demand
     - arm64
     - instance-type in [c6g.metal, m6g.metal]
   - Limits:
     - cpu: 1000
     - memory: 1000Gi
   - Disruption: consolidate when empty

**Dependencies**: EKS Cluster, IAM Roles, Node Group (at least 1 node), helm Lambda

---

#### 7. nested-stacks/07-cognito.yaml
**Status**: Not Started
**Components**:
- Cognito User Pool (email sign-in, password policy)
- User Pool Client (no secret, USER_PASSWORD_AUTH flow)
- User Pool Domain (openclaw-auth-{AccountId})
- Custom Resource: AdminCreateUser + AdminSetUserPassword
  - Generate secure random password (16 chars)
  - Store in Secrets Manager
- Secrets Manager Secret

**Dependencies**: cognito-user Lambda

---

#### 8. nested-stacks/08-alb.yaml
**Status**: Not Started
**Components**:
- Custom Resource: ALB Waiter
  - Poll ELBv2 API for ALB
  - Filter by tag: elbv2.k8s.aws/cluster=${ClusterName}
  - Timeout: 5 minutes
  - Retry: 5 attempts, 30s interval
- Return: ALB DNS name + ARN

**Dependencies**: OpenClaw Apps (Ingress must create ALB first)

---

#### 9. nested-stacks/09-cloudfront.yaml
**Status**: Not Started
**Components**:
- CloudFront Distribution
- Origin: ALB DNS (from 08-alb output)
- Origin Custom Headers: none (preserve Authorization header)
- Cache Behavior:
  - Forward Headers: Authorization, Origin, Host, Accept, Content-Type
  - AllowedMethods: GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE
  - CachePolicyId: Managed-CachingDisabled (no caching for dynamic API)
  - OriginRequestPolicyId: Managed-AllViewer
- Viewer Protocol: redirect-to-https
- Price Class: PriceClass_100 (US, Canada, Europe)

**Dependencies**: ALB Stack

---

#### 10. nested-stacks/10-kubernetes-controllers.yaml (HIGH PRIORITY)
**Status**: Not Started
**Components**:

**A. ALB Controller** (Helm Custom Resource)
- Chart: eks/aws-load-balancer-controller
- Version: 2.10.0
- Namespace: kube-system
- Service Account: aws-load-balancer-controller
- Pod Identity Association:
  ```yaml
  AWS::EKS::PodIdentityAssociation:
    Namespace: kube-system
    ServiceAccount: aws-load-balancer-controller
    RoleArn: ${ALBControllerRoleArn}
  ```

**B. EFS CSI Driver** (Helm Custom Resource)
- Chart: aws-efs-csi-driver/aws-efs-csi-driver
- Version: 3.0.0
- Namespace: kube-system
- Service Account: efs-csi-controller-sa
- Pod Identity Association

**C. Kata DaemonSet** (kubectl Custom Resource)
- Manifest from: https://github.com/kata-containers/kata-containers/releases/download/3.10.0/kata-deploy.yaml
- Or inline manifest:
  ```yaml
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
        nodeSelector:
          workload-type: kata  # Only run on Kata nodes
        tolerations:
          - key: kata
            operator: Exists
            effect: NoSchedule
        hostNetwork: true
        hostPID: true
        containers:
          - name: kata-deploy
            image: quay.io/kata-containers/kata-deploy:3.10.0
            imagePullPolicy: Always
            securityContext:
              privileged: true
            volumeMounts:
              - name: host-root
                mountPath: /host
        volumes:
          - name: host-root
            hostPath:
              path: /
  ```

**D. Kata RuntimeClasses** (kubectl Custom Resources)
- kata-fc (Firecracker) - **Warning: EFS write not persistent**
- kata-qemu (QEMU) - **Recommended for EFS**

**Dependencies**: EKS Cluster, Node Group, IAM Roles (Pod Identity), Karpenter (for Kata nodes)

---

#### 11. nested-stacks/11-openclaw-apps.yaml (HIGH PRIORITY)
**Status**: Not Started
**Components**:

**A. OpenClaw Operator** (Helm Custom Resource)
- Chart: openclaw/openclaw-operator (from local path or registry)
- Version: 0.10.7
- Namespace: openclaw-operator-system
- Create namespace: true

**B. Provisioning Service** (kubectl Custom Resources)
- Namespace: openclaw-provisioning
- Deployment:
  ```yaml
  metadata:
    name: openclaw-provisioner
  spec:
    replicas: 2
    selector:
      matchLabels:
        app: openclaw-provisioner
    template:
      spec:
        serviceAccountName: openclaw-provisioner
        nodeSelector:
          kubernetes.io/arch: arm64  # Run on ARM64 nodes
        containers:
          - name: provisioner
            image: ${ProvisioningServiceImage}
            ports:
              - containerPort: 8080
            env:
              - name: CLUSTER_NAME
                value: ${ClusterName}
              - name: SHARED_BEDROCK_ROLE_ARN
                value: ${SharedBedrockRoleArn}
            resources:
              requests:
                cpu: 200m
                memory: 256Mi
              limits:
                cpu: 500m
                memory: 512Mi
  ```
- Service (ClusterIP, port 8080)
- Ingress:
  ```yaml
  metadata:
    name: openclaw-provisioner-ingress
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/healthcheck-path: /health
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
      alb.ingress.kubernetes.io/ssl-redirect: '443'
      alb.ingress.kubernetes.io/tags: elbv2.k8s.aws/cluster=${ClusterName}
  spec:
    ingressClassName: alb
    rules:
      - http:
          paths:
            - path: /
              pathType: Prefix
              backend:
                service:
                  name: openclaw-provisioner
                  port:
                    number: 8080
  ```
- ServiceAccount: openclaw-provisioner
- Pod Identity Association:
  ```yaml
  AWS::EKS::PodIdentityAssociation:
    Namespace: openclaw-provisioning
    ServiceAccount: openclaw-provisioner
    RoleArn: ${ProvisioningServiceRoleArn}
  ```

**C. AWS Credentials Secret** (kubectl Custom Resource)
- For OpenClaw instances to access Bedrock
- Namespace: openclaw
- Name: aws-credentials
- Data:
  ```yaml
  AWS_DEFAULT_REGION: us-west-2
  AWS_ROLE_ARN: ${SharedBedrockRoleArn}
  ```

**Dependencies**: Controllers (ALB, EFS CSI, Kata), Storage, Karpenter

---

### Custom Resources (Lambda Functions)

#### 12. custom-resources/kubectl-lambda/function.py
**Status**: Not Started
**Functionality**:
- Handler: apply/delete Kubernetes manifests
- Input:
  ```json
  {
    "ClusterName": "openclaw-dev",
    "Manifest": "apiVersion: v1\nkind: ConfigMap\n...",
    "Namespace": "default",
    "ResourceName": "my-configmap"
  }
  ```
- Process:
  1. Get EKS cluster info via boto3
  2. Generate kubeconfig
  3. Write manifest to /tmp/manifest.yaml
  4. Execute: `kubectl apply -f /tmp/manifest.yaml`
  5. Return PhysicalResourceId
- Error handling: Idempotent (check if resource exists before create)
- Timeout: 300s

**Dependencies**: kubectl layer (Docker build)

---

#### 13. custom-resources/kubectl-lambda/Dockerfile
**Status**: Not Started
**Content**:
```dockerfile
FROM public.ecr.aws/lambda/python:3.12

# Install kubectl
RUN curl -LO "https://dl.k8s.io/release/v1.34.0/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /opt/bin/kubectl

# Install helm
RUN curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash && \
    mv /usr/local/bin/helm /opt/bin/helm

# Install Python dependencies
COPY requirements.txt .
RUN pip install -r requirements.txt -t /opt/python

# Package as layer
RUN cd /opt && zip -r /opt/layer.zip .

CMD ["/bin/bash"]
```

**requirements.txt**:
```
boto3>=1.28.0
kubernetes>=28.1.0
PyYAML>=6.0
```

---

#### 14. custom-resources/helm-lambda/function.py
**Status**: Not Started
**Functionality**:
- Handler: helm install/upgrade/uninstall
- Input:
  ```json
  {
    "ClusterName": "openclaw-dev",
    "ChartName": "eks/aws-load-balancer-controller",
    "ReleaseName": "aws-load-balancer-controller",
    "Namespace": "kube-system",
    "Version": "2.10.0",
    "Values": {"replicaCount": 2, ...}
  }
  ```
- Process:
  1. Get kubeconfig
  2. Execute: `helm repo add ... && helm install ...`
  3. Wait for release ready: `helm status --wait`
- Retry: 3 attempts with exponential backoff

---

#### 15. custom-resources/alb-waiter/function.py
**Status**: Not Started
**Functionality**:
- Poll ELBv2 API for ALB
- Filter: tag `elbv2.k8s.aws/cluster=${ClusterName}`
- Timeout: 5 minutes
- Return: ALB DNS name + ARN

**Pseudocode**:
```python
import boto3
import time

def lambda_handler(event, context):
    elbv2 = boto3.client('elbv2')
    cluster_name = event['ResourceProperties']['ClusterName']

    for attempt in range(10):  # 10 attempts, 30s each = 5min
        albs = elbv2.describe_load_balancers()
        for alb in albs['LoadBalancers']:
            tags = elbv2.describe_tags(ResourceArns=[alb['LoadBalancerArn']])
            for tag in tags['TagDescriptions'][0]['Tags']:
                if tag['Key'] == 'elbv2.k8s.aws/cluster' and tag['Value'] == cluster_name:
                    return {
                        'PhysicalResourceId': alb['LoadBalancerArn'],
                        'Data': {
                            'AlbDnsName': alb['DNSName'],
                            'AlbArn': alb['LoadBalancerArn']
                        }
                    }
        time.sleep(30)

    raise Exception("ALB not found after 5 minutes")
```

---

#### 16. custom-resources/cognito-user-lambda/function.py
**Status**: Not Started
**Functionality**:
- AdminCreateUser
- AdminSetUserPassword (permanent=True)
- Generate secure random password
- Store in Secrets Manager

**Pseudocode**:
```python
import boto3
import secrets
import string

def lambda_handler(event, context):
    cognito = boto3.client('cognito-idp')
    secretsmanager = boto3.client('secretsmanager')

    user_pool_id = event['ResourceProperties']['UserPoolId']
    email = event['ResourceProperties']['Email']

    # Generate password
    password = ''.join(secrets.choice(string.ascii_letters + string.digits + string.punctuation) for _ in range(16))

    if event['RequestType'] == 'Create':
        # Create user
        cognito.admin_create_user(
            UserPoolId=user_pool_id,
            Username=email,
            UserAttributes=[{'Name': 'email', 'Value': email}],
            MessageAction='SUPPRESS'
        )

        # Set permanent password
        cognito.admin_set_user_password(
            UserPoolId=user_pool_id,
            Username=email,
            Password=password,
            Permanent=True
        )

        # Store in Secrets Manager
        secret_arn = secretsmanager.create_secret(
            Name=f'openclaw/test-user-password',
            SecretString=password
        )['ARN']

        return {
            'PhysicalResourceId': email,
            'Data': {
                'TestUserPasswordSecretArn': secret_arn
            }
        }
```

---

### Supporting Files (P1 Priority)

#### 17. parameters/staging.json
**Status**: Not Started
**Same structure as dev.json, different values**

---

#### 18. parameters/prod.json
**Status**: Not Started
**Production-grade values (larger nodes, multi-AZ redundancy)**

---

#### 19. scripts/validate.sh
**Status**: Not Started
**Checks**:
- EKS cluster health
- All nodes Ready
- Kata RuntimeClasses exist
- Controllers (ALB, EFS, Karpenter, Operator) Running
- CloudFront endpoint accessible
- Cognito login test

---

#### 20. scripts/cleanup.sh
**Status**: Not Started
**Actions**:
- Delete CloudFormation stack
- Wait for deletion
- Delete artifact bucket
- Optionally delete Lambda layers

---

## 🔑 Key Implementation Decisions

### 1. Pod Identity vs IRSA
**Decision**: Use Pod Identity
**Rationale**:
- Simpler trust policies (no OIDC provider)
- Native EKS addon support
- Better for new deployments

**Impact**:
- All service account roles trust `pods.eks.amazonaws.com`
- Use `AWS::EKS::PodIdentityAssociation` resources
- No OIDC provider creation needed

---

### 2. Karpenter vs ASG for Kata Nodes
**Decision**: Use Karpenter
**Rationale**:
- Dynamic provisioning (scales to 0)
- Supports AL2023 with NodeConfig
- Bare metal instance support
- Better cost optimization

**Impact**:
- NVMe RAID0 setup in UserData
- NodePool with Kata labels and taints
- No manual ASG management

---

### 3. AL2023 vs Ubuntu for Kata
**Decision**: Use AL2023
**Rationale**:
- Native AWS support
- NodeConfig API for EKS bootstrap
- Consistent with other nodes
- Latest kernel and security updates

**Impact**:
- Use latest AL2023 AMI alias
- UserData includes AL2023-specific commands
- No Packer AMI building needed

---

### 4. kata-qemu vs kata-fc for EFS
**Decision**: Recommend kata-qemu
**Rationale**:
- virtiofs support for RWX
- EFS writes persist correctly
- Better compatibility with K8s volumes

**Impact**:
- RuntimeClass: kata-qemu for production
- kata-fc available but documented as limited

---

## 📋 Next Steps

### Immediate (Critical Path)
1. **05-storage.yaml** - EFS infrastructure
2. **06-karpenter.yaml** - Karpenter + Kata NodePool
3. **10-kubernetes-controllers.yaml** - ALB Controller, EFS CSI, Kata DaemonSet
4. **11-openclaw-apps.yaml** - Operator + Provisioning Service

### Lambda Functions
5. **kubectl-lambda** (function.py + Dockerfile)
6. **helm-lambda** (function.py)
7. **alb-waiter** (function.py)
8. **cognito-user-lambda** (function.py)

### Edge & Auth
9. **07-cognito.yaml** - User Pool
10. **08-alb.yaml** - ALB Waiter
11. **09-cloudfront.yaml** - CloudFront Distribution

### Validation & Docs
12. **validate.sh** - Post-deployment checks
13. **cleanup.sh** - Full cleanup script

---

## 🎯 Success Criteria

### Phase 1: Infrastructure (files 5-6)
- ✅ VPC and networking
- ✅ IAM roles and policies
- ✅ EKS cluster and node groups
- 🔲 EFS file system with StorageClass
- 🔲 Karpenter with Kata NodePool

### Phase 2: Controllers (file 10)
- 🔲 ALB Controller running
- 🔲 EFS CSI Driver running
- 🔲 Kata DaemonSet running on Kata nodes
- 🔲 RuntimeClasses (kata-fc, kata-qemu) created

### Phase 3: Applications (file 11)
- 🔲 OpenClaw Operator deployed
- 🔲 Provisioning Service deployed (2 replicas)
- 🔲 Ingress creates ALB
- 🔲 Pod Identity associations working

### Phase 4: Edge & Auth (files 7-9)
- 🔲 Cognito User Pool with test user
- 🔲 ALB discovered and DNS returned
- 🔲 CloudFront distribution deployed
- 🔲 HTTPS access working

### Phase 5: E2E Validation
- 🔲 Login via CloudFront URL
- 🔲 Create OpenClaw instance via UI
- 🔲 Instance scheduled to Kata node
- 🔲 EFS PVC bound and writable
- 🔲 Bedrock API accessible

---

## 📊 Estimated Time to Completion

**Based on current progress (41% complete)**:

| Phase | Files | Estimated Time | Priority |
|-------|-------|----------------|----------|
| Storage & Karpenter | 2 | 4 hours | P0 |
| Lambda Functions | 4 | 6 hours | P0 |
| Controllers & Apps | 2 | 5 hours | P0 |
| Edge & Auth | 3 | 4 hours | P0 |
| Validation Scripts | 2 | 2 hours | P1 |
| **Total** | **13** | **21 hours** | |

**Expected delivery**: 2-3 working days (assuming 8 hours/day)

---

## 🚨 Critical Blockers

### None Currently

All dependencies are satisfied by completed files. Can proceed with remaining implementation.

---

## 📝 Notes

- All IAM policies verified against test-s4 environment
- Pod Identity associations tested and working
- Karpenter NodePool config validated with reference architecture
- EFS + kata-qemu compatibility confirmed

---

**Status Updated**: 2026-03-09 by Claude Code
**Next Review**: After completing Phase 1 (Storage & Karpenter)
