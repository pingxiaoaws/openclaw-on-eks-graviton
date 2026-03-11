#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}OpenClaw - 部署前检查${NC}"
echo -e "${GREEN}========================================${NC}"

# Track failures
CHECKS_PASSED=0
CHECKS_FAILED=0

check_command() {
    if command -v $1 >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $1 已安装"
        ((CHECKS_PASSED++))
    else
        echo -e "${RED}✗${NC} $1 未安装"
        echo "   安装方法: $2"
        ((CHECKS_FAILED++))
    fi
}

check_aws_auth() {
    if aws sts get-caller-identity >/dev/null 2>&1; then
        ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
        USER_ARN=$(aws sts get-caller-identity --query Arn --output text)
        echo -e "${GREEN}✓${NC} AWS 认证成功"
        echo "   Account: ${ACCOUNT_ID}"
        echo "   User: ${USER_ARN}"
        ((CHECKS_PASSED++))
    else
        echo -e "${RED}✗${NC} AWS 认证失败"
        echo "   运行: aws configure"
        ((CHECKS_FAILED++))
    fi
}

check_aws_region() {
    REGION=${AWS_REGION:-$(aws configure get region)}
    if [ -n "$REGION" ]; then
        echo -e "${GREEN}✓${NC} AWS Region: ${REGION}"
        export AWS_REGION=$REGION
        ((CHECKS_PASSED++))
    else
        echo -e "${RED}✗${NC} AWS Region 未设置"
        echo "   运行: export AWS_REGION=us-west-2"
        ((CHECKS_FAILED++))
    fi
}

check_quota() {
    QUOTA_NAME=$1
    SERVICE_CODE=$2
    QUOTA_CODE=$3
    MIN_VALUE=$4

    VALUE=$(aws service-quotas get-service-quota \
        --service-code $SERVICE_CODE \
        --quota-code $QUOTA_CODE \
        --query 'Quota.Value' \
        --output text 2>/dev/null || echo "0")

    if [ $(echo "$VALUE >= $MIN_VALUE" | bc) -eq 1 ]; then
        echo -e "${GREEN}✓${NC} ${QUOTA_NAME}: ${VALUE} (需要 ${MIN_VALUE})"
        ((CHECKS_PASSED++))
    else
        echo -e "${YELLOW}⚠${NC} ${QUOTA_NAME}: ${VALUE} (建议 ${MIN_VALUE})"
        echo "   可能需要申请配额增加"
    fi
}

echo ""
echo -e "${YELLOW}1. 检查必需工具...${NC}"
check_command "aws" "curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip' && unzip awscliv2.zip && sudo ./aws/install"
check_command "kubectl" "curl -LO 'https://dl.k8s.io/release/v1.34.0/bin/linux/amd64/kubectl' && chmod +x kubectl && sudo mv kubectl /usr/local/bin/"
check_command "helm" "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
check_command "jq" "sudo apt-get install jq (Ubuntu) 或 brew install jq (macOS)"

echo ""
echo -e "${YELLOW}2. 检查 AWS 认证...${NC}"
check_aws_auth
check_aws_region

echo ""
echo -e "${YELLOW}3. 检查 IAM 权限...${NC}"

# Test key permissions
if aws iam list-roles --max-items 1 >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} IAM 读取权限"
    ((CHECKS_PASSED++))
else
    echo -e "${RED}✗${NC} IAM 读取权限不足"
    ((CHECKS_FAILED++))
fi

if aws cloudformation describe-stacks --max-results 1 >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} CloudFormation 权限"
    ((CHECKS_PASSED++))
else
    echo -e "${RED}✗${NC} CloudFormation 权限不足"
    ((CHECKS_FAILED++))
fi

if aws eks list-clusters --max-results 1 >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} EKS 权限"
    ((CHECKS_PASSED++))
else
    echo -e "${RED}✗${NC} EKS 权限不足"
    ((CHECKS_FAILED++))
fi

echo ""
echo -e "${YELLOW}4. 检查 AWS 配额 (可选)...${NC}"
echo "   注意: 如果无法检查配额，部署时可能会遇到限制"

check_quota "EKS Clusters" "eks" "L-1194D53C" "1"
check_quota "VPCs" "vpc" "L-F678F1CE" "1"
check_quota "NAT Gateways" "vpc" "L-FE5A380F" "1"

# Check bare metal quota (may fail if not set)
echo ""
echo -e "${YELLOW}5. 检查 Bare Metal 实例配额...${NC}"
for INSTANCE_TYPE in "c6g.metal" "m6g.metal"; do
    QUOTA=$(aws service-quotas get-service-quota \
        --service-code ec2 \
        --quota-code L-DB2E81BA \
        --query 'Quota.Value' \
        --output text 2>/dev/null || echo "未设置")

    if [ "$QUOTA" != "未设置" ] && [ $(echo "$QUOTA >= 2" | bc) -eq 1 ]; then
        echo -e "${GREEN}✓${NC} Running On-Demand ${INSTANCE_TYPE} instances: ${QUOTA}"
    else
        echo -e "${YELLOW}⚠${NC} Running On-Demand ${INSTANCE_TYPE} instances: ${QUOTA}"
        echo "   建议: 申请配额增加到至少 2 个"
        echo "   https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-DB2E81BA"
    fi
done

echo ""
echo -e "${YELLOW}6. 检查本地文件...${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

FILES=(
    "master.yaml"
    "nested-stacks/01-vpc-network.yaml"
    "nested-stacks/02-iam-roles.yaml"
    "nested-stacks/03-eks-cluster.yaml"
    "nested-stacks/04-eks-nodegroups.yaml"
    "nested-stacks/05-storage.yaml"
    "nested-stacks/07-cognito.yaml"
    "nested-stacks/08-alb.yaml"
    "nested-stacks/09-cloudfront.yaml"
    "nested-stacks/10-kubernetes-controllers.yaml"
    "nested-stacks/11-openclaw-apps.yaml"
    "parameters/dev.json"
)

for file in "${FILES[@]}"; do
    if [ -f "$file" ]; then
        echo -e "${GREEN}✓${NC} $file"
        ((CHECKS_PASSED++))
    else
        echo -e "${RED}✗${NC} $file 缺失"
        ((CHECKS_FAILED++))
    fi
done

echo ""
echo -e "${YELLOW}7. 检查参数配置...${NC}"

if [ -f "parameters/dev.json" ]; then
    ARTIFACT_BUCKET=$(jq -r '.[] | select(.ParameterKey=="ArtifactBucket") | .ParameterValue' parameters/dev.json)

    if [ "$ARTIFACT_BUCKET" == "REPLACE_WITH_YOUR_ARTIFACT_BUCKET_NAME" ]; then
        echo -e "${RED}✗${NC} ArtifactBucket 需要配置"
        echo "   运行: export ARTIFACT_BUCKET='openclaw-artifacts-\$(date +%s)'"
        echo "         sed -i '' \"s/REPLACE_WITH_YOUR_ARTIFACT_BUCKET_NAME/\$ARTIFACT_BUCKET/\" parameters/dev.json"
        ((CHECKS_FAILED++))
    else
        echo -e "${GREEN}✓${NC} ArtifactBucket: ${ARTIFACT_BUCKET}"
        ((CHECKS_PASSED++))

        # Check if bucket exists
        if aws s3 ls "s3://${ARTIFACT_BUCKET}" >/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} S3 Bucket 已存在"
            ((CHECKS_PASSED++))
        else
            echo -e "${YELLOW}⚠${NC} S3 Bucket 不存在，部署时会自动创建"
        fi
    fi

    TEST_USER_EMAIL=$(jq -r '.[] | select(.ParameterKey=="TestUserEmail") | .ParameterValue' parameters/dev.json)
    echo -e "${GREEN}✓${NC} TestUserEmail: ${TEST_USER_EMAIL}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}检查结果${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}通过:${NC} ${CHECKS_PASSED}"
echo -e "${RED}失败:${NC} ${CHECKS_FAILED}"

if [ $CHECKS_FAILED -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✓ 所有检查通过！可以开始部署${NC}"
    echo ""
    echo -e "${YELLOW}下一步:${NC}"
    echo "  ./scripts/deploy.sh"
    exit 0
else
    echo ""
    echo -e "${RED}✗ 部分检查失败，请先解决上述问题${NC}"
    exit 1
fi
