#!/bin/bash
set -e

# ============================================================================
# API Gateway WebSocket Routing Setup
# ============================================================================
#
# This script configures API Gateway to route WebSocket traffic directly to
# the shared instances ALB, bypassing the Provisioning Service Python proxy.
#
# Prerequisites:
# - Keeper ingress created (auto-created by Provisioning Service)
# - API Gateway HTTP API exists
# - VPC Link configured
#
# Usage:
#   ./setup-websocket-routing.sh
#
# Environment Variables:
#   API_GATEWAY_API_ID    - API Gateway API ID (default: 0qu1ls4sf5)
#   VPC_LINK_ID           - VPC Link ID (default: kn1heg)
#   AWS_REGION            - AWS Region (default: us-west-2)
# ============================================================================

# Configuration
API_ID="${API_GATEWAY_API_ID:-0qu1ls4sf5}"
VPC_LINK_ID="${VPC_LINK_ID:-kn1heg}"
REGION="${AWS_REGION:-us-west-2}"
KEEPER_INGRESS_NAME="openclaw-instances-keeper"
KEEPER_NAMESPACE="openclaw-provisioning"

echo "🚀 API Gateway WebSocket Routing Setup"
echo "========================================"
echo ""
echo "Configuration:"
echo "  API Gateway ID: $API_ID"
echo "  VPC Link ID: $VPC_LINK_ID"
echo "  Region: $REGION"
echo ""

# Step 1: Get shared ALB listener ARN from keeper ingress
echo "📋 Step 1: Getting shared ALB listener ARN..."

SHARED_ALB_DNS=$(kubectl get ingress "$KEEPER_INGRESS_NAME" \
  -n "$KEEPER_NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)

if [ -z "$SHARED_ALB_DNS" ]; then
  echo "❌ Error: Keeper ingress not found or ALB not ready"
  echo "   Make sure Provisioning Service is deployed and running"
  exit 1
fi

echo "   Shared ALB DNS: $SHARED_ALB_DNS"

SHARED_ALB_ARN=$(aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --query "LoadBalancers[?DNSName=='$SHARED_ALB_DNS'].LoadBalancerArn" \
  --output text)

if [ -z "$SHARED_ALB_ARN" ]; then
  echo "❌ Error: Could not find ALB ARN"
  exit 1
fi

echo "   Shared ALB ARN: $SHARED_ALB_ARN"

SHARED_LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$SHARED_ALB_ARN" \
  --region "$REGION" \
  --query 'Listeners[?Port==`80`].ListenerArn' \
  --output text)

if [ -z "$SHARED_LISTENER_ARN" ]; then
  echo "❌ Error: Could not find listener ARN"
  exit 1
fi

echo "   Listener ARN: $SHARED_LISTENER_ARN"
echo ""

# Step 2: Create or find WebSocket integration
echo "🔧 Step 2: Creating WebSocket integration..."

# Check if integration already exists
EXISTING_INTEGRATION=$(aws apigatewayv2 get-integrations \
  --api-id "$API_ID" \
  --region "$REGION" \
  --output json | jq -r ".Items[] | select(.IntegrationUri==\"$SHARED_LISTENER_ARN\") | .IntegrationId")

if [ -n "$EXISTING_INTEGRATION" ]; then
  echo "   ℹ️  Integration already exists: $EXISTING_INTEGRATION"
  WS_INTEGRATION_ID="$EXISTING_INTEGRATION"
else
  # Create new integration
  WS_INTEGRATION=$(aws apigatewayv2 create-integration \
    --api-id "$API_ID" \
    --integration-type HTTP_PROXY \
    --integration-uri "$SHARED_LISTENER_ARN" \
    --connection-type VPC_LINK \
    --connection-id "$VPC_LINK_ID" \
    --integration-method ANY \
    --payload-format-version "1.0" \
    --region "$REGION" \
    --output json)

  WS_INTEGRATION_ID=$(echo "$WS_INTEGRATION" | jq -r '.IntegrationId')
  echo "   ✅ Integration created: $WS_INTEGRATION_ID"
fi

echo ""

# Step 3: Update instance route to use WebSocket integration
echo "🔀 Step 3: Updating instance route..."

# Find instance route
INSTANCE_ROUTE=$(aws apigatewayv2 get-routes \
  --api-id "$API_ID" \
  --region "$REGION" \
  --query 'Items[?RouteKey==`ANY /instance/{user_id}/{proxy+}`]' \
  --output json)

ROUTE_ID=$(echo "$INSTANCE_ROUTE" | jq -r '.[0].RouteId')
CURRENT_TARGET=$(echo "$INSTANCE_ROUTE" | jq -r '.[0].Target')

if [ -z "$ROUTE_ID" ] || [ "$ROUTE_ID" = "null" ]; then
  echo "❌ Error: Instance route not found"
  exit 1
fi

echo "   Route ID: $ROUTE_ID"
echo "   Current target: $CURRENT_TARGET"
echo "   New target: integrations/$WS_INTEGRATION_ID"

# Update route
aws apigatewayv2 update-route \
  --api-id "$API_ID" \
  --route-id "$ROUTE_ID" \
  --target "integrations/$WS_INTEGRATION_ID" \
  --region "$REGION" \
  --output json > /dev/null

echo "   ✅ Route updated"
echo ""

# Step 4: Verify configuration
echo "🔍 Step 4: Verifying configuration..."

UPDATED_ROUTE=$(aws apigatewayv2 get-route \
  --api-id "$API_ID" \
  --route-id "$ROUTE_ID" \
  --region "$REGION" \
  --output json)

UPDATED_TARGET=$(echo "$UPDATED_ROUTE" | jq -r '.Target')

if [ "$UPDATED_TARGET" = "integrations/$WS_INTEGRATION_ID" ]; then
  echo "   ✅ Configuration verified"
else
  echo "   ❌ Verification failed"
  exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ WebSocket routing configured successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Architecture:"
echo "  Browser → API Gateway (HTTP/WebSocket)"
echo "    ↓"
echo "  VPC Link"
echo "    ↓"
echo "  Shared Instances ALB"
echo "    ↓"
echo "  User Instance Ingress (/instance/{user_id}/*)"
echo "    ↓"
echo "  OpenClaw Instance (native WebSocket support)"
echo ""
echo "Next steps:"
echo "  1. Create a new OpenClaw instance via /provision"
echo "  2. Test WebSocket connection from dashboard"
echo "  3. Verify OpenClaw status shows 'online'"
echo ""
