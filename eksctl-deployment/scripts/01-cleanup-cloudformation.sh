#!/bin/bash
# Cleanup existing CloudFormation deployment
# Run this BEFORE starting eksctl deployment

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== CloudFormation Cleanup Script ===${NC}"
echo ""

# Configuration
STACK_NAME=${STACK_NAME:-"openclaw-platform"}
AWS_REGION=${AWS_REGION:-"us-east-1"}

echo "Stack Name: $STACK_NAME"
echo "Region: $AWS_REGION"
echo ""

# Check if stack exists
echo "Checking if stack exists..."
STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].StackStatus' \
  --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$STACK_STATUS" == "DOES_NOT_EXIST" ]; then
  echo -e "${GREEN}✅ Stack does not exist, no cleanup needed${NC}"
  exit 0
fi

echo -e "${YELLOW}Stack Status: $STACK_STATUS${NC}"
echo ""

# Confirm deletion
echo -e "${RED}WARNING: This will delete the CloudFormation stack and all nested stacks.${NC}"
echo "This includes:"
echo "  - EKS Cluster (if created)"
echo "  - VPC and networking resources"
echo "  - IAM roles"
echo "  - Cognito User Pool"
echo ""
read -p "Are you sure you want to proceed? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
  echo -e "${YELLOW}Cleanup cancelled${NC}"
  exit 0
fi

# Delete stack
echo ""
echo "Deleting stack: $STACK_NAME..."
aws cloudformation delete-stack \
  --stack-name "$STACK_NAME" \
  --region "$AWS_REGION"

echo -e "${GREEN}✅ Delete command sent${NC}"
echo ""
echo "Waiting for stack deletion to complete (this may take 10-20 minutes)..."
echo "You can monitor progress in the AWS Console or run:"
echo ""
echo "  aws cloudformation describe-stack-events \\"
echo "    --stack-name $STACK_NAME \\"
echo "    --region $AWS_REGION \\"
echo "    --query 'StackEvents[?ResourceStatus==\`DELETE_IN_PROGRESS\` || ResourceStatus==\`DELETE_FAILED\`].[LogicalResourceId,ResourceStatus,ResourceStatusReason]' \\"
echo "    --output table"
echo ""

# Optional: Wait for deletion to complete
read -p "Wait for deletion to complete? (yes/no): " WAIT_CONFIRM

if [ "$WAIT_CONFIRM" == "yes" ]; then
  echo ""
  echo "Waiting for stack deletion..."

  aws cloudformation wait stack-delete-complete \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    && echo -e "${GREEN}✅ Stack deleted successfully${NC}" \
    || echo -e "${RED}❌ Stack deletion failed or timed out. Check AWS Console.${NC}"
else
  echo ""
  echo -e "${YELLOW}⚠️  Deletion initiated but not waiting for completion${NC}"
  echo "Proceed with eksctl deployment AFTER stack deletion completes"
fi

echo ""
echo -e "${GREEN}=== Cleanup Script Complete ===${NC}"
