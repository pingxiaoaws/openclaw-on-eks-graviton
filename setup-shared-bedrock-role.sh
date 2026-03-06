#!/bin/bash

# Setup script for shared IAM Roles
# - Creates shared Bedrock IAM Role (openclaw-bedrock-shared)
# - Creates Provisioning Service IAM Role (openclaw-provisioning-service)
# - Creates Pod Identity Association for Provisioning Service

set -e

AWS_REGION="${AWS_REGION:-us-west-2}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-test-s4}"

echo "=================================="
echo "Shared IAM Role Setup"
echo "=================================="
echo "AWS Account: $AWS_ACCOUNT_ID"
echo "AWS Region: $AWS_REGION"
echo "EKS Cluster: $EKS_CLUSTER_NAME"
echo ""

# Phase 1: Create Shared Bedrock IAM Role
echo "Phase 1: Creating Shared Bedrock IAM Role..."
echo ""

# 1.1 Create Trust Policy
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

echo "Creating IAM Role: openclaw-bedrock-shared..."
aws iam create-role \
  --role-name openclaw-bedrock-shared \
  --assume-role-policy-document file:///tmp/openclaw-bedrock-shared-trust.json \
  --description "Shared IAM Role for all OpenClaw instances to access Bedrock" \
  --tags Key=managed_by,Value=openclaw-platform Key=purpose,Value=bedrock-access \
  2>/dev/null || echo "Role already exists, skipping..."

# 1.2 Attach Bedrock Permissions
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
        "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-*",
        "arn:aws:bedrock:us-west-2::foundation-model/us.anthropic.claude-*"
      ]
    }
  ]
}
EOF

echo "Attaching Bedrock policy to role..."
aws iam put-role-policy \
  --role-name openclaw-bedrock-shared \
  --policy-name BedrockAccess \
  --policy-document file:///tmp/openclaw-bedrock-policy.json

SHARED_BEDROCK_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/openclaw-bedrock-shared"
echo "✅ Shared Bedrock Role: $SHARED_BEDROCK_ROLE_ARN"
echo ""

# Phase 2: Create Provisioning Service IAM Role + Pod Identity
echo "Phase 2: Creating Provisioning Service IAM Role..."
echo ""

# 2.1 Create IAM Policy
cat > /tmp/provisioning-service-policy.json << 'EOF'
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
    }
  ]
}
EOF

echo "Creating IAM Policy: OpenClawProvisioningServicePolicy..."
POLICY_ARN=$(aws iam create-policy \
  --policy-name OpenClawProvisioningServicePolicy \
  --policy-document file:///tmp/provisioning-service-policy.json \
  --description "Allows OpenClaw Provisioning Service to manage Pod Identity Associations" \
  --query 'Policy.Arn' \
  --output text 2>/dev/null || echo "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/OpenClawProvisioningServicePolicy")

echo "✅ Policy ARN: $POLICY_ARN"

# 2.2 Create IAM Role
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

echo "Creating IAM Role: openclaw-provisioning-service..."
aws iam create-role \
  --role-name openclaw-provisioning-service \
  --assume-role-policy-document file:///tmp/provisioning-role-trust.json \
  --description "IAM Role for OpenClaw Provisioning Service" \
  2>/dev/null || echo "Role already exists, skipping..."

echo "Attaching policy to role..."
aws iam attach-role-policy \
  --role-name openclaw-provisioning-service \
  --policy-arn "$POLICY_ARN"

PROVISIONING_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/openclaw-provisioning-service"
echo "✅ Provisioning Service Role: $PROVISIONING_ROLE_ARN"
echo ""

# 2.3 Create Pod Identity Association
echo "Creating Pod Identity Association for Provisioning Service..."
ASSOCIATION_OUTPUT=$(aws eks create-pod-identity-association \
  --cluster-name "$EKS_CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace openclaw-provisioning \
  --service-account openclaw-provisioner \
  --role-arn "$PROVISIONING_ROLE_ARN" \
  --output json 2>&1 || echo '{"associationId":"already-exists"}')

ASSOCIATION_ID=$(echo "$ASSOCIATION_OUTPUT" | jq -r '.association.associationId // .associationId')
echo "✅ Pod Identity Association: $ASSOCIATION_ID"
echo ""

# Cleanup temp files
rm -f /tmp/openclaw-bedrock-shared-trust.json \
      /tmp/openclaw-bedrock-policy.json \
      /tmp/provisioning-service-policy.json \
      /tmp/provisioning-role-trust.json

echo "=================================="
echo "Setup Complete!"
echo "=================================="
echo ""
echo "Summary:"
echo "  Shared Bedrock Role ARN: $SHARED_BEDROCK_ROLE_ARN"
echo "  Provisioning Service Role ARN: $PROVISIONING_ROLE_ARN"
echo "  Pod Identity Association ID: $ASSOCIATION_ID"
echo ""
echo "Next steps:"
echo "  1. Update eks-pod-service code (config.py, provision.py, delete.py)"
echo "  2. Update kubernetes/deployment.yaml with environment variables"
echo "  3. Rebuild and deploy provisioning service"
echo "  4. Test with new user creation"
echo ""
