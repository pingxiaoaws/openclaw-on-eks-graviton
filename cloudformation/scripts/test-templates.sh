#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
AWS_REGION="${AWS_REGION:-us-west-2}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}OpenClaw CloudFormation - Template Validation${NC}"
echo -e "${GREEN}========================================${NC}"

# Check prerequisites
echo -e "\n${YELLOW}Checking prerequisites...${NC}"
command -v aws >/dev/null 2>&1 || { echo -e "${RED}Error: AWS CLI not found${NC}" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo -e "${RED}Error: jq not found${NC}" >&2; exit 1; }

# Check AWS credentials
aws sts get-caller-identity >/dev/null 2>&1 || { echo -e "${RED}Error: AWS credentials not configured${NC}" >&2; exit 1; }
echo -e "${GREEN}✓ Prerequisites satisfied${NC}"

# Validate all templates
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Validating Templates${NC}"
echo -e "${GREEN}========================================${NC}"

cd "$ROOT_DIR"

total_templates=0
valid_templates=0
failed_templates=0

# Validate master template
echo -e "\n${BLUE}1. Validating master.yaml...${NC}"
total_templates=$((total_templates + 1))
if aws cloudformation validate-template \
    --template-body file://master.yaml \
    --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo -e "${GREEN}   ✓ master.yaml is valid${NC}"
    valid_templates=$((valid_templates + 1))
else
    echo -e "${RED}   ✗ master.yaml validation failed${NC}"
    aws cloudformation validate-template \
        --template-body file://master.yaml \
        --region "${AWS_REGION}" 2>&1 | tail -5
    failed_templates=$((failed_templates + 1))
fi

# Validate nested templates
echo -e "\n${BLUE}2. Validating nested stacks...${NC}"
for template in nested-stacks/*.yaml; do
    if [ -f "$template" ]; then
        template_name=$(basename "$template")
        total_templates=$((total_templates + 1))

        if aws cloudformation validate-template \
            --template-body file://"$template" \
            --region "${AWS_REGION}" >/dev/null 2>&1; then
            echo -e "${GREEN}   ✓ $template_name is valid${NC}"
            valid_templates=$((valid_templates + 1))
        else
            echo -e "${RED}   ✗ $template_name validation failed${NC}"
            aws cloudformation validate-template \
                --template-body file://"$template" \
                --region "${AWS_REGION}" 2>&1 | tail -5
            failed_templates=$((failed_templates + 1))
        fi
    fi
done

# Summary
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Validation Summary${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${BLUE}Total templates:${NC} $total_templates"
echo -e "${GREEN}Valid templates:${NC} $valid_templates"
if [ $failed_templates -gt 0 ]; then
    echo -e "${RED}Failed templates:${NC} $failed_templates"
else
    echo -e "${GREEN}Failed templates:${NC} 0"
fi

# Check for missing templates
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Template Completeness Check${NC}"
echo -e "${GREEN}========================================${NC}"

expected_templates=(
    "nested-stacks/01-vpc-network.yaml"
    "nested-stacks/02-iam-roles.yaml"
    "nested-stacks/03-eks-cluster.yaml"
    "nested-stacks/04-eks-nodegroups.yaml"
    "nested-stacks/05-storage.yaml"
    "nested-stacks/06-karpenter.yaml"
    "nested-stacks/07-cognito.yaml"
    "nested-stacks/08-alb.yaml"
    "nested-stacks/09-cloudfront.yaml"
    "nested-stacks/10-kubernetes-controllers.yaml"
    "nested-stacks/11-openclaw-apps.yaml"
)

existing_count=0
missing_count=0

for template in "${expected_templates[@]}"; do
    if [ -f "$template" ]; then
        echo -e "${GREEN}✓${NC} $(basename "$template")"
        existing_count=$((existing_count + 1))
    else
        echo -e "${RED}✗${NC} $(basename "$template") ${YELLOW}(missing)${NC}"
        missing_count=$((missing_count + 1))
    fi
done

echo -e "\n${BLUE}Progress:${NC} $existing_count/${#expected_templates[@]} templates (${GREEN}$(( existing_count * 100 / ${#expected_templates[@]} ))%${NC})"

# Check parameters file
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Parameters File Check${NC}"
echo -e "${GREEN}========================================${NC}"

if [ -f "parameters/dev.json" ]; then
    echo -e "${GREEN}✓${NC} parameters/dev.json exists"

    # Check for placeholder values
    if grep -q "REPLACE_WITH_YOUR_ARTIFACT_BUCKET_NAME" parameters/dev.json; then
        echo -e "${YELLOW}⚠${NC} ArtifactBucket parameter needs to be updated in parameters/dev.json"
    else
        echo -e "${GREEN}✓${NC} ArtifactBucket parameter is configured"
    fi

    # Validate JSON syntax
    if jq empty parameters/dev.json 2>/dev/null; then
        echo -e "${GREEN}✓${NC} parameters/dev.json is valid JSON"
    else
        echo -e "${RED}✗${NC} parameters/dev.json has invalid JSON syntax"
    fi
else
    echo -e "${RED}✗${NC} parameters/dev.json is missing"
fi

# Check Lambda functions
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Lambda Functions Check${NC}"
echo -e "${GREEN}========================================${NC}"

lambda_functions=(
    "custom-resources/kubectl-lambda/function.py"
    "custom-resources/kubectl-lambda/Dockerfile"
    "custom-resources/helm-lambda/function.py"
    "custom-resources/alb-waiter/function.py"
    "custom-resources/cognito-user-lambda/function.py"
)

lambda_existing=0
lambda_missing=0

for func in "${lambda_functions[@]}"; do
    if [ -f "$func" ]; then
        echo -e "${GREEN}✓${NC} $func"
        lambda_existing=$((lambda_existing + 1))
    else
        echo -e "${RED}✗${NC} $func ${YELLOW}(missing)${NC}"
        lambda_missing=$((lambda_missing + 1))
    fi
done

# Dry-run test with cfn-lint if available
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Advanced Validation (cfn-lint)${NC}"
echo -e "${GREEN}========================================${NC}"

if command -v cfn-lint >/dev/null 2>&1; then
    echo -e "${BLUE}Running cfn-lint on templates...${NC}"

    for template in master.yaml nested-stacks/*.yaml; do
        if [ -f "$template" ]; then
            template_name=$(basename "$template")
            if cfn-lint "$template" >/dev/null 2>&1; then
                echo -e "${GREEN}✓${NC} $template_name passes cfn-lint"
            else
                echo -e "${YELLOW}⚠${NC} $template_name has cfn-lint warnings:"
                cfn-lint "$template" | head -10
            fi
        fi
    done
else
    echo -e "${YELLOW}⚠${NC} cfn-lint not installed (optional)"
    echo -e "   Install with: pip install cfn-lint"
fi

# Final summary
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Overall Status${NC}"
echo -e "${GREEN}========================================${NC}"

if [ $failed_templates -eq 0 ] && [ $existing_count -ge 5 ]; then
    echo -e "${GREEN}✓ Templates are valid and ready for testing${NC}"
    echo -e ""
    echo -e "${BLUE}Next steps:${NC}"
    echo -e "  1. Update parameters/dev.json with your ArtifactBucket"
    echo -e "  2. Create an S3 bucket for artifacts:"
    echo -e "     ${YELLOW}export ARTIFACT_BUCKET=openclaw-artifacts-\$(date +%s)${NC}"
    echo -e "     ${YELLOW}aws s3 mb s3://\$ARTIFACT_BUCKET --region ${AWS_REGION}${NC}"
    echo -e "  3. Update parameters/dev.json:"
    echo -e "     ${YELLOW}sed -i '' 's/REPLACE_WITH_YOUR_ARTIFACT_BUCKET_NAME/'\$ARTIFACT_BUCKET'/' parameters/dev.json${NC}"
    echo -e "  4. Test partial deployment:"
    echo -e "     ${YELLOW}./scripts/deploy-infra-only.sh${NC}"
    echo -e ""
    echo -e "${GREEN}Status: Ready for partial deployment (VPC, IAM, EKS, Storage)${NC}"
else
    if [ $failed_templates -gt 0 ]; then
        echo -e "${RED}✗ Some templates have validation errors${NC}"
        echo -e "   Fix the errors above before deploying"
    fi
    if [ $existing_count -lt 5 ]; then
        echo -e "${YELLOW}⚠ Only $existing_count/11 templates complete${NC}"
        echo -e "   See IMPLEMENTATION-STATUS.md for remaining work"
    fi
fi

echo -e "\n${GREEN}========================================${NC}"
