#!/bin/bash

# Migration script for existing users to shared IAM role
# WARNING: This will delete existing Pod Identity Associations and recreate them

set -e

AWS_REGION="${AWS_REGION:-us-west-2}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-test-s4}"
SHARED_BEDROCK_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/openclaw-bedrock-shared"

echo "=================================="
echo "Migrate Existing Users to Shared Role"
echo "=================================="
echo "Cluster: $EKS_CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Shared Role: $SHARED_BEDROCK_ROLE_ARN"
echo ""

# Find all openclaw-* namespaces
NAMESPACES=$(kubectl get namespaces -o name | grep "^namespace/openclaw-" | sed 's|namespace/||')

if [ -z "$NAMESPACES" ]; then
    echo "No openclaw-* namespaces found. Nothing to migrate."
    exit 0
fi

echo "Found namespaces to migrate:"
echo "$NAMESPACES"
echo ""

read -p "Proceed with migration? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Migration cancelled."
    exit 0
fi

echo ""
echo "Starting migration..."
echo ""

for NAMESPACE in $NAMESPACES; do
    # Extract user_id from namespace
    USER_ID=$(echo "$NAMESPACE" | sed 's/openclaw-//')
    SERVICE_ACCOUNT="openclaw-${USER_ID}"

    echo "----------------------------------------"
    echo "Migrating: $NAMESPACE"
    echo "  User ID: $USER_ID"
    echo "  Service Account: $SERVICE_ACCOUNT"

    # Step 1: List existing Pod Identity Associations
    echo "  Step 1: Finding existing Pod Identity Associations..."
    ASSOCIATION_IDS=$(aws eks list-pod-identity-associations \
        --cluster-name "$EKS_CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --namespace "$NAMESPACE" \
        --service-account "$SERVICE_ACCOUNT" \
        --query 'associations[].associationId' \
        --output text 2>/dev/null || echo "")

    if [ -z "$ASSOCIATION_IDS" ]; then
        echo "  ⚠️  No existing associations found. Creating new one..."
    else
        echo "  Found associations: $ASSOCIATION_IDS"

        # Step 2: Get old role ARN (for logging)
        for ASSOCIATION_ID in $ASSOCIATION_IDS; do
            OLD_ROLE_ARN=$(aws eks describe-pod-identity-association \
                --cluster-name "$EKS_CLUSTER_NAME" \
                --region "$AWS_REGION" \
                --association-id "$ASSOCIATION_ID" \
                --query 'association.roleArn' \
                --output text 2>/dev/null || echo "unknown")
            echo "  Old Role: $OLD_ROLE_ARN"

            # Step 3: Delete old association
            echo "  Step 2: Deleting old association..."
            aws eks delete-pod-identity-association \
                --cluster-name "$EKS_CLUSTER_NAME" \
                --region "$AWS_REGION" \
                --association-id "$ASSOCIATION_ID" >/dev/null 2>&1 || echo "  Failed to delete"
            echo "  ✅ Deleted association: $ASSOCIATION_ID"

            # Wait for deletion
            sleep 2
        done
    fi

    # Step 4: Create new association with shared role
    echo "  Step 3: Creating new association with shared role..."
    NEW_ASSOCIATION_ID=$(aws eks create-pod-identity-association \
        --cluster-name "$EKS_CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --namespace "$NAMESPACE" \
        --service-account "$SERVICE_ACCOUNT" \
        --role-arn "$SHARED_BEDROCK_ROLE_ARN" \
        --query 'association.associationId' \
        --output text 2>&1 || echo "FAILED")

    if [ "$NEW_ASSOCIATION_ID" = "FAILED" ]; then
        echo "  ❌ Failed to create new association"
    else
        echo "  ✅ Created new association: $NEW_ASSOCIATION_ID"
    fi

    # Step 5: Restart pod to pick up new credentials
    echo "  Step 4: Restarting pod..."
    POD_NAME="openclaw-${USER_ID}-0"
    kubectl delete pod "$POD_NAME" -n "$NAMESPACE" 2>/dev/null || echo "  Pod not found or already deleted"
    echo "  ✅ Pod restart triggered"

    echo ""
done

echo "=================================="
echo "Migration Complete!"
echo "=================================="
echo ""
echo "Verify pods are running:"
echo "  kubectl get pods -A | grep openclaw-"
echo ""
echo "Check Pod Identity Associations:"
echo "  aws eks list-pod-identity-associations --cluster-name $EKS_CLUSTER_NAME --region $AWS_REGION"
echo ""
echo "Optional: Clean up old IAM roles"
echo "  List old roles: aws iam list-roles --query 'Roles[?starts_with(RoleName, \`openclaw-user-\`)].RoleName' --output text"
echo ""
