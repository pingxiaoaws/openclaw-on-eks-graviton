# 核心模板创建状态

**创建时间**: 2026-03-09
**状态**: 3个核心模板已创建，2个完全验证通过

---

## ✅ 已完成的核心模板

### 1. Kubernetes Controllers (10-kubernetes-controllers.yaml) ✅

**验证状态**: ✅ VALID (CloudFormation 验证通过)

**包含内容**:
- **ALB Controller** (Helm v2.10.0)
  - Chart: eks/aws-load-balancer-controller
  - Pod Identity Association
  - 2 replicas, 自动创建 ALB

- **EFS CSI Driver** (Helm v3.0.0)
  - Chart: aws-efs-csi-driver
  - Pod Identity Association
  - 支持 EFS 动态供给

- **Kata Containers DaemonSet**
  - Image: quay.io/kata-containers/kata-deploy:3.10.0
  - 只运行在 `workload-type=kata` 节点上
  - 自动安装 Kata runtime 和 Firecracker

- **RuntimeClasses**
  - `kata-fc` - Firecracker runtime
  - `kata-qemu` - QEMU runtime (推荐用于 EFS)

- **Metrics Server** (可选)
  - 支持 `kubectl top` 命令

**依赖**: EKS Cluster, Node Groups, IAM Roles (Pod Identity)

---

### 2. OpenClaw Applications (11-openclaw-apps.yaml) ✅

**验证状态**: ✅ VALID (CloudFormation 验证通过)

**包含内容**:
- **OpenClaw Operator** (Helm v0.10.7)
  - Chart: openclaw/openclaw-operator
  - Namespace: openclaw-operator-system
  - Watches OpenClawInstance CRD

- **Provisioning Service**
  - Deployment: 2 replicas (ARM64 节点)
  - Service: ClusterIP :8080
  - **Ingress**:
    - 自动创建 internet-facing ALB
    - Health check: /health
    - Tags: `elbv2.k8s.aws/cluster=${ClusterName}`
  - Pod Identity Association
  - Environment Variables:
    - CLUSTER_NAME
    - SHARED_BEDROCK_ROLE_ARN

- **Namespaces**
  - `openclaw` - OpenClaw instances
  - `openclaw-provisioning` - Provisioning service

- **AWS Credentials Secret**
  - Namespace: openclaw
  - Name: aws-credentials
  - 包含 Bedrock 访问配置

**依赖**: Controllers (ALB, EFS CSI), Storage, Karpenter

---

### 3. Karpenter + Kata NodePool (06-karpenter.yaml) ⚠️

**验证状态**: ⚠️ 部分验证通过 (UserData bash 变量转义问题)

**包含内容**:
- **Karpenter Helm Release**
  - Chart: oci://public.ecr.aws/karpenter/karpenter v1.7.4
  - Namespace: kube-system
  - Pod Identity Association
  - 2 replicas

- **EC2NodeClasses** (2个):
  1. **kata-bare-metal** ⭐
     - AL2023 AMI (latest)
     - Instance types: c6g.metal, m6g.metal
     - 200GB gp3 EBS
     - **UserData**: NVMe RAID0 + LVM for devicemapper

  2. **provisioning-graviton**
     - AL2023 AMI (latest)
     - Instance types: t4g, c6g, c7g, m6g, m7g
     - 100GB gp3 EBS

- **NodePools** (2个):
  1. **kata-bare-metal** ⭐
     - Labels: `workload-type=kata`, `instance-type=bare-metal`
     - Taints: `kata=true:NoSchedule`
     - Requirements: on-demand, arm64, bare metal only
     - Limits: 1000 CPU, 1000Gi memory

  2. **provisioning-graviton**
     - Labels: `workload-type=standard`
     - Requirements: on-demand/spot, arm64, 4th gen+
     - Limits: 1000 CPU, 1000Gi memory

**⚠️ 已知问题**:
- UserData 中的 bash 变量（如 `${#nvme_disks[@]}`）与 CloudFormation 的 `!Sub` 语法冲突
- 需要进一步转义或使用替代方案

**变通方案**:
1. 使用 Helm 手动安装 Karpenter
2. 通过 `kubectl apply` 应用 EC2NodeClass 和 NodePool YAML（见下方）

**依赖**: EKS Cluster, Node Groups, IAM Roles

---

## 📊 验证结果总结

| 模板 | CloudFormation验证 | 包含资源数 | 优先级 |
|------|-------------------|-----------|--------|
| **10-kubernetes-controllers.yaml** | ✅ VALID | 6 (ALB, EFS, Kata, RuntimeClasses) | P0 ⭐⭐⭐ |
| **11-openclaw-apps.yaml** | ✅ VALID | 5 (Operator, Provisioning, Ingress) | P0 ⭐⭐⭐ |
| **06-karpenter.yaml** | ⚠️ PARTIAL | 5 (Karpenter, NodeClasses, NodePools) | P0 ⭐⭐⭐ |

**总计**: 16 个核心资源配置

---

## 🔧 Karpenter 变通方案（推荐）

由于 06-karpenter.yaml 的 UserData bash 变量转义复杂，推荐使用以下方式部署 Karpenter：

### Step 1: 手动安装 Karpenter (Helm)

```bash
export CLUSTER_NAME=openclaw-dev
export KARPENTER_VERSION=1.7.4

# 获取 Karpenter Controller Role ARN
export KARPENTER_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name openclaw-platform \
  --query 'Stacks[0].Outputs[?OutputKey==`KarpenterControllerRoleArn`].OutputValue' \
  --output text)

# 安装 Karpenter
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version $KARPENTER_VERSION \
  --namespace kube-system \
  --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=$(aws eks describe-cluster --name ${CLUSTER_NAME} --query 'cluster.endpoint' --output text)" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KARPENTER_ROLE_ARN}" \
  --wait
```

### Step 2: 应用 EC2NodeClass 和 NodePool

创建 `kata-nodepool.yaml`:

```yaml
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: kata-bare-metal
spec:
  amiFamily: AL2023
  amiSelectorTerms:
    - alias: al2023@latest
  role: openclaw-dev-karpenter-node  # 替换为实际 role name
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: openclaw-dev  # 替换为实际 cluster name
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: openclaw-dev  # 替换为实际 cluster name
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 200Gi
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true
  userData: |
    #!/bin/bash
    set -ex
    exec > >(tee /var/log/user-data.log) 2>&1

    echo "=== Starting Kata node setup ==="
    dnf install -y mdadm lvm2 device-mapper

    # Find NVMe instance store devices
    nvme_disks=()
    for dev in /dev/nvme*n1; do
        if [ -b "$dev" ]; then
            if ! lsblk -n -o MOUNTPOINT "$dev" | grep -q . && \
               ! lsblk -n "$dev" | grep -q part && \
               ! fuser "$dev" 2>/dev/null && \
               ! mdadm --examine "$dev" 2>/dev/null | grep -q "Magic"; then
                echo "Found NVMe device: $dev"
                nvme_disks+=("$dev")
            fi
        fi
    done

    # Setup RAID0 + LVM for containerd devicemapper
    if [ ${#nvme_disks[@]} -gt 1 ]; then
        echo "Creating RAID0 array with ${#nvme_disks[@]} disks"
        mdadm --create --verbose /dev/md0 --level=0 \
          --raid-devices=${#nvme_disks[@]} ${nvme_disks[@]} \
          --force --assume-clean
        sleep 5
        pvcreate /dev/md0
        vgcreate vg_raid0 /dev/md0
        lvcreate -n thinpool_data vg_raid0 -l 90%VG
        echo "RAID0 + LVM setup complete"
    elif [ ${#nvme_disks[@]} -eq 1 ]; then
        echo "Using single NVMe device: ${nvme_disks[0]}"
        pvcreate ${nvme_disks[0]}
        vgcreate vg_raid0 ${nvme_disks[0]}
        lvcreate -n thinpool_data vg_raid0 -l 90%VG
        echo "LVM setup complete"
    else
        echo "No NVMe instance store devices found, using EBS only"
    fi

    echo "=== Kata node setup complete ==="
  tags:
    Name: kata-bare-metal-node
    KarpenterNodeClass: kata-bare-metal

---
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
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: kata-bare-metal
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
  limits:
    cpu: "1000"
    memory: 1000Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m

---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: provisioning-graviton
spec:
  amiFamily: AL2023
  amiSelectorTerms:
    - alias: al2023@latest
  role: openclaw-dev-karpenter-node  # 替换为实际 role name
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: openclaw-dev  # 替换为实际 cluster name
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: openclaw-dev  # 替换为实际 cluster name
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true
  tags:
    Name: provisioning-graviton-node
    KarpenterNodeClass: provisioning-graviton

---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: provisioning-graviton
spec:
  template:
    metadata:
      labels:
        workload-type: standard
        instance-type: graviton
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: provisioning-graviton
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand", "spot"]
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ["t4g", "c6g", "c7g", "m6g", "m7g"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["3"]
  limits:
    cpu: "1000"
    memory: 1000Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
```

应用配置:

```bash
kubectl apply -f kata-nodepool.yaml
```

验证:

```bash
# 检查 EC2NodeClasses
kubectl get ec2nodeclass

# 检查 NodePools
kubectl get nodepool

# 触发 Kata 节点创建（创建一个 Kata Pod）
kubectl run test-kata --image=busybox --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"kata-qemu","nodeSelector":{"workload-type":"kata"},"tolerations":[{"key":"kata","operator":"Exists","effect":"NoSchedule"}]}}' \
  -- sh -c "sleep 3600"

# 等待节点创建（约 5-7 分钟）
watch kubectl get nodes -l workload-type=kata
```

---

## 🎯 部署顺序（推荐）

### 使用 CloudFormation 部署基础设施

```bash
cd cloudformation

# 1. 部署主栈（跳过 Karpenter 栈）
#    主栈会自动部署：VPC, IAM, EKS, Node Groups, Storage
aws cloudformation create-stack \
  --stack-name openclaw-platform \
  --template-body file://master.yaml \
  --parameters file://parameters/dev.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2

# 2. 等待基础设施完成（约 15-20 分钟）
aws cloudformation wait stack-create-complete \
  --stack-name openclaw-platform \
  --region us-west-2

# 3. 配置 kubectl
aws eks update-kubeconfig --name openclaw-dev --region us-west-2
```

### 手动部署 Karpenter 和 Controllers

```bash
# 4. 部署 Karpenter（见上方 Step 1）
# ... helm install karpenter ...

# 5. 部署 Controllers 栈
#    注意：这个栈在 master.yaml 中会自动部署
#    如果跳过了 master.yaml，可以单独部署：
aws cloudformation create-stack \
  --stack-name openclaw-controllers \
  --template-body file://nested-stacks/10-kubernetes-controllers.yaml \
  --parameters \
      ParameterKey=ClusterName,ParameterValue=openclaw-dev \
      ParameterKey=ALBControllerRoleArn,ParameterValue=<ARN> \
      ParameterKey=EFSCSIDriverRoleArn,ParameterValue=<ARN> \
      ParameterKey=VpcId,ParameterValue=<VPC_ID> \
      ParameterKey=ArtifactBucket,ParameterValue=<BUCKET> \
  --region us-west-2

# 6. 部署 OpenClaw Apps 栈
#    注意：这个栈在 master.yaml 中会自动部署
aws cloudformation create-stack \
  --stack-name openclaw-apps \
  --template-body file://nested-stacks/11-openclaw-apps.yaml \
  --parameters \
      ParameterKey=ClusterName,ParameterValue=openclaw-dev \
      ParameterKey=OperatorVersion,ParameterValue=0.10.7 \
      ParameterKey=ProvisioningServiceImage,ParameterValue=<ECR_URI> \
      ParameterKey=ProvisioningServiceRoleArn,ParameterValue=<ARN> \
      ParameterKey=SharedBedrockRoleArn,ParameterValue=<ARN> \
      ParameterKey=ArtifactBucket,ParameterValue=<BUCKET> \
  --region us-west-2

# 7. 应用 Karpenter NodePools（见上方 Step 2）
kubectl apply -f kata-nodepool.yaml
```

---

## 📋 下一步

### 选项 A: 完整修复 Karpenter 模板

修复 `06-karpenter.yaml` 中的 bash 变量转义问题，使其能够通过 CloudFormation 验证。

**工作量**: 1-2 小时
**优点**: 完全自动化，一键部署
**缺点**: CloudFormation !Sub 和 bash 变量冲突复杂

### 选项 B: 使用混合部署方式（推荐）

- CloudFormation: 部署基础设施（VPC, IAM, EKS, Storage）
- Helm + kubectl: 部署 Karpenter 和 NodePools
- CloudFormation: 部署 Controllers 和 Apps

**工作量**: 立即可用
**优点**:
- 避开 CloudFormation 限制
- Karpenter 配置更灵活
- 更符合 Kubernetes 最佳实践
**缺点**: 需要两步部署

---

## ✅ 成功标准

当前 3 个核心模板创建完成后，你将拥有:

1. ✅ **完整的 Kubernetes 控制器**
   - ALB Controller（自动创建 Load Balancer）
   - EFS CSI Driver（动态供给 PVC）
   - Kata Containers Runtime
   - 2 个 RuntimeClasses

2. ✅ **完整的 OpenClaw 应用栈**
   - OpenClaw Operator（CRD controller）
   - Provisioning Service（2 replicas, JWT auth ready）
   - 自动创建 ALB Ingress
   - Pod Identity 集成

3. ⚠️ **Karpenter 自动扩展器**（需手动部署）
   - Karpenter controller
   - 2 个 NodePools（Kata + Standard）
   - 自动节点供给和回收

---

## 📊 当前总进度

**CloudFormation 模板**: 8/11 完成 (73%)
**核心功能**: 3/3 创建 (100%)
**验证通过**: 2/3 完全通过 (67%)

---

**下一步建议**:
1. 使用混合部署方式测试当前模板
2. 或者继续创建剩余的 3 个模板（Cognito, ALB, CloudFront）

**维护者**: Claude Code
**最后更新**: 2026-03-09
