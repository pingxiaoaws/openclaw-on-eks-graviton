# IAM Roles Reference for OpenClaw Shared Role Architecture

**Last Updated**: 2026-03-06
**Status**: Production Ready

---

## Overview

This document contains the complete IAM role configurations for the OpenClaw shared role architecture using EKS Pod Identity.

**Architecture**:
- **Provisioning Service Role**: Manages Pod Identity Associations
- **Shared Bedrock Role**: Used by all OpenClaw instances for Bedrock access

---

## 1. Provisioning Service Role

### Role Name
```
openclaw-provisioning-service
```

### ARN
```
arn:aws:iam::111122223333:role/openclaw-provisioning-service
```

### Trust Policy (AssumeRolePolicyDocument)

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

### Permissions Policy

**Policy Name**: `OpenClawProvisioningServicePolicy`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManagePodIdentityAssociations",
      "Effect": "Allow",
      "Action": [
        "eks:CreatePodIdentityAssociation",
        "eks:DescribePodIdentityAssociation",
        "eks:ListPodIdentityAssociations",
        "eks:DeletePodIdentityAssociation"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassRoleAndGetSharedBedrockRole",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole",
        "iam:GetRole"
      ],
      "Resource": "arn:aws:iam::111122223333:role/openclaw-bedrock-shared"
    }
  ]
}
```

### Creation Script

```bash
#!/bin/bash
# Create Provisioning Service Role

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

# 1. Create Trust Policy
cat > /tmp/provisioning-role-trust.json << 'EOF'
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
EOF

# 2. Create Role
aws iam create-role \
  --role-name openclaw-provisioning-service \
  --assume-role-policy-document file:///tmp/provisioning-role-trust.json \
  --description "IAM Role for OpenClaw Provisioning Service to manage Pod Identity Associations"

# 3. Create Permissions Policy
cat > /tmp/provisioning-service-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManagePodIdentityAssociations",
      "Effect": "Allow",
      "Action": [
        "eks:CreatePodIdentityAssociation",
        "eks:DescribePodIdentityAssociation",
        "eks:ListPodIdentityAssociations",
        "eks:DeletePodIdentityAssociation"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassRoleAndGetSharedBedrockRole",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole",
        "iam:GetRole"
      ],
      "Resource": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/openclaw-bedrock-shared"
    }
  ]
}
EOF

# 4. Attach Policy to Role
aws iam put-role-policy \
  --role-name openclaw-provisioning-service \
  --policy-name OpenClawProvisioningServicePolicy \
  --policy-document file:///tmp/provisioning-service-policy.json

echo "✅ Provisioning Service Role created: arn:aws:iam::${AWS_ACCOUNT_ID}:role/openclaw-provisioning-service"
```

---

## 2. Shared Bedrock Role

### Role Name
```
openclaw-bedrock-shared
```

### ARN
```
arn:aws:iam::111122223333:role/openclaw-bedrock-shared
```

### Trust Policy (AssumeRolePolicyDocument)

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

### Permissions Policy

**Policy Name**: `BedrockAccess`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:*:*:inference-profile/*"
      ]
    }
  ]
}
```

**Notes**:
- Supports **all AWS regions** (wildcard `*` in resource ARN)
- Supports **all Bedrock models** (`foundation-model/*`)
- Supports **inference profiles** (cross-region inference, etc.)

### Creation Script

```bash
#!/bin/bash
# Create Shared Bedrock Role

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

# 1. Create Trust Policy
cat > /tmp/openclaw-bedrock-shared-trust.json << 'EOF'
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
EOF

# 2. Create Role
aws iam create-role \
  --role-name openclaw-bedrock-shared \
  --assume-role-policy-document file:///tmp/openclaw-bedrock-shared-trust.json \
  --description "Shared IAM Role for all OpenClaw instances to access Bedrock" \
  --tags Key=managed_by,Value=openclaw-platform Key=purpose,Value=bedrock-access

# 3. Create Bedrock Permissions Policy
cat > /tmp/openclaw-bedrock-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:*:*:inference-profile/*"
      ]
    }
  ]
}
EOF

# 4. Attach Policy to Role
aws iam put-role-policy \
  --role-name openclaw-bedrock-shared \
  --policy-name BedrockAccess \
  --policy-document file:///tmp/openclaw-bedrock-policy.json

echo "✅ Shared Bedrock Role created: arn:aws:iam::${AWS_ACCOUNT_ID}:role/openclaw-bedrock-shared"
```

---

## 3. Pod Identity Associations

### Provisioning Service Association

```bash
# Link Provisioning Service to its IAM Role
aws eks create-pod-identity-association \
  --cluster-name test-s4 \
  --region us-west-2 \
  --namespace openclaw-provisioning \
  --service-account openclaw-provisioner \
  --role-arn arn:aws:iam::111122223333:role/openclaw-provisioning-service
```

**Result**:
- Association ID: `a-z1anuvondr8pwlcvb`
- Namespace: `openclaw-provisioning`
- ServiceAccount: `openclaw-provisioner`
- Role: `openclaw-provisioning-service`

### User Instance Associations

Created dynamically by provisioning service for each user:

```python
# Example from provision.py
pod_identity_association_id = create_pod_identity_association(
    cluster_name=Config.EKS_CLUSTER_NAME,
    namespace=f"openclaw-{user_id}",
    service_account=f"openclaw-{user_id}",
    role_arn=Config.SHARED_BEDROCK_ROLE_ARN,  # Shared role
    region=Config.AWS_REGION
)
```

---

## 4. Complete Deployment Script

```bash
#!/bin/bash
# Complete IAM setup for OpenClaw Shared Role Architecture

set -e

AWS_REGION="${AWS_REGION:-us-west-2}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-test-s4}"

echo "=================================="
echo "OpenClaw IAM Setup"
echo "=================================="
echo "AWS Account: $AWS_ACCOUNT_ID"
echo "AWS Region: $AWS_REGION"
echo "EKS Cluster: $EKS_CLUSTER_NAME"
echo ""

# ========================================
# 1. Create Shared Bedrock Role
# ========================================
echo "Step 1: Creating Shared Bedrock Role..."

cat > /tmp/openclaw-bedrock-shared-trust.json << 'EOF'
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
EOF

aws iam create-role \
  --role-name openclaw-bedrock-shared \
  --assume-role-policy-document file:///tmp/openclaw-bedrock-shared-trust.json \
  --description "Shared IAM Role for all OpenClaw instances to access Bedrock" \
  --tags Key=managed_by,Value=openclaw-platform Key=purpose,Value=bedrock-access \
  2>/dev/null || echo "Role already exists, skipping..."

cat > /tmp/openclaw-bedrock-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:*:*:inference-profile/*"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name openclaw-bedrock-shared \
  --policy-name BedrockAccess \
  --policy-document file:///tmp/openclaw-bedrock-policy.json

SHARED_BEDROCK_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/openclaw-bedrock-shared"
echo "✅ Shared Bedrock Role: $SHARED_BEDROCK_ROLE_ARN"
echo ""

# ========================================
# 2. Create Provisioning Service Role
# ========================================
echo "Step 2: Creating Provisioning Service Role..."

cat > /tmp/provisioning-role-trust.json << 'EOF'
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
EOF

aws iam create-role \
  --role-name openclaw-provisioning-service \
  --assume-role-policy-document file:///tmp/provisioning-role-trust.json \
  --description "IAM Role for OpenClaw Provisioning Service" \
  2>/dev/null || echo "Role already exists, skipping..."

cat > /tmp/provisioning-service-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManagePodIdentityAssociations",
      "Effect": "Allow",
      "Action": [
        "eks:CreatePodIdentityAssociation",
        "eks:DescribePodIdentityAssociation",
        "eks:ListPodIdentityAssociations",
        "eks:DeletePodIdentityAssociation"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassRoleAndGetSharedBedrockRole",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole",
        "iam:GetRole"
      ],
      "Resource": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/openclaw-bedrock-shared"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name openclaw-provisioning-service \
  --policy-name OpenClawProvisioningServicePolicy \
  --policy-document file:///tmp/provisioning-service-policy.json

PROVISIONING_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/openclaw-provisioning-service"
echo "✅ Provisioning Service Role: $PROVISIONING_ROLE_ARN"
echo ""

# ========================================
# 3. Create Pod Identity Association
# ========================================
echo "Step 3: Creating Pod Identity Association for Provisioning Service..."

ASSOCIATION_OUTPUT=$(aws eks create-pod-identity-association \
  --cluster-name "$EKS_CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace openclaw-provisioning \
  --service-account openclaw-provisioner \
  --role-arn "$PROVISIONING_ROLE_ARN" \
  --output json 2>&1 || echo '{"association":{"associationId":"already-exists"}}')

ASSOCIATION_ID=$(echo "$ASSOCIATION_OUTPUT" | jq -r '.association.associationId // "already-exists"')
echo "✅ Pod Identity Association: $ASSOCIATION_ID"
echo ""

# ========================================
# Cleanup temp files
# ========================================
rm -f /tmp/openclaw-bedrock-shared-trust.json \
      /tmp/openclaw-bedrock-policy.json \
      /tmp/provisioning-role-trust.json \
      /tmp/provisioning-service-policy.json

echo "=================================="
echo "Setup Complete!"
echo "=================================="
echo ""
echo "Summary:"
echo "  Shared Bedrock Role: $SHARED_BEDROCK_ROLE_ARN"
echo "  Provisioning Service Role: $PROVISIONING_ROLE_ARN"
echo "  Pod Identity Association: $ASSOCIATION_ID"
echo ""
echo "Next steps:"
echo "  1. Update eks-pod-service deployment.yaml with:"
echo "     SHARED_BEDROCK_ROLE_ARN=$SHARED_BEDROCK_ROLE_ARN"
echo "  2. Deploy provisioning service"
echo "  3. Test instance creation"
echo ""
```

---

## 5. Verification Commands

### Check IAM Roles

```bash
# List roles
aws iam list-roles --query 'Roles[?starts_with(RoleName, `openclaw`)].{Name:RoleName,ARN:Arn}' --output table

# Get role details
aws iam get-role --role-name openclaw-bedrock-shared
aws iam get-role --role-name openclaw-provisioning-service

# Get policies
aws iam get-role-policy --role-name openclaw-bedrock-shared --policy-name BedrockAccess
aws iam get-role-policy --role-name openclaw-provisioning-service --policy-name OpenClawProvisioningServicePolicy
```

### Check Pod Identity Associations

```bash
# List all associations
aws eks list-pod-identity-associations \
  --cluster-name test-s4 \
  --region us-west-2 \
  --output table

# Check provisioning service
aws eks list-pod-identity-associations \
  --cluster-name test-s4 \
  --region us-west-2 \
  --namespace openclaw-provisioning \
  --output json

# Check user instance
aws eks list-pod-identity-associations \
  --cluster-name test-s4 \
  --region us-west-2 \
  --namespace openclaw-<user-id> \
  --output json
```

### Test Bedrock Access from Pod

```bash
# From OpenClaw pod
kubectl exec -n openclaw-<user-id> openclaw-<user-id>-0 -c openclaw -- \
  aws bedrock list-foundation-models --region us-west-2 --query 'modelSummaries[0]'

# Should return model details without errors
```

---

## 6. Troubleshooting

### Error: "Not authorized to perform sts:AssumeRoleWithWebIdentity"

**Cause**: ServiceAccount has IRSA annotation (`eks.amazonaws.com/role-arn`)

**Fix**:
```bash
# Remove IRSA annotation
kubectl annotate sa openclaw-<user-id> -n openclaw-<user-id> eks.amazonaws.com/role-arn-

# Restart pod
kubectl delete pod openclaw-<user-id>-0 -n openclaw-<user-id>
```

### Error: "is not authorized to perform: bedrock:InvokeModel"

**Cause**: Bedrock policy missing or wrong region/resource type

**Fix**: Update policy to use wildcard regions and include inference-profile

### Error: "Caller does not have permission to perform iam:PassRole"

**Cause**: Provisioning service role missing PassRole permission

**Fix**: Add `iam:PassRole` and `iam:GetRole` to provisioning service policy

---

## 7. Migration from Per-User Roles

If you have existing users with per-user IAM roles:

```bash
#!/bin/bash
# Migrate user from per-user role to shared role

USER_ID="416e0b5f"
NAMESPACE="openclaw-${USER_ID}"
SERVICE_ACCOUNT="openclaw-${USER_ID}"
SHARED_ROLE_ARN="arn:aws:iam::111122223333:role/openclaw-bedrock-shared"

# 1. List old associations
OLD_ASSOCIATIONS=$(aws eks list-pod-identity-associations \
  --cluster-name test-s4 \
  --region us-west-2 \
  --namespace "$NAMESPACE" \
  --service-account "$SERVICE_ACCOUNT" \
  --query 'associations[].associationId' \
  --output text)

# 2. Delete old associations
for ASSOC_ID in $OLD_ASSOCIATIONS; do
  echo "Deleting old association: $ASSOC_ID"
  aws eks delete-pod-identity-association \
    --cluster-name test-s4 \
    --region us-west-2 \
    --association-id "$ASSOC_ID"
done

# 3. Create new association with shared role
echo "Creating new association with shared role"
aws eks create-pod-identity-association \
  --cluster-name test-s4 \
  --region us-west-2 \
  --namespace "$NAMESPACE" \
  --service-account "$SERVICE_ACCOUNT" \
  --role-arn "$SHARED_ROLE_ARN"

# 4. Remove IRSA annotation if present
kubectl annotate sa "$SERVICE_ACCOUNT" -n "$NAMESPACE" eks.amazonaws.com/role-arn- || true

# 5. Restart pod
kubectl delete pod "${NAMESPACE}-0" -n "$NAMESPACE"

echo "✅ Migration complete for user $USER_ID"
```

---

## 8. Security Best Practices

1. **Least Privilege**: Provisioning service only has EKS permissions, not full IAM
2. **Centralized Management**: Single shared role easier to audit and update
3. **Resource Restrictions**: Bedrock policy uses specific actions, not `bedrock:*`
4. **Region Flexibility**: Supports all regions for cross-region inference profiles
5. **Pod Identity**: Modern EKS authentication, better than IRSA

---

**Last Updated**: 2026-03-06
**Maintained By**: Claude Code
**Status**: Production Ready
