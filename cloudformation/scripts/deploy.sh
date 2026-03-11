#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
AWS_REGION="${AWS_REGION:-us-west-2}"
STACK_NAME="${STACK_NAME:-openclaw-platform}"
PARAMS_FILE="${PARAMS_FILE:-$ROOT_DIR/parameters/dev.json}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}OpenClaw Platform Deployment${NC}"
echo -e "${GREEN}========================================${NC}"

# Check prerequisites
echo -e "\n${YELLOW}Checking prerequisites...${NC}"

command -v aws >/dev/null 2>&1 || { echo -e "${RED}Error: AWS CLI not found${NC}" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo -e "${RED}Error: jq not found${NC}" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}Error: kubectl not found${NC}" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo -e "${RED}Error: helm not found${NC}" >&2; exit 1; }

echo -e "${GREEN}✓ All prerequisites satisfied${NC}"

# Check AWS credentials
echo -e "\n${YELLOW}Checking AWS credentials...${NC}"
aws sts get-caller-identity >/dev/null 2>&1 || { echo -e "${RED}Error: AWS credentials not configured${NC}" >&2; exit 1; }
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo -e "${GREEN}✓ AWS Account: ${AWS_ACCOUNT_ID}${NC}"
echo -e "${GREEN}✓ Region: ${AWS_REGION}${NC}"

# Check if parameters file exists
if [ ! -f "$PARAMS_FILE" ]; then
    echo -e "${RED}Error: Parameters file not found: ${PARAMS_FILE}${NC}" >&2
    exit 1
fi

# Extract artifact bucket from parameters
ARTIFACT_BUCKET=$(jq -r '.[] | select(.ParameterKey=="ArtifactBucket") | .ParameterValue' "$PARAMS_FILE")

if [ "$ARTIFACT_BUCKET" == "REPLACE_WITH_YOUR_ARTIFACT_BUCKET_NAME" ]; then
    echo -e "${RED}Error: Please update ArtifactBucket in ${PARAMS_FILE}${NC}" >&2
    exit 1
fi

echo -e "\n${YELLOW}Step 1: Creating artifact bucket...${NC}"

if aws s3 ls "s3://${ARTIFACT_BUCKET}" 2>&1 | grep -q 'NoSuchBucket'; then
    aws s3 mb "s3://${ARTIFACT_BUCKET}" --region "${AWS_REGION}"
    echo -e "${GREEN}✓ Created bucket: ${ARTIFACT_BUCKET}${NC}"
else
    echo -e "${GREEN}✓ Bucket already exists: ${ARTIFACT_BUCKET}${NC}"
fi

# Enable versioning
aws s3api put-bucket-versioning \
    --bucket "${ARTIFACT_BUCKET}" \
    --versioning-configuration Status=Enabled \
    --region "${AWS_REGION}"

echo -e "\n${YELLOW}Step 2: Uploading CloudFormation templates...${NC}"

aws s3 sync "${ROOT_DIR}" "s3://${ARTIFACT_BUCKET}/cloudformation/" \
    --exclude ".git/*" \
    --exclude "*.md" \
    --exclude "scripts/*" \
    --exclude "parameters/*" \
    --exclude "custom-resources/*" \
    --region "${AWS_REGION}"

echo -e "${GREEN}✓ Templates uploaded${NC}"

echo -e "\n${YELLOW}Step 3: Building Lambda layers...${NC}"

# kubectl Lambda layer
echo -e "\n${YELLOW}Building kubectl Lambda layer...${NC}"
cd "${ROOT_DIR}/custom-resources/kubectl-lambda"

if [ -f "Dockerfile" ]; then
    docker build -t kubectl-lambda-layer .
    docker create --name kubectl-temp kubectl-lambda-layer
    docker cp kubectl-temp:/opt/layer.zip kubectl-layer.zip
    docker rm kubectl-temp

    aws s3 cp kubectl-layer.zip \
        "s3://${ARTIFACT_BUCKET}/lambda-layers/kubectl-layer.zip" \
        --region "${AWS_REGION}"

    KUBECTL_LAYER_ARN=$(aws lambda publish-layer-version \
        --layer-name kubectl-layer \
        --description "kubectl and helm for EKS management" \
        --license-info "Apache-2.0" \
        --content "S3Bucket=${ARTIFACT_BUCKET},S3Key=lambda-layers/kubectl-layer.zip" \
        --compatible-runtimes python3.12 \
        --region "${AWS_REGION}" \
        --query 'LayerVersionArn' \
        --output text)

    echo -e "${GREEN}✓ kubectl layer ARN: ${KUBECTL_LAYER_ARN}${NC}"
else
    echo -e "${YELLOW}⚠ Dockerfile not found, skipping kubectl layer${NC}"
fi

# Upload other Lambda functions
echo -e "\n${YELLOW}Step 4: Uploading Lambda functions...${NC}"

for lambda_dir in helm-lambda alb-waiter cognito-user-lambda; do
    if [ -d "${ROOT_DIR}/custom-resources/${lambda_dir}" ]; then
        cd "${ROOT_DIR}/custom-resources/${lambda_dir}"
        zip -r "${lambda_dir}.zip" function.py requirements.txt 2>/dev/null || zip -r "${lambda_dir}.zip" function.py
        aws s3 cp "${lambda_dir}.zip" \
            "s3://${ARTIFACT_BUCKET}/lambda-functions/${lambda_dir}.zip" \
            --region "${AWS_REGION}"
        echo -e "${GREEN}✓ Uploaded ${lambda_dir}${NC}"
    fi
done

echo -e "\n${YELLOW}Step 5: Validating CloudFormation template...${NC}"

cd "${ROOT_DIR}"
aws cloudformation validate-template \
    --template-body file://master.yaml \
    --region "${AWS_REGION}" >/dev/null

echo -e "${GREEN}✓ Template validated${NC}"

echo -e "\n${YELLOW}Step 6: Creating CloudFormation stack...${NC}"
echo -e "${YELLOW}This will take approximately 40-50 minutes.${NC}"

aws cloudformation create-stack \
    --stack-name "${STACK_NAME}" \
    --template-body file://master.yaml \
    --parameters file://"${PARAMS_FILE}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "${AWS_REGION}" \
    --on-failure DELETE \
    --tags Key=Environment,Value=dev Key=Project,Value=openclaw

echo -e "${GREEN}✓ Stack creation initiated${NC}"

echo -e "\n${YELLOW}Monitoring stack creation...${NC}"
echo -e "${YELLOW}You can monitor progress in AWS Console:${NC}"
echo -e "${YELLOW}https://console.aws.amazon.com/cloudformation/home?region=${AWS_REGION}#/stacks${NC}"

# Wait for stack creation
aws cloudformation wait stack-create-complete \
    --stack-name "${STACK_NAME}" \
    --region "${AWS_REGION}" 2>&1 | while read -r line; do
    echo "$line"
done

if [ $? -eq 0 ]; then
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}🎉 Stack created successfully!${NC}"
    echo -e "${GREEN}========================================${NC}"

    # Get outputs
    echo -e "\n${YELLOW}Retrieving stack outputs...${NC}"

    CLOUDFRONT_URL=$(aws cloudformation describe-stacks \
        --stack-name "${STACK_NAME}" \
        --region "${AWS_REGION}" \
        --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDomainName`].OutputValue' \
        --output text)

    TEST_USER_EMAIL=$(aws cloudformation describe-stacks \
        --stack-name "${STACK_NAME}" \
        --region "${AWS_REGION}" \
        --query 'Stacks[0].Outputs[?OutputKey==`TestUserEmail`].OutputValue' \
        --output text)

    TEST_PASSWORD_SECRET_ARN=$(aws cloudformation describe-stacks \
        --stack-name "${STACK_NAME}" \
        --region "${AWS_REGION}" \
        --query 'Stacks[0].Outputs[?OutputKey==`TestUserPasswordSecretArn`].OutputValue' \
        --output text)

    TEST_PASSWORD=$(aws secretsmanager get-secret-value \
        --secret-id "${TEST_PASSWORD_SECRET_ARN}" \
        --query SecretString \
        --output text \
        --region "${AWS_REGION}" 2>/dev/null || echo "N/A")

    CLUSTER_NAME=$(aws cloudformation describe-stacks \
        --stack-name "${STACK_NAME}" \
        --region "${AWS_REGION}" \
        --query 'Stacks[0].Outputs[?OutputKey==`ClusterName`].OutputValue' \
        --output text)

    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}DEPLOYMENT COMPLETE${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e ""
    echo -e "${GREEN}Login URL:${NC} https://${CLOUDFRONT_URL}/login"
    echo -e "${GREEN}Email:${NC} ${TEST_USER_EMAIL}"
    echo -e "${GREEN}Password:${NC} ${TEST_PASSWORD}"
    echo -e ""
    echo -e "${GREEN}Configure kubectl:${NC}"
    echo -e "  aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}"
    echo -e ""
    echo -e "${GREEN}Next steps:${NC}"
    echo -e "  1. Run validation: ./scripts/validate.sh"
    echo -e "  2. View all outputs: ./scripts/outputs.sh"
    echo -e "  3. Create your first OpenClaw instance via UI"
    echo -e ""
    echo -e "${GREEN}========================================${NC}"

else
    echo -e "\n${RED}========================================${NC}"
    echo -e "${RED}Stack creation failed!${NC}"
    echo -e "${RED}========================================${NC}"

    echo -e "\n${YELLOW}Last 20 stack events:${NC}"
    aws cloudformation describe-stack-events \
        --stack-name "${STACK_NAME}" \
        --region "${AWS_REGION}" \
        --max-items 20 \
        --query 'StackEvents[*].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId,ResourceStatusReason]' \
        --output table

    exit 1
fi
