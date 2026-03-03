# WebSocket Setup - API Gateway Configuration

## Overview

This document describes how to configure API Gateway to support WebSocket connections for OpenClaw instances.

**Key feature:** AWS HTTP API (API Gateway v2) natively supports WebSocket protocol upgrades! 🎉

**Architecture:**
```
User Browser (WebSocket)
    ↓
API Gateway HTTP API (WebSocket upgrade)
    ↓
VPC Link
    ↓
Shared Instances ALB (openclaw-shared-instances)
    ↓
User Instance Ingress (/instance/{user_id}/*)
    ↓
OpenClaw Instance Service
    ↓
OpenClaw Pod (WebSocket handler)
```

**Why direct to ALB?**
- ALB natively supports WebSocket protocol upgrade (HTTP → WebSocket)
- Bypasses Python Provisioning Service (requests library doesn't support WebSocket)
- Same ALB handles both HTTP and WebSocket traffic

---

## Prerequisites

1. **Provisioning Service deployed** with keeper ingress auto-creation
   - Keeper ingress: `openclaw-instances-keeper`
   - Creates shared ALB: `k8s-openclawsharedins-*`

2. **API Gateway HTTP API** configured
   - API ID: `0qu1ls4sf5` (or your API ID)
   - VPC Link: `kn1heg` (or your VPC Link ID)

3. **kubectl access** to EKS cluster

---

## Quick Setup (Automated Script)

Run the provided automation script:

```bash
cd eks-pod-service/scripts
./setup-websocket-routing.sh
```

The script will:
1. ✅ Get shared ALB listener ARN from keeper ingress
2. ✅ Create WebSocket integration (or reuse existing)
3. ✅ Update `/instance/{user_id}/{proxy+}` route
4. ✅ Verify configuration

**Environment variables** (optional):
```bash
export API_GATEWAY_API_ID="0qu1ls4sf5"
export VPC_LINK_ID="kn1heg"
export AWS_REGION="us-west-2"
```

---

## Manual Setup (Step-by-Step)

### Step 1: Get Shared ALB Listener ARN

```bash
# Get keeper ingress ALB DNS
SHARED_ALB_DNS=$(kubectl get ingress openclaw-instances-keeper \
  -n openclaw-provisioning \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "Shared ALB DNS: $SHARED_ALB_DNS"

# Get ALB ARN
SHARED_ALB_ARN=$(aws elbv2 describe-load-balancers \
  --region us-west-2 \
  --query "LoadBalancers[?DNSName=='$SHARED_ALB_DNS'].LoadBalancerArn" \
  --output text)

echo "Shared ALB ARN: $SHARED_ALB_ARN"

# Get listener ARN (port 80)
SHARED_LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$SHARED_ALB_ARN" \
  --region us-west-2 \
  --query 'Listeners[?Port==`80`].ListenerArn' \
  --output text)

echo "Shared Listener ARN: $SHARED_LISTENER_ARN"
```

**Expected output example:**
```
Shared ALB DNS: internal-k8s-openclawsharedins-1304d94a5a-588233483.us-west-2.elb.amazonaws.com
Shared ALB ARN: arn:aws:elasticloadbalancing:us-west-2:970547376847:loadbalancer/app/k8s-openclawsharedins-1304d94a5a/7499ae8bdb6efc4f
Shared Listener ARN: arn:aws:elasticloadbalancing:us-west-2:970547376847:listener/app/k8s-openclawsharedins-1304d94a5a/7499ae8bdb6efc4f/48382bb1cbc7bfe8
```

---

### Step 2: Create WebSocket Integration

```bash
# Create integration pointing to shared ALB
# IMPORTANT: Include request-parameters to strip stage prefix (/prod)
WS_INTEGRATION=$(aws apigatewayv2 create-integration \
  --api-id 0qu1ls4sf5 \
  --integration-type HTTP_PROXY \
  --integration-uri "$SHARED_LISTENER_ARN" \
  --connection-type VPC_LINK \
  --connection-id kn1heg \
  --integration-method ANY \
  --payload-format-version "1.0" \
  --request-parameters '{"overwrite:path":"$request.path"}' \
  --region us-west-2 \
  --output json)

WS_INTEGRATION_ID=$(echo "$WS_INTEGRATION" | jq -r '.IntegrationId')

echo "WebSocket Integration ID: $WS_INTEGRATION_ID"
```

**⚠️ Critical**: The `--request-parameters '{"overwrite:path":"$request.path"}'` parameter is **required** to ensure proper path routing. Without it, API Gateway forwards paths with the stage prefix (e.g., `/prod/instance/416e0b5f`), but ALB ingress rules expect paths without the prefix (e.g., `/instance/416e0b5f`), causing 404 errors.

**Verify integration:**
```bash
aws apigatewayv2 get-integration \
  --api-id 0qu1ls4sf5 \
  --integration-id "$WS_INTEGRATION_ID" \
  --region us-west-2 \
  --output json | jq '{IntegrationId, IntegrationType, IntegrationUri, ConnectionType, ConnectionId}'
```

**Expected output:**
```json
{
  "IntegrationId": "p5a92ng",
  "IntegrationType": "HTTP_PROXY",
  "IntegrationUri": "arn:aws:elasticloadbalancing:us-west-2:970547376847:listener/app/k8s-openclawsharedins-1304d94a5a/7499ae8bdb6efc4f/48382bb1cbc7bfe8",
  "ConnectionType": "VPC_LINK",
  "ConnectionId": "kn1heg"
}
```

---

### Step 3: Update Instance Route

Find the current instance route:
```bash
aws apigatewayv2 get-routes \
  --api-id 0qu1ls4sf5 \
  --region us-west-2 \
  --query 'Items[?RouteKey==`ANY /instance/{user_id}/{proxy+}`]' \
  --output json | jq '.[0] | {RouteKey, RouteId, Target}'
```

Update route to use WebSocket integration:
```bash
ROUTE_ID="<route-id-from-above>"

aws apigatewayv2 update-route \
  --api-id 0qu1ls4sf5 \
  --route-id "$ROUTE_ID" \
  --target "integrations/$WS_INTEGRATION_ID" \
  --region us-west-2

echo "✅ Route updated to use shared ALB"
```

---

### Step 4: Verify Configuration

```bash
# Verify route update
aws apigatewayv2 get-route \
  --api-id 0qu1ls4sf5 \
  --route-id "$ROUTE_ID" \
  --region us-west-2 \
  --output json | jq '{RouteKey, Target}'
```

**Expected output:**
```json
{
  "RouteKey": "ANY /instance/{user_id}/{proxy+}",
  "Target": "integrations/p5a92ng"
}
```

---

## Testing WebSocket Connection

### 1. Create OpenClaw Instance

```bash
# Via dashboard or API
curl -X POST https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/provision \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json"
```

### 2. Get Gateway Token

```bash
USER_ID="<your-user-id>"

GATEWAY_TOKEN=$(kubectl get secret openclaw-${USER_ID}-gateway-token \
  -n openclaw-${USER_ID} \
  -o jsonpath='{.data.token}' | base64 -d)

echo "Gateway Token: $GATEWAY_TOKEN"
```

### 3. Test WebSocket Connection

**From browser console:**
```javascript
const userId = "416e0b5f";  // Your user ID
const token = "your-gateway-token";
const wsUrl = `wss://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/instance/${userId}/?token=${token}`;

const ws = new WebSocket(wsUrl);

ws.onopen = () => console.log("✅ WebSocket connected");
ws.onclose = (event) => console.log("❌ WebSocket closed", event.code, event.reason);
ws.onerror = (error) => console.error("❌ WebSocket error", error);
ws.onmessage = (msg) => console.log("📨 Message:", msg.data);
```

**Expected result:**
- `✅ WebSocket connected`
- OpenClaw dashboard shows status: **online** (green)

---

## Troubleshooting

### Issue: WebSocket connection fails with 403/404

**Cause:** User instance ingress not created or using wrong group name

**Solution:**
1. Check if user instance ingress exists:
   ```bash
   kubectl get ingress -n openclaw-${USER_ID}
   ```

2. Verify ingress uses correct group name:
   ```bash
   kubectl get ingress openclaw-${USER_ID} -n openclaw-${USER_ID} \
     -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/group\.name}'
   ```
   Should output: `openclaw-shared-instances`

3. If wrong, delete and recreate instance:
   ```bash
   kubectl delete openclawinstance openclaw-${USER_ID} -n openclaw-${USER_ID}
   # Provision again via dashboard
   ```

---

### Issue: WebSocket connects but immediately closes (1006)

**Cause:** OpenClaw instance not ready or gateway token invalid

**Solution:**
1. Check OpenClaw pod status:
   ```bash
   kubectl get pod -n openclaw-${USER_ID}
   ```

2. Check OpenClaw logs:
   ```bash
   kubectl logs -n openclaw-${USER_ID} openclaw-${USER_ID}-0 -c openclaw --tail=50
   ```

3. Verify gateway token:
   ```bash
   kubectl get secret openclaw-${USER_ID}-gateway-token \
     -n openclaw-${USER_ID} \
     -o jsonpath='{.data.token}' | base64 -d
   ```

---

### Issue: Integration returns 502 Bad Gateway

**Cause:** ALB cannot reach OpenClaw service

**Solution:**
1. Check ALB target health:
   ```bash
   # Get ALB ARN
   ALB_ARN=$(aws elbv2 describe-load-balancers \
     --region us-west-2 \
     --query "LoadBalancers[?contains(DNSName, 'openclawsharedins')].LoadBalancerArn" \
     --output text)

   # Get target groups
   aws elbv2 describe-target-groups \
     --load-balancer-arn "$ALB_ARN" \
     --region us-west-2 \
     --query 'TargetGroups[].{Name:TargetGroupName,ARN:TargetGroupArn}'

   # Check target health
   aws elbv2 describe-target-health \
     --target-group-arn <target-group-arn> \
     --region us-west-2
   ```

2. Check ingress controller logs:
   ```bash
   kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=100
   ```

3. Verify NetworkPolicy allows traffic:
   ```bash
   kubectl get networkpolicy -n openclaw-${USER_ID}
   ```

---

### Issue: API Gateway returns 404 even though ALB is healthy

**Cause:** Path mismatch between API Gateway and ALB Ingress rules

**Details:**
- API Gateway forwards requests with stage prefix: `/prod/instance/416e0b5f/`
- ALB Ingress rules expect paths without stage: `/instance/416e0b5f/`
- Result: ALB returns 404 (no matching rule)

**Solution:**
Add `request-parameters` to the integration to handle path rewriting:

```bash
aws apigatewayv2 update-integration \
  --api-id 0qu1ls4sf5 \
  --integration-id "$WS_INTEGRATION_ID" \
  --request-parameters '{"overwrite:path":"$request.path"}' \
  --region us-west-2
```

**Verification:**
```bash
# Before fix: 404
curl -i "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/instance/416e0b5f/?token=..."
# HTTP/2 404

# After fix: 200
curl -i "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/instance/416e0b5f/?token=..."
# HTTP/2 200
```

**Alternative solutions:**
1. **Update Ingress paths** (not recommended):
   ```yaml
   # Change path to include stage prefix
   path: /prod/instance/416e0b5f  # Instead of /instance/416e0b5f
   ```
   Problem: Requires updating all user ingress resources

2. **Use Provisioning Service as proxy** (not recommended):
   - Adds latency and complexity
   - Python `requests` library doesn't support WebSocket

---

## Architecture Benefits

### Why Direct to ALB?

**Before (Python Proxy):**
```
API Gateway → Provisioning ALB → Python Proxy → K8s Service → OpenClaw
                                    ↑
                            WebSocket NOT supported
```

**After (Direct ALB):**
```
API Gateway → Shared Instances ALB → Ingress Rule → K8s Service → OpenClaw
                ↑
        WebSocket supported!
```

### Key Advantages

1. **Native WebSocket Support**
   - ALB handles HTTP → WebSocket upgrade automatically
   - No custom proxy code needed

2. **Single ALB for All Users**
   - Cost-efficient: ~$16/month for unlimited users
   - Keeper ingress prevents deletion

3. **Dynamic Routing**
   - Each user's ingress adds ALB listener rule
   - Path-based routing: `/instance/{user_id}/*`

4. **No Per-User Configuration**
   - One-time API Gateway setup
   - New users work automatically

---

## Related Documentation

- [API Gateway Setup](./API-GATEWAY-SETUP.md) - HTTP API configuration
- [Provisioning Service Architecture](../README.md) - Overall system design
- [Keeper Ingress Implementation](../app/k8s/ingress.py) - Auto-management code

---

**Last updated:** 2026-03-03
**Maintainer:** OpenClaw Team
