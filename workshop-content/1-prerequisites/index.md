---
title: "环境准备"
weight: 20
---

# 环境准备

在开始之前，请确保您已准备好以下环境。

## AWS 账户要求

- 一个 AWS 账户（推荐使用 Workshop Studio 提供的临时账户）
- IAM 权限：AdministratorAccess 或具备 EKS、EC2、IAM、Cognito、CloudFront 的操作权限

## 工具安装

请确保您的环境中已安装以下工具：

```bash
# AWS CLI v2
aws --version
# 期望: aws-cli/2.x.x

# kubectl
kubectl version --client
# 期望: v1.28+

# eksctl
eksctl version
# 期望: 0.170+

# Helm 3
helm version
# 期望: v3.x.x

# Docker (用于构建镜像)
docker --version
```

{{% notice tip %}}
如果使用 AWS CloudShell，大部分工具已预装，只需要安装 eksctl 和 Helm。
{{% /notice %}}

## 安装 eksctl (如果需要)

```bash
# Linux/macOS ARM64
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_arm64.tar.gz"
tar -xzf eksctl_$(uname -s)_arm64.tar.gz -C /usr/local/bin
```

## 安装 Helm (如果需要)

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## 设置环境变量

```bash
# 设置 AWS Region
export AWS_REGION=us-west-2
export CLUSTER_NAME=openclaw-workshop
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "AWS Region: $AWS_REGION"
echo "Cluster Name: $CLUSTER_NAME"
echo "Account ID: $ACCOUNT_ID"
```

## 验证 AWS 凭证

```bash
aws sts get-caller-identity
```

期望输出类似：
```json
{
    "UserId": "AIDXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/workshop-user"
}
```

{{% notice warning %}}
如果您使用的是临时凭证，请确保 Session Token 有效。
{{% /notice %}}

## 下一步

环境准备就绪后，我们将开始创建 EKS 集群。
