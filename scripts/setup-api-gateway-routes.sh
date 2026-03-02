#!/bin/bash
set -e

# Setup API Gateway routes for OpenClaw Internal ALB
# This script creates API Gateway integration and routes to forward traffic to Internal ALB

API_ID="0qu1ls4sf5"
VPC_LINK_ID="kn1heg"
REGION="us-west-2"
STAGE="prod"

echo "🔧 Setting up API Gateway routes for OpenClaw instances..."

# Step 1: Get Internal ALB DNS
echo ""
echo "📋 Step 1: Getting Internal ALB DNS..."
ALB_DNS=$(kubectl get ingress -A -l alb.ingress.kubernetes.io/group.name=openclaw-instances \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [ -z "$ALB_DNS" ]; then
  echo "❌ Error: Internal ALB not found!"
  echo ""
  echo "Please create at least one OpenClaw instance first:"
  echo "  1. Visit: https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/dashboard"
  echo "  2. Click 'Create OpenClaw Instance'"
  echo "  3. Wait for ALB to be created (~2-3 minutes)"
  echo "  4. Run this script again"
  exit 1
fi

echo "✅ Internal ALB DNS: $ALB_DNS"

# Step 2: Create Integration to Internal ALB via VPC Link
echo ""
echo "📋 Step 2: Creating API Gateway integration..."

INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --region "$REGION" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --integration-uri "http://$ALB_DNS" \
  --connection-type VPC_LINK \
  --connection-id "$VPC_LINK_ID" \
  --payload-format-version 1.0 \
  --query 'IntegrationId' \
  --output text)

if [ -z "$INTEGRATION_ID" ]; then
  echo "❌ Error: Failed to create integration"
  exit 1
fi

echo "✅ Integration created: $INTEGRATION_ID"

# Step 3: Create Route for OpenClaw instances
echo ""
echo "📋 Step 3: Creating API Gateway route..."

ROUTE_ID=$(aws apigatewayv2 create-route \
  --api-id "$API_ID" \
  --region "$REGION" \
  --route-key 'ANY /instance/{user_id}/{proxy+}' \
  --target "integrations/$INTEGRATION_ID" \
  --authorization-type JWT \
  --authorizer-id $(aws apigatewayv2 get-authorizers --api-id "$API_ID" --region "$REGION" --query 'Items[0].AuthorizerId' --output text) \
  --query 'RouteId' \
  --output text)

if [ -z "$ROUTE_ID" ]; then
  echo "❌ Error: Failed to create route"
  exit 1
fi

echo "✅ Route created: $ROUTE_ID"

# Step 4: Verify configuration
echo ""
echo "📋 Step 4: Verifying configuration..."

aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
  --query 'Items[?contains(RouteKey, `instance`)].{RouteKey:RouteKey,Target:Target}' \
  --output table

echo ""
echo "✅ API Gateway configuration complete!"
echo ""
echo "🎉 OpenClaw instances are now accessible via:"
echo "   https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/instance/{user_id}/"
echo ""
echo "📝 Next steps:"
echo "   1. Test by clicking 'Connect to Gateway' button in dashboard"
echo "   2. Monitor ALB health checks: kubectl describe ingress -A -l alb.ingress.kubernetes.io/group.name=openclaw-instances"
