#!/bin/bash
export AWS_PAGER=""
# Cleanup Application Stack (reverse of 05-deploy-application-stack-db.sh)
#
# Deletes all resources created by the application stack deployment:
# - OpenClaw user instances (openclaw-* namespaces)
# - Ingress / ALB
# - Provisioning service resources (deployment, postgres, RBAC, secrets, PVC)
# - CloudFront distribution
# - Security groups (CloudFront SG + cluster SG rules)
# - Pod Identity associations (provisioning + bedrock, NOT EFS)
# - IAM roles & policies (Bedrock + Provisioning)
# - openclaw-provisioning namespace
#
# Does NOT delete: EKS cluster, EFS, controllers, openclaw-operator-system

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${RED}=== Cleanup Application Stack (reverse of 05-deploy-application-stack-db.sh) ===${NC}"
echo ""

# ============================================================================
# Auto-detect cluster info
# ============================================================================

# Resolve from cluster ARN, not context name which may be an alias
CLUSTER_ARN=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
if [[ "$CLUSTER_ARN" == arn:aws:eks:* ]]; then
  AWS_REGION=$(echo "$CLUSTER_ARN" | cut -d':' -f4)
  CLUSTER_NAME=$(echo "$CLUSTER_ARN" | cut -d'/' -f2)
else
  CONTEXT=$(kubectl config current-context)
  CLUSTER_NAME=$(echo "$CONTEXT" | cut -d'@' -f2 | cut -d'.' -f1)
  AWS_REGION=$(echo "$CONTEXT" | grep -o 'us-[a-z]*-[0-9]' || echo "us-east-1")
fi
AWS_ACCOUNT=${AWS_ACCOUNT_ID:-${AWS_ACCOUNT:-$(aws sts get-caller-identity --query Account --output text)}}

echo "Cluster: $CLUSTER_NAME"
echo "Region:  $AWS_REGION"
echo "Account: $AWS_ACCOUNT"
echo ""

# Track what was deleted vs already gone
DELETED=()
SKIPPED=()

# ============================================================================
# Step 1: Confirmation
# ============================================================================

echo -e "${RED}This will delete ALL resources created by 05-deploy-application-stack-db.sh${NC}"
echo ""
echo "Resources that will be deleted:"
echo "  - OpenClaw user instances (openclaw-* namespaces except operator)"
echo "  - Ingress (openclaw-provisioning-public) + ALB"
echo "  - Provisioning service (deployment, postgres, services, secrets, PVC)"
echo "  - RBAC (ClusterRole, ClusterRoleBinding, ServiceAccount)"
echo "  - CloudFront distribution (OpenClaw-${CLUSTER_NAME})"
echo "  - Security group (openclaw-alb-cloudfront-only) + cluster SG rules"
echo "  - Pod Identity associations (provisioning + bedrock)"
echo "  - IAM roles & policies (OpenClawBedrockRole, openclaw-provisioning-service)"
echo "  - Namespace openclaw-provisioning"
echo ""
echo -e "${YELLOW}NOT deleted: EKS cluster, EFS, controllers, openclaw-operator-system${NC}"
echo ""

read -p "Type DELETE to confirm: " CONFIRM
if [ "$CONFIRM" != "DELETE" ]; then
  echo -e "${YELLOW}Cancelled.${NC}"
  exit 1
fi

echo ""
echo -e "${GREEN}Confirmed. Starting cleanup...${NC}"
echo ""

# ============================================================================
# Step 2: Delete OpenClaw user instances
# ============================================================================

echo -e "${CYAN}[Step 2/10] Deleting OpenClaw user instances...${NC}"

USER_NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep '^openclaw-' | grep -v '^openclaw-operator-system$' | grep -v '^openclaw-provisioning$' || echo "")

if [ -n "$USER_NAMESPACES" ]; then
  for NS in $USER_NAMESPACES; do
    echo "  Deleting namespace: $NS"
    kubectl delete namespace "$NS" --wait=false 2>/dev/null || true
    DELETED+=("namespace/$NS")
  done
else
  echo "  No user namespaces found"
  SKIPPED+=("user namespaces (not found)")
fi

# Also delete openclaw namespace if it exists (created by step 3 of 05 script)
if kubectl get namespace openclaw &>/dev/null; then
  echo "  Deleting namespace: openclaw"
  kubectl delete namespace openclaw --wait=false 2>/dev/null || true
  DELETED+=("namespace/openclaw")
fi

echo ""

# ============================================================================
# Step 3: Delete Ingress (triggers ALB deletion)
# ============================================================================

echo -e "${CYAN}[Step 3/10] Deleting Ingress (triggers ALB cleanup)...${NC}"

if kubectl get ingress openclaw-provisioning-public -n openclaw-provisioning &>/dev/null; then
  kubectl delete ingress openclaw-provisioning-public -n openclaw-provisioning 2>/dev/null || true
  DELETED+=("ingress/openclaw-provisioning-public")
  echo "  Deleted ingress openclaw-provisioning-public"
  echo "  Waiting 30s for ALB controller to clean up ALB..."
  sleep 30
else
  echo "  Ingress not found"
  SKIPPED+=("ingress/openclaw-provisioning-public (not found)")
fi

echo ""

# ============================================================================
# Step 4: Delete K8s resources in openclaw-provisioning namespace
# ============================================================================

echo -e "${CYAN}[Step 4/10] Deleting K8s resources in openclaw-provisioning...${NC}"

if kubectl get namespace openclaw-provisioning &>/dev/null; then
  # Deployment
  if kubectl get deployment openclaw-provisioning -n openclaw-provisioning &>/dev/null; then
    kubectl delete deployment openclaw-provisioning -n openclaw-provisioning 2>/dev/null || true
    DELETED+=("deployment/openclaw-provisioning")
    echo "  Deleted deployment openclaw-provisioning"
  else
    SKIPPED+=("deployment/openclaw-provisioning (not found)")
  fi

  # HPA
  if kubectl get hpa openclaw-provisioning -n openclaw-provisioning &>/dev/null; then
    kubectl delete hpa openclaw-provisioning -n openclaw-provisioning 2>/dev/null || true
    DELETED+=("hpa/openclaw-provisioning")
    echo "  Deleted HPA openclaw-provisioning"
  else
    SKIPPED+=("hpa/openclaw-provisioning (not found)")
  fi

  # StatefulSet (postgres)
  if kubectl get statefulset postgres -n openclaw-provisioning &>/dev/null; then
    kubectl delete statefulset postgres -n openclaw-provisioning 2>/dev/null || true
    DELETED+=("statefulset/postgres")
    echo "  Deleted statefulset postgres"
  else
    SKIPPED+=("statefulset/postgres (not found)")
  fi

  # Services
  for SVC in openclaw-provisioning postgres; do
    if kubectl get service "$SVC" -n openclaw-provisioning &>/dev/null; then
      kubectl delete service "$SVC" -n openclaw-provisioning 2>/dev/null || true
      DELETED+=("service/$SVC")
      echo "  Deleted service $SVC"
    else
      SKIPPED+=("service/$SVC (not found)")
    fi
  done

  # Secrets
  for SECRET in openclaw-provisioning-secret postgres-secret; do
    if kubectl get secret "$SECRET" -n openclaw-provisioning &>/dev/null; then
      kubectl delete secret "$SECRET" -n openclaw-provisioning 2>/dev/null || true
      DELETED+=("secret/$SECRET")
      echo "  Deleted secret $SECRET"
    else
      SKIPPED+=("secret/$SECRET (not found)")
    fi
  done

  # PVC (postgres data - DATA LOSS!)
  if kubectl get pvc postgres-data-postgres-0 -n openclaw-provisioning &>/dev/null; then
    kubectl delete pvc postgres-data-postgres-0 -n openclaw-provisioning 2>/dev/null || true
    DELETED+=("pvc/postgres-data-postgres-0 (DATA DELETED)")
    echo -e "  ${YELLOW}Deleted PVC postgres-data-postgres-0 (data lost!)${NC}"
  else
    SKIPPED+=("pvc/postgres-data-postgres-0 (not found)")
  fi

  # RBAC (cluster-scoped)
  if kubectl get clusterrolebinding openclaw-provisioner &>/dev/null; then
    kubectl delete clusterrolebinding openclaw-provisioner 2>/dev/null || true
    DELETED+=("clusterrolebinding/openclaw-provisioner")
    echo "  Deleted ClusterRoleBinding openclaw-provisioner"
  else
    SKIPPED+=("clusterrolebinding/openclaw-provisioner (not found)")
  fi

  if kubectl get clusterrole openclaw-provisioner &>/dev/null; then
    kubectl delete clusterrole openclaw-provisioner 2>/dev/null || true
    DELETED+=("clusterrole/openclaw-provisioner")
    echo "  Deleted ClusterRole openclaw-provisioner"
  else
    SKIPPED+=("clusterrole/openclaw-provisioner (not found)")
  fi
else
  echo "  Namespace openclaw-provisioning not found, skipping K8s resources"
  SKIPPED+=("all openclaw-provisioning resources (namespace not found)")
fi

echo ""

# ============================================================================
# Step 5: CloudFront Distribution
# ============================================================================

echo -e "${CYAN}[Step 5/10] Deleting CloudFront distribution...${NC}"

CLOUDFRONT_DIST_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='OpenClaw-${CLUSTER_NAME}'].Id" \
  --output text 2>/dev/null || echo "")

if [ -n "$CLOUDFRONT_DIST_ID" ] && [ "$CLOUDFRONT_DIST_ID" != "None" ]; then
  echo "  Found distribution: $CLOUDFRONT_DIST_ID"

  # Get current config
  aws cloudfront get-distribution-config --id "$CLOUDFRONT_DIST_ID" > /tmp/cf-cleanup.json
  ETAG=$(jq -r '.ETag' /tmp/cf-cleanup.json)
  IS_ENABLED=$(jq -r '.DistributionConfig.Enabled' /tmp/cf-cleanup.json)

  if [ "$IS_ENABLED" == "true" ]; then
    echo "  Disabling distribution (this takes 5-10 minutes)..."
    jq '.DistributionConfig.Enabled = false | .DistributionConfig' /tmp/cf-cleanup.json > /tmp/cf-disabled.json

    aws cloudfront update-distribution \
      --id "$CLOUDFRONT_DIST_ID" \
      --if-match "$ETAG" \
      --distribution-config file:///tmp/cf-disabled.json > /dev/null

    echo "  Waiting for distribution to be disabled..."
    aws cloudfront wait distribution-deployed --id "$CLOUDFRONT_DIST_ID"

    # Get new ETag after disable
    aws cloudfront get-distribution-config --id "$CLOUDFRONT_DIST_ID" > /tmp/cf-cleanup-new.json
    ETAG=$(jq -r '.ETag' /tmp/cf-cleanup-new.json)
  else
    echo "  Distribution already disabled"
  fi

  echo "  Deleting distribution..."
  aws cloudfront delete-distribution --id "$CLOUDFRONT_DIST_ID" --if-match "$ETAG"
  DELETED+=("cloudfront/$CLOUDFRONT_DIST_ID")
  echo -e "  ${GREEN}Deleted CloudFront distribution${NC}"
else
  echo "  No CloudFront distribution found for OpenClaw-${CLUSTER_NAME}"
  SKIPPED+=("cloudfront distribution (not found)")
fi

echo ""

# ============================================================================
# Step 6: Security Groups
# ============================================================================

echo -e "${CYAN}[Step 6/10] Cleaning up security groups...${NC}"

VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text 2>/dev/null || echo "")

CLOUDFRONT_SG_NAME="openclaw-alb-cloudfront-only"
CLOUDFRONT_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$CLOUDFRONT_SG_NAME" \
  --region "$AWS_REGION" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

if [ -n "$CLOUDFRONT_SG_ID" ] && [ "$CLOUDFRONT_SG_ID" != "None" ]; then
  # Remove SG rules from cluster SG that reference the CloudFront SG
  CLUSTER_SG=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
    --output text 2>/dev/null || echo "")

  if [ -n "$CLUSTER_SG" ] && [ "$CLUSTER_SG" != "None" ]; then
    echo "  Removing CloudFront SG rules from cluster SG ($CLUSTER_SG)..."

    # Get ingress rules that reference the CloudFront SG
    RULES_JSON=$(aws ec2 describe-security-groups \
      --group-ids "$CLUSTER_SG" \
      --region "$AWS_REGION" \
      --query "SecurityGroups[0].IpPermissions[?UserIdGroupPairs[?GroupId=='$CLOUDFRONT_SG_ID']]" \
      --output json 2>/dev/null || echo "[]")

    if [ "$RULES_JSON" != "[]" ] && [ -n "$RULES_JSON" ]; then
      echo "$RULES_JSON" > /tmp/sg-rules-to-remove.json
      aws ec2 revoke-security-group-ingress \
        --group-id "$CLUSTER_SG" \
        --ip-permissions file:///tmp/sg-rules-to-remove.json \
        --region "$AWS_REGION" 2>/dev/null || echo "  (rules already removed)"
      echo "  Removed CloudFront SG rules from cluster SG"
    else
      echo "  No CloudFront SG rules found in cluster SG"
    fi
  fi

  # Delete the CloudFront SG itself
  echo "  Deleting security group: $CLOUDFRONT_SG_ID ($CLOUDFRONT_SG_NAME)"
  # Retry a few times - ALB may still be cleaning up
  for i in 1 2 3; do
    if aws ec2 delete-security-group --group-id "$CLOUDFRONT_SG_ID" --region "$AWS_REGION" 2>/dev/null; then
      DELETED+=("security-group/$CLOUDFRONT_SG_ID")
      echo -e "  ${GREEN}Deleted security group${NC}"
      break
    else
      if [ "$i" -lt 3 ]; then
        echo "  SG still in use (ALB cleanup may be in progress), retrying in 15s..."
        sleep 15
      else
        echo -e "  ${YELLOW}Failed to delete SG after retries. Delete manually: aws ec2 delete-security-group --group-id $CLOUDFRONT_SG_ID --region $AWS_REGION${NC}"
        SKIPPED+=("security-group/$CLOUDFRONT_SG_ID (still in use)")
      fi
    fi
  done
else
  echo "  CloudFront security group not found"
  SKIPPED+=("security-group/openclaw-alb-cloudfront-only (not found)")
fi

echo ""

# ============================================================================
# Step 7: Pod Identity Associations
# ============================================================================

echo -e "${CYAN}[Step 7/10] Deleting Pod Identity associations...${NC}"

# Delete openclaw-provisioning/openclaw-provisioner association
PROV_ASSOC=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace openclaw-provisioning \
  --service-account openclaw-provisioner \
  --query 'associations[0].associationId' \
  --output text 2>/dev/null || echo "")

if [ -n "$PROV_ASSOC" ] && [ "$PROV_ASSOC" != "None" ]; then
  aws eks delete-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" \
    --association-id "$PROV_ASSOC" \
    --region "$AWS_REGION" 2>/dev/null || true
  DELETED+=("pod-identity/openclaw-provisioning:openclaw-provisioner ($PROV_ASSOC)")
  echo "  Deleted provisioning service association: $PROV_ASSOC"
else
  echo "  Provisioning service association not found"
  SKIPPED+=("pod-identity/openclaw-provisioning:openclaw-provisioner (not found)")
fi

# Delete openclaw/openclaw-bedrock-access association
BEDROCK_ASSOC=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace openclaw \
  --service-account openclaw-bedrock-access \
  --query 'associations[0].associationId' \
  --output text 2>/dev/null || echo "")

if [ -n "$BEDROCK_ASSOC" ] && [ "$BEDROCK_ASSOC" != "None" ]; then
  aws eks delete-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" \
    --association-id "$BEDROCK_ASSOC" \
    --region "$AWS_REGION" 2>/dev/null || true
  DELETED+=("pod-identity/openclaw:openclaw-bedrock-access ($BEDROCK_ASSOC)")
  echo "  Deleted bedrock access association: $BEDROCK_ASSOC"
else
  echo "  Bedrock access association not found"
  SKIPPED+=("pod-identity/openclaw:openclaw-bedrock-access (not found)")
fi

echo ""

# ============================================================================
# Step 8: IAM Resources
# ============================================================================

echo -e "${CYAN}[Step 8/10] Deleting IAM resources...${NC}"

# --- Bedrock Role + Policy ---
BEDROCK_ROLE_NAME="OpenClawBedrockRole"
BEDROCK_POLICY_NAME="OpenClawBedrockAccess"
BEDROCK_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT}:policy/${BEDROCK_POLICY_NAME}"

if aws iam get-role --role-name "$BEDROCK_ROLE_NAME" &>/dev/null; then
  echo "  Detaching policies from $BEDROCK_ROLE_NAME..."
  ATTACHED=$(aws iam list-attached-role-policies \
    --role-name "$BEDROCK_ROLE_NAME" \
    --query 'AttachedPolicies[].PolicyArn' \
    --output text 2>/dev/null || echo "")
  for P in $ATTACHED; do
    aws iam detach-role-policy --role-name "$BEDROCK_ROLE_NAME" --policy-arn "$P" 2>/dev/null || true
  done

  aws iam delete-role --role-name "$BEDROCK_ROLE_NAME" 2>/dev/null || true
  DELETED+=("iam-role/$BEDROCK_ROLE_NAME")
  echo "  Deleted role $BEDROCK_ROLE_NAME"
else
  echo "  Role $BEDROCK_ROLE_NAME not found"
  SKIPPED+=("iam-role/$BEDROCK_ROLE_NAME (not found)")
fi

if aws iam get-policy --policy-arn "$BEDROCK_POLICY_ARN" &>/dev/null; then
  # Delete all non-default policy versions first
  NON_DEFAULT_VERSIONS=$(aws iam list-policy-versions \
    --policy-arn "$BEDROCK_POLICY_ARN" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' \
    --output text 2>/dev/null || echo "")
  for V in $NON_DEFAULT_VERSIONS; do
    aws iam delete-policy-version --policy-arn "$BEDROCK_POLICY_ARN" --version-id "$V" 2>/dev/null || true
  done

  aws iam delete-policy --policy-arn "$BEDROCK_POLICY_ARN" 2>/dev/null || true
  DELETED+=("iam-policy/$BEDROCK_POLICY_NAME")
  echo "  Deleted policy $BEDROCK_POLICY_NAME"
else
  echo "  Policy $BEDROCK_POLICY_NAME not found"
  SKIPPED+=("iam-policy/$BEDROCK_POLICY_NAME (not found)")
fi

# --- Provisioning Service Role + Policy ---
PROV_ROLE_NAME="openclaw-provisioning-service"
PROV_POLICY_NAME="OpenClawProvisioningServicePolicy"
PROV_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT}:policy/${PROV_POLICY_NAME}"

if aws iam get-role --role-name "$PROV_ROLE_NAME" &>/dev/null; then
  echo "  Detaching policies from $PROV_ROLE_NAME..."
  ATTACHED=$(aws iam list-attached-role-policies \
    --role-name "$PROV_ROLE_NAME" \
    --query 'AttachedPolicies[].PolicyArn' \
    --output text 2>/dev/null || echo "")
  for P in $ATTACHED; do
    aws iam detach-role-policy --role-name "$PROV_ROLE_NAME" --policy-arn "$P" 2>/dev/null || true
  done

  aws iam delete-role --role-name "$PROV_ROLE_NAME" 2>/dev/null || true
  DELETED+=("iam-role/$PROV_ROLE_NAME")
  echo "  Deleted role $PROV_ROLE_NAME"
else
  echo "  Role $PROV_ROLE_NAME not found"
  SKIPPED+=("iam-role/$PROV_ROLE_NAME (not found)")
fi

if aws iam get-policy --policy-arn "$PROV_POLICY_ARN" &>/dev/null; then
  NON_DEFAULT_VERSIONS=$(aws iam list-policy-versions \
    --policy-arn "$PROV_POLICY_ARN" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' \
    --output text 2>/dev/null || echo "")
  for V in $NON_DEFAULT_VERSIONS; do
    aws iam delete-policy-version --policy-arn "$PROV_POLICY_ARN" --version-id "$V" 2>/dev/null || true
  done

  aws iam delete-policy --policy-arn "$PROV_POLICY_ARN" 2>/dev/null || true
  DELETED+=("iam-policy/$PROV_POLICY_NAME")
  echo "  Deleted policy $PROV_POLICY_NAME"
else
  echo "  Policy $PROV_POLICY_NAME not found"
  SKIPPED+=("iam-policy/$PROV_POLICY_NAME (not found)")
fi

echo ""

# ============================================================================
# Step 9: Delete openclaw-provisioning namespace (catches leftovers)
# ============================================================================

echo -e "${CYAN}[Step 9/10] Deleting openclaw-provisioning namespace...${NC}"

if kubectl get namespace openclaw-provisioning &>/dev/null; then
  kubectl delete namespace openclaw-provisioning --timeout=120s 2>/dev/null || {
    echo -e "  ${YELLOW}Namespace deletion timed out, force-deleting...${NC}"
    kubectl delete namespace openclaw-provisioning --force --grace-period=0 2>/dev/null || true
  }
  DELETED+=("namespace/openclaw-provisioning")
  echo "  Deleted namespace openclaw-provisioning"
else
  echo "  Namespace already gone"
  SKIPPED+=("namespace/openclaw-provisioning (already gone)")
fi

echo ""

# ============================================================================
# Step 10: Summary
# ============================================================================

echo -e "${GREEN}=== Application Stack Cleanup Complete ===${NC}"
echo ""

if [ ${#DELETED[@]} -gt 0 ]; then
  echo -e "${GREEN}Deleted (${#DELETED[@]}):${NC}"
  for item in "${DELETED[@]}"; do
    echo "  - $item"
  done
  echo ""
fi

if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo -e "${YELLOW}Already gone / skipped (${#SKIPPED[@]}):${NC}"
  for item in "${SKIPPED[@]}"; do
    echo "  - $item"
  done
  echo ""
fi

echo "Verification commands:"
echo "  kubectl get all,ingress -n openclaw-provisioning"
echo "  aws iam get-role --role-name OpenClawBedrockRole 2>&1 | head -1"
echo "  aws cloudfront list-distributions --query \"DistributionList.Items[?Comment=='OpenClaw-${CLUSTER_NAME}'].Id\" --output text"
echo "  aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME --region $AWS_REGION --namespace openclaw-provisioning --query 'associations[].associationId' --output text"
echo "  aws ec2 describe-security-groups --filters 'Name=group-name,Values=openclaw-alb-cloudfront-only' --region $AWS_REGION --query 'SecurityGroups[].GroupId' --output text"
echo ""
echo -e "${GREEN}You can now re-run 05-deploy-application-stack-db.sh for a clean deployment.${NC}"
