---
title: "创建 EKS 集群"
weight: 30
---

# 创建 EKS 集群与 Graviton 节点

## 为什么选择 EKS + Graviton?

| 维度 | Graviton (ARM64) | x86 同配置实例 |
|------|------------------|---------------|
| 性价比 | 便宜 20-40% | 基准 |
| 单核性能 | 优秀（Neoverse V2） | 良好 |
| 能效比 | 高（功耗更低） | 标准 |
| Kata Containers | 支持（Metal 实例） | 支持（Metal 实例） |

## 创建 EKS 集群

使用 eksctl 创建一个带 Graviton 节点组的 EKS 集群：

```bash
cat << 'EOF' > cluster-config.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: openclaw-workshop
  region: us-west-2
  version: "1.30"

iam:
  withOIDC: true

managedNodeGroups:
  - name: graviton-system
    instanceType: t4g.medium
    desiredCapacity: 2
    minSize: 1
    maxSize: 4
    amiFamily: AmazonLinux2023
    labels:
      role: system
    tags:
      workshop: openclaw
EOF

eksctl create cluster -f cluster-config.yaml
```

{{% notice info %}}
集群创建大约需要 **15-20 分钟**，请耐心等待。
{{% /notice %}}

## 验证集群

```bash
# 检查集群状态
kubectl get nodes
# 期望看到 2 个 arm64 节点

# 验证节点架构
kubectl get nodes -o wide | awk '{print $1, $NF}'
# 期望: CONTAINER-RUNTIME 列显示 containerd
```

## 安装 Karpenter

Karpenter 负责自动弹性伸缩，按需创建 Graviton 节点：

```bash
# 设置 Karpenter 版本
export KARPENTER_VERSION="1.0.0"

# 安装 Karpenter
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace karpenter --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=$(aws eks describe-cluster --name ${CLUSTER_NAME} --query 'cluster.endpoint' --output text)" \
  --wait
```

## 创建 Graviton NodePool

```yaml
cat << 'EOF' | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: openclaw-graviton
spec:
  template:
    metadata:
      labels:
        type: karpenter
        workload-type: openclaw
        arch: arm64
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["t", "c", "m"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["3"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: openclaw-graviton
      expireAfter: 720h
  limits:
    cpu: 100
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30m
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: openclaw-graviton
spec:
  tags:
    KarpenterProvisionerName: "openclaw-graviton"
    Workshop: "openclaw"
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 20Gi
        volumeType: gp3
        encrypted: true
  role: "KarpenterNodeRole-${CLUSTER_NAME}"
  amiSelectorTerms:
    - alias: "al2023@latest"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
EOF
```

## 安装 AWS Load Balancer Controller

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=${CLUSTER_NAME} \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller
```

## 安装 EFS CSI Driver

```bash
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm repo update

helm install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.create=true
```

## 验证所有组件

```bash
echo "=== Nodes ==="
kubectl get nodes -o wide

echo "=== Karpenter ==="
kubectl get pods -n karpenter

echo "=== AWS LB Controller ==="
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

echo "=== EFS CSI Driver ==="
kubectl get pods -n kube-system -l app=efs-csi-controller
```

{{% notice tip %}}
所有 Pod 应该处于 Running 状态。如果遇到问题，请检查 IAM Role 权限配置。
{{% /notice %}}

## 下一步

集群准备就绪，接下来我们将部署 OpenClaw Operator。
