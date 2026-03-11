# EKS Pod Identity Setup Guide for OpenClaw Multi-Tenant Platform

## 概述

本文档记录了为OpenClaw多租户平台实现EKS Pod Identity的完整过程，用于自动化部署（Terraform/CloudFormation）参考。

## 架构

```
┌──────────────────────────────────────────────────────────────┐
│  Multi-Tenant OpenClaw Platform with Pod Identity            │
└──────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│ 1. Provisioning Service (openclaw-provisioning namespace)      │
│                                                                  │
│    ServiceAccount: openclaw-provisioner                        │
│    Annotations: eks.amazonaws.com/role-arn=                    │
│                 arn:aws:iam::ACCOUNT:role/                     │
│                 OpenClawProvisioningServiceRole                │
│                                                                  │
│    IAM Role: OpenClawProvisioningServiceRole                   │
│    - Trust Policy: pods.eks.amazonaws.com                      │
│    - Permissions: Create/Delete IAM Roles,                     │
│                   Create/Delete Pod Identity Associations      │
│                                                                  │
│    Pod Identity Association:                                   │
│    - Namespace: openclaw-provisioning                          │
│    - ServiceAccount: openclaw-provisioner                      │
│    - Role: OpenClawProvisioningServiceRole                     │
└────────────────────────────────────────────────────────────────┘
                           │
                           │ Creates per-user resources
                           ↓
┌────────────────────────────────────────────────────────────────┐
│ 2. User Instance (openclaw-{user_id} namespace)               │
│                                                                  │
│    ServiceAccount: openclaw-{user_id}                          │
│    Annotations: eks.amazonaws.com/role-arn=                    │
│                 arn:aws:iam::ACCOUNT:role/                     │
│                 openclaw-user-{user_id}                        │
│                                                                  │
│    IAM Role: openclaw-user-{user_id}                           │
│    - Trust Policy: pods.eks.amazonaws.com                      │
│    - Permissions: AmazonBedrockFullAccess                      │
│    - Tags: user_id, managed_by, cost_allocation               │
│                                                                  │
│    Pod Identity Association:                                   │
│    - Namespace: openclaw-{user_id}                             │
│    - ServiceAccount: openclaw-{user_id}                        │
│    - Role: openclaw-user-{user_id}                             │
│                                                                  │
│    Pod: openclaw-{user_id}-0                                   │
│    - Env injected by EKS Pod Identity Agent:                   │
│      AWS_ROLE_ARN=arn:aws:iam::ACCOUNT:role/openclaw-user-... │
│      AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.../token│
│      AWS_REGION=us-west-2                                      │
└────────────────────────────────────────────────────────────────┘
```

## 实施步骤

### Step 1: 为Provisioning Service创建IAM Role

**IAM Policy**: `OpenClawProvisioningServicePolicy`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageUserIAMRoles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:TagRole"
      ],
      "Resource": "arn:aws:iam::*:role/openclaw-user-*"
    },
    {
      "Sid": "ManagePodIdentityAssociations",
      "Effect": "Allow",
      "Action": [
        "eks:CreatePodIdentityAssociation",
        "eks:DeletePodIdentityAssociation",
        "eks:DescribePodIdentityAssociation",
        "eks:ListPodIdentityAssociations"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassRoleToEKS",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::*:role/openclaw-user-*",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "pods.eks.amazonaws.com"
        }
      }
    }
  ]
}
```

**IAM Role**: `OpenClawProvisioningServiceRole`

Trust Policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
```

**AWS CLI 创建命令**:

```bash
# 1. Create Policy
aws iam create-policy \
  --policy-name OpenClawProvisioningServicePolicy \
  --policy-document file://provisioning-service-policy.json \
  --region us-west-2

# 2. Create Role with Trust Policy
aws iam create-role \
  --role-name OpenClawProvisioningServiceRole \
  --assume-role-policy-document file://pod-identity-trust-policy.json \
  --region us-west-2

# 3. Attach Policy to Role
aws iam attach-role-policy \
  --role-name OpenClawProvisioningServiceRole \
  --policy-arn arn:aws:iam::111122223333:policy/OpenClawProvisioningServicePolicy \
  --region us-west-2
```

### Step 2: 创建Pod Identity Association for Provisioning Service

```bash
aws eks create-pod-identity-association \
  --cluster-name test-s4 \
  --namespace openclaw-provisioning \
  --service-account openclaw-provisioner \
  --role-arn arn:aws:iam::111122223333:role/OpenClawProvisioningServiceRole \
  --region us-west-2
```

**输出示例**:
```json
{
  "association": {
    "clusterName": "test-s4",
    "namespace": "openclaw-provisioning",
    "serviceAccount": "openclaw-provisioner",
    "roleArn": "arn:aws:iam::111122223333:role/OpenClawProvisioningServiceRole",
    "associationArn": "arn:aws:eks:us-west-2:111122223333:podidentityassociation/test-s4/...",
    "associationId": "a-xxxxx",
    "createdAt": "2026-03-03T03:00:00.000Z"
  }
}
```

### Step 3: 更新Provisioning Service的ServiceAccount

确保ServiceAccount有Pod Identity annotation:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: openclaw-provisioner
  namespace: openclaw-provisioning
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/OpenClawProvisioningServiceRole
```

### Step 4: 重启Provisioning Service以加载凭证

```bash
kubectl rollout restart deployment openclaw-provisioning -n openclaw-provisioning
kubectl rollout status deployment openclaw-provisioning -n openclaw-provisioning
```

### Step 5: Provisioning Service自动为每个用户创建IAM资源

当用户调用 `/provision` API时，Provisioning Service自动执行以下操作：

#### 5.1 创建用户IAM Role

**Python代码** (`app/aws/iam.py`):

```python
def create_pod_identity_role(user_id, region='us-west-2'):
    """Create IAM Role for EKS Pod Identity with Bedrock access"""
    iam = boto3.client('iam', region_name=region)
    role_name = f"openclaw-user-{user_id}"

    # Trust Policy for EKS Pod Identity
    trust_policy = {
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "pods.eks.amazonaws.com"},
            "Action": ["sts:AssumeRole", "sts:TagSession"]
        }]
    }

    try:
        # Create Role
        response = iam.create_role(
            RoleName=role_name,
            AssumeRolePolicyDocument=json.dumps(trust_policy),
            Description=f"EKS Pod Identity role for OpenClaw user {user_id}",
            Tags=[
                {'Key': 'user_id', 'Value': user_id},
                {'Key': 'managed_by', 'Value': 'openclaw-provisioning-service'},
                {'Key': 'cost_allocation', 'Value': f'openclaw-user-{user_id}'}
            ]
        )

        role_arn = response['Role']['Arn']

        # Attach Bedrock policy
        iam.attach_role_policy(
            RoleName=role_name,
            PolicyArn='arn:aws:iam::aws:policy/AmazonBedrockFullAccess'
        )

        return role_arn

    except iam.exceptions.EntityAlreadyExistsException:
        response = iam.get_role(RoleName=role_name)
        return response['Role']['Arn']
```

#### 5.2 创建Pod Identity Association

```python
def create_pod_identity_association(cluster_name, namespace, service_account, role_arn, region='us-west-2'):
    """Create EKS Pod Identity Association"""
    eks = boto3.client('eks', region_name=region)

    try:
        response = eks.create_pod_identity_association(
            clusterName=cluster_name,
            namespace=namespace,
            serviceAccount=service_account,
            roleArn=role_arn
        )
        return response['association']['associationId']

    except eks.exceptions.ResourceInUseException:
        # Association already exists
        associations = eks.list_pod_identity_associations(
            clusterName=cluster_name,
            namespace=namespace,
            serviceAccount=service_account
        )
        return associations['associations'][0]['associationId'] if associations['associations'] else None
```

#### 5.3 创建OpenClawInstance with ServiceAccount Annotation

```python
def create_openclaw_instance(k8s_client, user_id, namespace, user_email, cognito_sub=None, custom_config=None, role_arn=None):
    """Create OpenClawInstance CRD with Pod Identity"""
    instance_body = {
        "apiVersion": "openclaw.rocks/v1alpha1",
        "kind": "OpenClawInstance",
        "metadata": {
            "name": f"openclaw-{user_id}",
            "namespace": namespace
        },
        "spec": {
            "security": {
                "rbac": {
                    "createServiceAccount": True,
                    "serviceAccountAnnotations": {
                        "eks.amazonaws.com/role-arn": role_arn
                    } if role_arn else {}
                }
            },
            # ... other configurations
        }
    }

    return k8s_client.custom_objects.create_namespaced_custom_object(
        group="openclaw.rocks",
        version="v1alpha1",
        namespace=namespace,
        plural="openclawinstances",
        body=instance_body
    )
```

### Step 6: 清理资源

当删除OpenClaw实例时，Provisioning Service自动清理IAM资源：

```python
def delete_pod_identity_role(user_id, region='us-west-2'):
    """Delete IAM Role and detach all policies"""
    iam = boto3.client('iam', region_name=region)
    role_name = f"openclaw-user-{user_id}"

    try:
        # Detach all policies
        attached_policies = iam.list_attached_role_policies(RoleName=role_name)
        for policy in attached_policies['AttachedPolicies']:
            iam.detach_role_policy(RoleName=role_name, PolicyArn=policy['PolicyArn'])

        # Delete role
        iam.delete_role(RoleName=role_name)
        return True
    except iam.exceptions.NoSuchEntityException:
        return False

def delete_pod_identity_association(cluster_name, association_id, region='us-west-2'):
    """Delete EKS Pod Identity Association"""
    eks = boto3.client('eks', region_name=region)

    try:
        eks.delete_pod_identity_association(
            clusterName=cluster_name,
            associationId=association_id
        )
        return True
    except eks.exceptions.ResourceNotFoundException:
        return False
```

## Terraform实现参考

### 1. Provisioning Service IAM Role

```hcl
# Policy for Provisioning Service
resource "aws_iam_policy" "provisioning_service" {
  name        = "OpenClawProvisioningServicePolicy"
  description = "Allows OpenClaw provisioning service to manage user IAM roles and Pod Identity"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageUserIAMRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:TagRole"
        ]
        Resource = "arn:aws:iam::*:role/openclaw-user-*"
      },
      {
        Sid    = "ManagePodIdentityAssociations"
        Effect = "Allow"
        Action = [
          "eks:CreatePodIdentityAssociation",
          "eks:DeletePodIdentityAssociation",
          "eks:DescribePodIdentityAssociation",
          "eks:ListPodIdentityAssociations"
        ]
        Resource = "*"
      },
      {
        Sid    = "PassRoleToEKS"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = "arn:aws:iam::*:role/openclaw-user-*"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "pods.eks.amazonaws.com"
          }
        }
      }
    ]
  })
}

# IAM Role for Provisioning Service
resource "aws_iam_role" "provisioning_service" {
  name = "OpenClawProvisioningServiceRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = {
    Name       = "OpenClawProvisioningServiceRole"
    ManagedBy  = "Terraform"
    Component  = "openclaw-provisioning"
  }
}

resource "aws_iam_role_policy_attachment" "provisioning_service" {
  role       = aws_iam_role.provisioning_service.name
  policy_arn = aws_iam_policy.provisioning_service.arn
}
```

### 2. Pod Identity Association for Provisioning Service

```hcl
resource "aws_eks_pod_identity_association" "provisioning_service" {
  cluster_name    = var.eks_cluster_name
  namespace       = "openclaw-provisioning"
  service_account = "openclaw-provisioner"
  role_arn        = aws_iam_role.provisioning_service.arn

  tags = {
    Name      = "openclaw-provisioning-pod-identity"
    ManagedBy = "Terraform"
  }
}
```

### 3. Kubernetes ServiceAccount

```hcl
resource "kubernetes_service_account" "provisioning_service" {
  metadata {
    name      = "openclaw-provisioner"
    namespace = kubernetes_namespace.provisioning.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.provisioning_service.arn
    }
  }

  depends_on = [aws_eks_pod_identity_association.provisioning_service]
}
```

### 4. Provisioning Service Deployment

```hcl
resource "kubernetes_deployment" "provisioning_service" {
  metadata {
    name      = "openclaw-provisioning"
    namespace = kubernetes_namespace.provisioning.metadata[0].name
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "openclaw-provisioning"
      }
    }

    template {
      metadata {
        labels = {
          app = "openclaw-provisioning"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.provisioning_service.metadata[0].name

        container {
          name  = "provisioning-service"
          image = "${var.ecr_registry}/openclaw-provisioning:latest"

          env {
            name  = "USE_POD_IDENTITY"
            value = "true"
          }

          env {
            name  = "AWS_REGION"
            value = var.aws_region
          }

          env {
            name  = "EKS_CLUSTER_NAME"
            value = var.eks_cluster_name
          }

          # ... other env vars
        }
      }
    }
  }
}
```

## 验证

### 1. 验证Provisioning Service凭证

```bash
# Check ServiceAccount annotation
kubectl get sa openclaw-provisioner -n openclaw-provisioning -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'

# Expected: arn:aws:iam::ACCOUNT:role/OpenClawProvisioningServiceRole

# Check Pod has AWS credentials injected
kubectl exec -n openclaw-provisioning deployment/openclaw-provisioning -- env | grep AWS_ROLE_ARN

# Expected: AWS_ROLE_ARN=arn:aws:iam::ACCOUNT:role/OpenClawProvisioningServiceRole
```

### 2. 验证用户实例凭证

```bash
# After creating a user instance
USER_ID="a744863d"

# Check ServiceAccount annotation
kubectl get sa openclaw-${USER_ID} -n openclaw-${USER_ID} -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'

# Expected: arn:aws:iam::ACCOUNT:role/openclaw-user-a744863d

# Check Pod credentials
kubectl exec -n openclaw-${USER_ID} openclaw-${USER_ID}-0 -c openclaw -- env | grep AWS_ROLE_ARN

# Expected: AWS_ROLE_ARN=arn:aws:iam::ACCOUNT:role/openclaw-user-a744863d
```

### 3. 验证Bedrock访问

```bash
# Test Bedrock API call from OpenClaw pod
kubectl exec -n openclaw-${USER_ID} openclaw-${USER_ID}-0 -c openclaw -- \
  aws bedrock-runtime list-foundation-models --region us-west-2

# Should return list of available models
```

## 成本追踪

每个用户的IAM Role都有cost allocation标签：

```json
{
  "Tags": [
    {
      "Key": "user_id",
      "Value": "a744863d"
    },
    {
      "Key": "cost_allocation",
      "Value": "openclaw-user-a744863d"
    },
    {
      "Key": "managed_by",
      "Value": "openclaw-provisioning-service"
    }
  ]
}
```

可在AWS Cost Explorer中按 `cost_allocation` 标签过滤用户级别的Bedrock费用。

## 安全优势

1. **最小权限原则**: 每个用户只能访问分配给他们的IAM Role
2. **自动凭证轮换**: EKS Pod Identity Agent自动管理短期凭证
3. **审计追踪**: CloudTrail记录所有API调用，关联到具体的IAM Role (user_id)
4. **无静态凭证**: 不需要存储AWS_ACCESS_KEY_ID/SECRET_ACCESS_KEY
5. **命名空间隔离**: 结合Kubernetes RBAC实现多租户隔离

## 故障排查

### Pod Identity凭证未注入

**症状**: Pod中没有 `AWS_ROLE_ARN` 环境变量

**检查清单**:
1. ServiceAccount是否有 `eks.amazonaws.com/role-arn` annotation
2. Pod Identity Association是否创建成功
3. EKS Pod Identity Agent是否运行 (`kubectl get ds -n kube-system eks-pod-identity-agent`)
4. IAM Role trust policy是否包含 `pods.eks.amazonaws.com`

### Bedrock API调用失败

**症状**: `AccessDeniedException` 或 `UnauthorizedException`

**检查清单**:
1. IAM Role是否附加了 `AmazonBedrockFullAccess` 策略
2. Pod的AWS凭证是否正确: `kubectl exec POD -- env | grep AWS_`
3. Bedrock服务是否在正确的region启用
4. NetworkPolicy是否允许出站HTTPS流量

### Provisioning Service无法创建IAM Role

**症状**: `/provision` API返回 `Unable to locate credentials`

**检查清单**:
1. Provisioning Service的ServiceAccount annotation是否正确
2. `OpenClawProvisioningServiceRole` 是否有足够的IAM权限
3. Provisioning Service的Pod是否重启以加载新凭证

## 参考资料

- [AWS EKS Pod Identity Documentation](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [IAM Roles for Service Accounts (IRSA) vs Pod Identity](https://aws.amazon.com/blogs/containers/amazon-eks-pod-identity-a-new-way-for-applications-on-eks-to-obtain-iam-credentials/)
- [OpenClaw Operator README](./README.md)

---

**Created**: 2026-03-03
**Author**: Claude Code
**Version**: 1.0
