# API Gateway Setup - One-Time Configuration

## Overview

This document describes the **one-time** API Gateway configuration needed to connect API Gateway to the OpenClaw Provisioning Service reverse proxy.

**Architecture:**
```
User Browser
    ↓
API Gateway (fixed endpoint)
    ↓
VPC Link (fixed)
    ↓
Provisioning Service ALB (fixed, never deleted)
    ↓
Provisioning Service Pods (reverse proxy)
    ↓ (dynamic routing)
OpenClaw Instance Services (per-user)
```

**Key benefit:** After this one-time setup, unlimited users can create OpenClaw instances without any additional API Gateway configuration.

---

## Prerequisites

1. **EKS Cluster** deployed with:
   - AWS Load Balancer Controller installed
   - OpenClaw Provisioning Service deployed in `openclaw-provisioning` namespace

2. **API Gateway HTTP API** created:
   - API ID: `0qu1ls4sf5` (or your API ID)
   - Region: `us-west-2` (or your region)

3. **VPC Link** created:
   - VPC Link ID: `kn1heg` (or your VPC Link ID)
   - Connected to EKS cluster VPC and subnets

4. **Cognito User Pool** configured for JWT authentication (for dashboard access)

---

## Step 1: Get Provisioning Service ALB Listener ARN

```bash
# Get provisioning service ingress ALB DNS name
PROV_ALB_DNS=$(kubectl get ingress openclaw-provisioning-ingress \
  -n openclaw-provisioning \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "Provisioning ALB DNS: $PROV_ALB_DNS"

# Get ALB ARN by DNS name
PROV_ALB_ARN=$(aws elbv2 describe-load-balancers \
  --region us-west-2 \
  --query "LoadBalancers[?DNSName=='$PROV_ALB_DNS'].LoadBalancerArn" \
  --output text)

echo "Provisioning ALB ARN: $PROV_ALB_ARN"

# Get listener ARN (port 80)
PROV_LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$PROV_ALB_ARN" \
  --region us-west-2 \
  --query 'Listeners[?Port==`80`].ListenerArn' \
  --output text)

echo "Provisioning Listener ARN: $PROV_LISTENER_ARN"
```

**Expected output example:**
```
Provisioning ALB DNS: internal-openclaw-provisioning-internal-1460342763.us-west-2.elb.amazonaws.com
Provisioning ALB ARN: arn:aws:elasticloadbalancing:us-west-2:970547376847:loadbalancer/app/k8s-openclawprovisioning-abc123/def456
Provisioning Listener ARN: arn:aws:elasticloadbalancing:us-west-2:970547376847:listener/app/k8s-openclawprovisioning-abc123/def456/ghi789
```

---

## Step 2: Update API Gateway Integration

**Get current integration ID for instance routes:**

```bash
# Find the integration ID for /instance/{user_id}/{proxy+} route
INSTANCE_INTEGRATION_ID=$(aws apigatewayv2 get-routes \
  --api-id 0qu1ls4sf5 \
  --region us-west-2 \
  --query 'Items[?RouteKey==`ANY /instance/{user_id}/{proxy+}`].Target' \
  --output text | sed 's/integrations\///')

echo "Instance Integration ID: $INSTANCE_INTEGRATION_ID"
```

**Update the integration to point to Provisioning ALB:**

```bash
aws apigatewayv2 update-integration \
  --api-id 0qu1ls4sf5 \
  --integration-id "$INSTANCE_INTEGRATION_ID" \
  --integration-uri "$PROV_LISTENER_ARN" \
  --region us-west-2

echo "✅ API Gateway integration updated!"
```

**Verify the update:**

```bash
aws apigatewayv2 get-integration \
  --api-id 0qu1ls4sf5 \
  --integration-id "$INSTANCE_INTEGRATION_ID" \
  --region us-west-2 \
  --output json | jq '{IntegrationType,IntegrationUri,ConnectionType,ConnectionId}'
```

**Expected output:**
```json
{
  "IntegrationType": "HTTP_PROXY",
  "IntegrationUri": "arn:aws:elasticloadbalancing:us-west-2:970547376847:listener/app/k8s-openclawprovisioning-abc123/def456/ghi789",
  "ConnectionType": "VPC_LINK",
  "ConnectionId": "kn1heg"
}
```

---

## Step 3: Verify End-to-End

**Test the proxy endpoint:**

```bash
# Test with a gateway token (get from status API or K8s secret)
USER_ID="416e0b5f"  # Example user ID
GATEWAY_TOKEN="your-gateway-token-here"

curl -i "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/instance/${USER_ID}/?token=${GATEWAY_TOKEN}"
```

**Expected result:**
- HTTP 200 OK
- OpenClaw Gateway response (or login page if token is invalid)

---

## Complete Setup Script

Save this as `setup-api-gateway.sh`:

```bash
#!/bin/bash
set -e

# Configuration
API_ID="${API_GATEWAY_API_ID:-0qu1ls4sf5}"
REGION="${AWS_REGION:-us-west-2}"
NAMESPACE="openclaw-provisioning"
INGRESS_NAME="openclaw-provisioning-ingress"

echo "🚀 API Gateway Setup - One-Time Configuration"
echo "=============================================="
echo ""

# Step 1: Get Provisioning ALB Listener ARN
echo "📋 Step 1: Getting Provisioning Service ALB Listener ARN..."

PROV_ALB_DNS=$(kubectl get ingress "$INGRESS_NAME" \
  -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

if [ -z "$PROV_ALB_DNS" ]; then
  echo "❌ Error: Could not find provisioning ingress ALB DNS"
  exit 1
fi

echo "   ALB DNS: $PROV_ALB_DNS"

PROV_ALB_ARN=$(aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --query "LoadBalancers[?DNSName=='$PROV_ALB_DNS'].LoadBalancerArn" \
  --output text)

if [ -z "$PROV_ALB_ARN" ]; then
  echo "❌ Error: Could not find ALB ARN"
  exit 1
fi

echo "   ALB ARN: $PROV_ALB_ARN"

PROV_LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$PROV_ALB_ARN" \
  --region "$REGION" \
  --query 'Listeners[?Port==`80`].ListenerArn' \
  --output text)

if [ -z "$PROV_LISTENER_ARN" ]; then
  echo "❌ Error: Could not find listener ARN"
  exit 1
fi

echo "   Listener ARN: $PROV_LISTENER_ARN"
echo ""

# Step 2: Update API Gateway Integration
echo "🔧 Step 2: Updating API Gateway integration..."

INSTANCE_INTEGRATION_ID=$(aws apigatewayv2 get-routes \
  --api-id "$API_ID" \
  --region "$REGION" \
  --query 'Items[?RouteKey==`ANY /instance/{user_id}/{proxy+}`].Target' \
  --output text | sed 's/integrations\///')

if [ -z "$INSTANCE_INTEGRATION_ID" ]; then
  echo "❌ Error: Could not find instance integration ID"
  exit 1
fi

echo "   Integration ID: $INSTANCE_INTEGRATION_ID"

aws apigatewayv2 update-integration \
  --api-id "$API_ID" \
  --integration-id "$INSTANCE_INTEGRATION_ID" \
  --integration-uri "$PROV_LISTENER_ARN" \
  --region "$REGION" \
  --output json > /dev/null

echo "   ✅ Integration updated"
echo ""

# Step 3: Verify
echo "🔍 Step 3: Verifying configuration..."

aws apigatewayv2 get-integration \
  --api-id "$API_ID" \
  --integration-id "$INSTANCE_INTEGRATION_ID" \
  --region "$REGION" \
  --output json | jq '{IntegrationType,IntegrationUri,ConnectionType}'

echo ""
echo "✅ API Gateway setup complete!"
echo ""
echo "📝 Summary:"
echo "   - API Gateway now points to Provisioning Service ALB"
echo "   - All user instances will automatically route through reverse proxy"
echo "   - No further configuration needed for new users"
echo ""
echo "🧪 Test with:"
echo "   curl -i https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod/instance/{user_id}/?token={gateway_token}"
```

Make executable:
```bash
chmod +x setup-api-gateway.sh
```

Run:
```bash
./setup-api-gateway.sh
```

---

## Troubleshooting

### Issue: Integration update fails with "ListenerNotFound"

**Cause:** The Provisioning Service ALB or listener doesn't exist.

**Solution:**
1. Check if provisioning service is deployed:
   ```bash
   kubectl get deployment openclaw-provisioning -n openclaw-provisioning
   kubectl get ingress openclaw-provisioning-ingress -n openclaw-provisioning
   ```

2. Wait for ALB to be created (can take 2-3 minutes):
   ```bash
   kubectl get ingress openclaw-provisioning-ingress -n openclaw-provisioning -w
   ```

3. Verify ALB exists in AWS:
   ```bash
   aws elbv2 describe-load-balancers --region us-west-2 | grep openclaw-provisioning
   ```

---

### Issue: API Gateway returns 503 Service Unavailable

**Cause:** VPC Link cannot reach the ALB.

**Solution:**
1. Check VPC Link status:
   ```bash
   aws apigatewayv2 get-vpc-link --vpc-link-id kn1heg --region us-west-2
   ```
   Status should be "AVAILABLE"

2. Verify VPC Link subnets match EKS cluster subnets:
   ```bash
   # Get VPC Link subnets
   aws apigatewayv2 get-vpc-link --vpc-link-id kn1heg --region us-west-2 --query 'SubnetIds'

   # Get EKS cluster subnets
   aws eks describe-cluster --name test-s4 --region us-west-2 --query 'cluster.resourcesVpcConfig.subnetIds'
   ```

3. Check ALB security group allows traffic from VPC Link

---

### Issue: Provisioning Service returns 404 for /instance/{user_id}

**Cause:** Reverse proxy endpoint not deployed.

**Solution:**
1. Check provisioning service logs:
   ```bash
   kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=100
   ```

2. Verify proxy endpoint is registered:
   ```bash
   kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning | grep "proxy"
   ```

3. Redeploy provisioning service:
   ```bash
   kubectl rollout restart deployment openclaw-provisioning -n openclaw-provisioning
   ```

---

## Infrastructure as Code

### Terraform Example

```hcl
# api-gateway-integration.tf

data "kubernetes_ingress_v1" "provisioning" {
  metadata {
    name      = "openclaw-provisioning-ingress"
    namespace = "openclaw-provisioning"
  }
}

data "aws_lb" "provisioning" {
  name = regex("^[^-]+-[^-]+", data.kubernetes_ingress_v1.provisioning.status[0].load_balancer[0].ingress[0].hostname)[0]
}

data "aws_lb_listener" "provisioning" {
  load_balancer_arn = data.aws_lb.provisioning.arn
  port              = 80
}

resource "aws_apigatewayv2_integration" "openclaw_instances" {
  api_id           = aws_apigatewayv2_api.main.id
  integration_type = "HTTP_PROXY"
  integration_uri  = data.aws_lb_listener.provisioning.arn

  connection_type = "VPC_LINK"
  connection_id   = aws_apigatewayv2_vpc_link.main.id

  integration_method = "ANY"
}

resource "aws_apigatewayv2_route" "openclaw_instances" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "ANY /instance/{user_id}/{proxy+}"

  target = "integrations/${aws_apigatewayv2_integration.openclaw_instances.id}"
}
```

### CloudFormation Example

```yaml
# api-gateway-integration.yaml

Resources:
  OpenClawInstancesIntegration:
    Type: AWS::ApiGatewayV2::Integration
    Properties:
      ApiId: !Ref HttpApi
      IntegrationType: HTTP_PROXY
      IntegrationUri: !Sub
        - arn:aws:elasticloadbalancing:${AWS::Region}:${AWS::AccountId}:listener/${ListenerArn}
        - ListenerArn: !GetAtt ProvisioningALBListener.Arn
      ConnectionType: VPC_LINK
      ConnectionId: !Ref VpcLink
      IntegrationMethod: ANY
      PayloadFormatVersion: "1.0"

  OpenClawInstancesRoute:
    Type: AWS::ApiGatewayV2::Route
    Properties:
      ApiId: !Ref HttpApi
      RouteKey: "ANY /instance/{user_id}/{proxy+}"
      Target: !Sub "integrations/${OpenClawInstancesIntegration}"
```

---

## Automation Checklist

When setting up a new environment:

- [ ] Deploy EKS cluster with AWS Load Balancer Controller
- [ ] Deploy OpenClaw Provisioning Service
- [ ] Wait for Provisioning Service ALB to be created (check ingress status)
- [ ] Create API Gateway HTTP API
- [ ] Create VPC Link pointing to EKS VPC subnets
- [ ] Create Cognito User Pool (for dashboard JWT auth)
- [ ] Run `setup-api-gateway.sh` (one-time)
- [ ] Test: create a user, provision instance, access via API Gateway
- [ ] ✅ Done! New users will work automatically

---

## Related Documentation

- [Provisioning Service Architecture](./ARCHITECTURE.md)
- [Reverse Proxy Implementation](../app/api/proxy.py)
- [User Instance Management](./USER-INSTANCES.md)
- [Cognito Authentication Setup](./COGNITO-SETUP.md)

---

**Last updated:** 2026-03-03
**Maintainer:** OpenClaw Team
