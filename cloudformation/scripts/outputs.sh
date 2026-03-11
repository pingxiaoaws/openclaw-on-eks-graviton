#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

AWS_REGION="${AWS_REGION:-us-west-2}"
STACK_NAME="${1:-openclaw-platform}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}OpenClaw Platform - Stack Outputs${NC}"
echo -e "${GREEN}========================================${NC}"

# Check if stack exists
if ! aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo -e "${RED}Error: Stack '${STACK_NAME}' not found in region ${AWS_REGION}${NC}"
    exit 1
fi

# Get stack status
STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${AWS_REGION}" \
    --query 'Stacks[0].StackStatus' \
    --output text)

echo -e "\n${BLUE}Stack Status:${NC} ${STACK_STATUS}"

if [ "$STACK_STATUS" != "CREATE_COMPLETE" ] && [ "$STACK_STATUS" != "UPDATE_COMPLETE" ]; then
    echo -e "${YELLOW}Warning: Stack is not in a complete state${NC}"
fi

# Function to get output value
get_output() {
    local output_key=$1
    aws cloudformation describe-stacks \
        --stack-name "${STACK_NAME}" \
        --region "${AWS_REGION}" \
        --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue" \
        --output text 2>/dev/null || echo "N/A"
}

# Get all outputs
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}PRIMARY ACCESS${NC}"
echo -e "${GREEN}========================================${NC}"

CLOUDFRONT_URL=$(get_output "CloudFrontDomainName")
LOGIN_URL="https://${CLOUDFRONT_URL}/login"

echo -e "${BLUE}Login URL:${NC}"
echo -e "  ${LOGIN_URL}"

echo -e "\n${BLUE}Test User Credentials:${NC}"
TEST_USER_EMAIL=$(get_output "TestUserEmail")
echo -e "  Email: ${TEST_USER_EMAIL}"

TEST_PASSWORD_SECRET_ARN=$(get_output "TestUserPasswordSecretArn")
if [ "$TEST_PASSWORD_SECRET_ARN" != "N/A" ]; then
    TEST_PASSWORD=$(aws secretsmanager get-secret-value \
        --secret-id "${TEST_PASSWORD_SECRET_ARN}" \
        --query SecretString \
        --output text \
        --region "${AWS_REGION}" 2>/dev/null || echo "Error retrieving password")
    echo -e "  Password: ${TEST_PASSWORD}"
    echo -e "\n${BLUE}Or retrieve password with:${NC}"
    echo -e "  $(get_output 'GetPasswordCommand')"
fi

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}CLUSTER ACCESS${NC}"
echo -e "${GREEN}========================================${NC}"

CLUSTER_NAME=$(get_output "ClusterName")
CLUSTER_ENDPOINT=$(get_output "ClusterEndpoint")

echo -e "${BLUE}Cluster Name:${NC} ${CLUSTER_NAME}"
echo -e "${BLUE}Cluster Endpoint:${NC} ${CLUSTER_ENDPOINT}"

echo -e "\n${BLUE}Configure kubectl:${NC}"
echo -e "  $(get_output 'GetKubeconfigCommand')"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}AWS RESOURCES${NC}"
echo -e "${GREEN}========================================${NC}"

VPC_ID=$(get_output "VpcId")
EFS_ID=$(get_output "EfsFileSystemId")
USER_POOL_ID=$(get_output "UserPoolId")
CLIENT_ID=$(get_output "UserPoolClientId")
BEDROCK_ROLE=$(get_output "SharedBedrockRoleArn")
ALB_ARN=$(get_output "AlbArn")

echo -e "${BLUE}VPC ID:${NC} ${VPC_ID}"
echo -e "${BLUE}EFS File System ID:${NC} ${EFS_ID}"
echo -e "${BLUE}Cognito User Pool ID:${NC} ${USER_POOL_ID}"
echo -e "${BLUE}Cognito Client ID:${NC} ${CLIENT_ID}"
echo -e "${BLUE}Shared Bedrock Role ARN:${NC}"
echo -e "  ${BEDROCK_ROLE}"
echo -e "${BLUE}ALB ARN:${NC}"
echo -e "  ${ALB_ARN}"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}QUICK COMMANDS${NC}"
echo -e "${GREEN}========================================${NC}"

echo -e "${BLUE}Get cluster nodes:${NC}"
echo -e "  kubectl get nodes"

echo -e "\n${BLUE}Check Kata RuntimeClasses:${NC}"
echo -e "  kubectl get runtimeclass"

echo -e "\n${BLUE}Check controllers:${NC}"
echo -e "  kubectl get deployment -n kube-system aws-load-balancer-controller"
echo -e "  kubectl get deployment -n kube-system karpenter"
echo -e "  kubectl get deployment -n openclaw-operator-system openclaw-operator"
echo -e "  kubectl get deployment -n openclaw-provisioning openclaw-provisioner"

echo -e "\n${BLUE}List OpenClaw instances:${NC}"
echo -e "  kubectl get openclawinstances -A"

echo -e "\n${BLUE}Check Kata nodes:${NC}"
echo -e "  kubectl get nodes -l workload-type=kata"

echo -e "\n${BLUE}View provisioning service logs:${NC}"
echo -e "  kubectl logs -n openclaw-provisioning -l app=openclaw-provisioner -f"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}CONSOLE LINKS${NC}"
echo -e "${GREEN}========================================${NC}"

echo -e "${BLUE}CloudFormation Stack:${NC}"
echo -e "  https://console.aws.amazon.com/cloudformation/home?region=${AWS_REGION}#/stacks/stackinfo?stackId=${STACK_NAME}"

echo -e "\n${BLUE}EKS Cluster:${NC}"
echo -e "  https://console.aws.amazon.com/eks/home?region=${AWS_REGION}#/clusters/${CLUSTER_NAME}"

echo -e "\n${BLUE}CloudFront Distribution:${NC}"
echo -e "  https://console.aws.amazon.com/cloudfront/v3/home#/distributions"

echo -e "\n${BLUE}Cognito User Pool:${NC}"
echo -e "  https://console.aws.amazon.com/cognito/v2/idp/user-pools?region=${AWS_REGION}"

echo -e "\n${BLUE}EFS File System:${NC}"
echo -e "  https://console.aws.amazon.com/efs/home?region=${AWS_REGION}#/file-systems/${EFS_ID}"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}NEXT STEPS${NC}"
echo -e "${GREEN}========================================${NC}"

echo -e "1. ${BLUE}Configure kubectl:${NC}"
echo -e "   aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}"

echo -e "\n2. ${BLUE}Run validation:${NC}"
echo -e "   ./scripts/validate.sh ${STACK_NAME} ${AWS_REGION}"

echo -e "\n3. ${BLUE}Login to OpenClaw:${NC}"
echo -e "   Open: ${LOGIN_URL}"
echo -e "   Email: ${TEST_USER_EMAIL}"
echo -e "   Password: (see above)"

echo -e "\n4. ${BLUE}Create your first instance:${NC}"
echo -e "   kubectl apply -f examples/openclaw-instance.yaml"
echo -e "   # Or create via UI"

echo -e "\n${GREEN}========================================${NC}"

# Full outputs table
echo -e "\n${BLUE}All Stack Outputs:${NC}"
aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue,Description]' \
    --output table
