#!/bin/bash
# Fully automated test script for API Gateway + Internal ALB
# Runs on local machine, but controls remote Graviton machine via SSH

set -e

# Configuration
REMOTE_HOST="44.252.48.166"
REMOTE_USER="ec2-user"
SSH_KEY="/Users/pingxiao/.ssh/pingec2.key"
REMOTE_REPO="/home/ec2-user/openclaw-on-eks-graviton"
ECR_REPO="970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning"
API_ID="0qu1ls4sf5"
VPC_LINK_ID="kn1heg"
REGION="us-west-2"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

function print_header() {
    echo ""
    echo -e "${BLUE}==================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}==================================${NC}"
    echo ""
}

function print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

function print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

function print_error() {
    echo -e "${RED}❌ $1${NC}"
}

function run_remote() {
    local cmd="$1"
    local desc="$2"
    echo -e "${BLUE}[Remote] $desc${NC}"
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" "$cmd"
}

function run_local() {
    local cmd="$1"
    local desc="$2"
    echo -e "${BLUE}[Local] $desc${NC}"
    eval "$cmd"
}

# ========================================
# Stage 0: Prerequisites Check
# ========================================
print_header "Stage 0: Prerequisites Check"

echo "Checking local tools..."
for tool in kubectl aws jq; do
    if command -v $tool &> /dev/null; then
        print_success "$tool installed"
    else
        print_error "$tool not installed"
        exit 1
    fi
done

echo ""
echo "Checking Kubernetes cluster connection..."
if kubectl cluster-info &> /dev/null; then
    CLUSTER=$(kubectl config current-context)
    print_success "Connected to cluster: $CLUSTER"
else
    print_error "Cannot connect to Kubernetes cluster"
    exit 1
fi

echo ""
echo "Checking remote host connectivity..."
if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$REMOTE_USER@$REMOTE_HOST" "echo 'SSH OK'" &> /dev/null; then
    print_success "Remote host reachable: $REMOTE_HOST"
else
    print_error "Cannot connect to remote host"
    exit 1
fi

echo ""
echo "Checking AWS Load Balancer Controller..."
if kubectl get deployment -n kube-system aws-load-balancer-controller &> /dev/null; then
    print_success "AWS Load Balancer Controller installed"
else
    print_error "AWS Load Balancer Controller not installed"
    exit 1
fi

print_success "All prerequisites passed!"

# ========================================
# Stage 1: Update Remote Code
# ========================================
print_header "Stage 1: Update Remote Code"

run_remote "cd $REMOTE_REPO && git pull" "Pull latest code"
LATEST_COMMIT=$(run_remote "cd $REMOTE_REPO && git log --oneline -1" "Get latest commit")
print_success "Remote code updated: $LATEST_COMMIT"

# ========================================
# Stage 2: Build and Push Image on Remote
# ========================================
print_header "Stage 2: Build and Push Image"

echo "Logging into ECR on remote..."
run_remote "aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_REPO" \
    "ECR login"

echo ""
echo "Building image on remote (this may take 1-2 minutes)..."
run_remote "cd $REMOTE_REPO/eks-pod-service && \
    docker build -t $ECR_REPO:latest . 2>&1 | tail -5" \
    "Build Docker image"

echo ""
echo "Pushing image to ECR..."
PUSH_OUTPUT=$(run_remote "docker push $ECR_REPO:latest 2>&1 | tail -10" "Push image to ECR")
echo "$PUSH_OUTPUT"

DIGEST=$(echo "$PUSH_OUTPUT" | grep -o 'sha256:[a-f0-9]*' | head -1)
if [ -n "$DIGEST" ]; then
    print_success "Image pushed: $DIGEST"
else
    print_warning "Could not extract digest, but push may have succeeded"
fi

# ========================================
# Stage 3: Restart Provisioning Service
# ========================================
print_header "Stage 3: Restart Provisioning Service"

run_local "kubectl rollout restart deployment/openclaw-provisioning -n openclaw-provisioning" \
    "Restart deployment"

echo ""
echo "Waiting for rollout to complete..."
if kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning --timeout=120s; then
    print_success "Provisioning service restarted"
else
    print_error "Rollout failed"
    exit 1
fi

echo ""
run_local "kubectl get pods -n openclaw-provisioning" "Check pods"

# ========================================
# Stage 4: Create Test Instance
# ========================================
print_header "Stage 4: Create Test Instance"

echo "Getting JWT token..."
TOKEN=$(aws cognito-idp initiate-auth \
    --auth-flow USER_PASSWORD_AUTH \
    --client-id 62csdgbfh62kqtekbhjpqhmlta \
    --auth-parameters USERNAME=testuser@example.com,PASSWORD=TestPass123! \
    --region $REGION \
    --query 'AuthenticationResult.IdToken' \
    --output text 2>/dev/null)

if [ -z "$TOKEN" ]; then
    print_error "Failed to get JWT token"
    exit 1
fi
print_success "JWT token obtained"

echo ""
echo "Creating OpenClaw instance..."
RESPONSE=$(curl -s -X POST \
    "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/provision" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{}')

echo "$RESPONSE" | jq .

USER_ID=$(echo "$RESPONSE" | jq -r '.user_id')
if [ -z "$USER_ID" ] || [ "$USER_ID" == "null" ]; then
    print_error "Failed to create instance"
    echo "Response: $RESPONSE"
    exit 1
fi

print_success "Instance created: $USER_ID"

# ========================================
# Stage 5: Wait for Internal ALB
# ========================================
print_header "Stage 5: Wait for Internal ALB Creation"

echo "Namespace: openclaw-$USER_ID"
echo "Waiting for Ingress (may take 2-3 minutes)..."

ALB_DNS=""
for i in {1..60}; do
    echo -n "."
    sleep 3

    ALB_DNS=$(kubectl get ingress openclaw-$USER_ID -n openclaw-$USER_ID \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

    if [ -n "$ALB_DNS" ]; then
        echo ""
        print_success "Internal ALB created!"
        echo "ALB DNS: $ALB_DNS"
        break
    fi

    if [ $i -eq 60 ]; then
        echo ""
        print_error "Timeout: ALB not created"
        echo ""
        echo "Checking Ingress status:"
        kubectl describe ingress openclaw-$USER_ID -n openclaw-$USER_ID | tail -30
        exit 1
    fi
done

echo ""
echo "Ingress annotations:"
kubectl get ingress openclaw-$USER_ID -n openclaw-$USER_ID -o yaml | grep -A 15 "annotations:"

# ========================================
# Stage 6: Configure API Gateway Routes
# ========================================
print_header "Stage 6: Configure API Gateway Routes"

echo "Checking existing OpenClaw routes..."
EXISTING_ROUTE=$(aws apigatewayv2 get-routes --api-id $API_ID --region $REGION \
    --query 'Items[?contains(RouteKey, `instance`)].RouteId' --output text)

if [ -n "$EXISTING_ROUTE" ]; then
    print_warning "Route already exists: $EXISTING_ROUTE"
    echo "Deleting existing route..."
    aws apigatewayv2 delete-route --api-id $API_ID --region $REGION --route-id $EXISTING_ROUTE
    print_success "Old route deleted"
fi

echo ""
echo "Getting ALB ARN..."
ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?DNSName=='$ALB_DNS'].LoadBalancerArn" --output text)
if [ -z "$ALB_ARN" ]; then
    print_error "Failed to get ALB ARN"
    exit 1
fi
echo "ALB ARN: $ALB_ARN"

echo ""
echo "Getting ALB listener ARN..."
LISTENER_ARN=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --region "$REGION" \
    --query "Listeners[0].ListenerArn" \
    --output text)
if [ -z "$LISTENER_ARN" ]; then
    print_error "Failed to get listener ARN"
    exit 1
fi
echo "Listener ARN: $LISTENER_ARN"

echo ""
echo "Creating integration to Internal ALB..."
INTEGRATION_ID=$(aws apigatewayv2 create-integration \
    --api-id "$API_ID" \
    --region "$REGION" \
    --integration-type HTTP_PROXY \
    --integration-method ANY \
    --integration-uri "$LISTENER_ARN" \
    --connection-type VPC_LINK \
    --connection-id "$VPC_LINK_ID" \
    --payload-format-version 1.0 \
    --query 'IntegrationId' \
    --output text)

if [ -z "$INTEGRATION_ID" ]; then
    print_error "Failed to create integration"
    exit 1
fi
print_success "Integration created: $INTEGRATION_ID"

echo ""
echo "Creating route..."
AUTHORIZER_ID=$(aws apigatewayv2 get-authorizers --api-id "$API_ID" --region "$REGION" \
    --query 'Items[0].AuthorizerId' --output text)

ROUTE_ID=$(aws apigatewayv2 create-route \
    --api-id "$API_ID" \
    --region "$REGION" \
    --route-key 'ANY /instance/{user_id}/{proxy+}' \
    --target "integrations/$INTEGRATION_ID" \
    --authorization-type JWT \
    --authorizer-id "$AUTHORIZER_ID" \
    --query 'RouteId' \
    --output text)

if [ -z "$ROUTE_ID" ]; then
    print_error "Failed to create route"
    exit 1
fi
print_success "Route created: $ROUTE_ID"

echo ""
echo "Verifying configuration..."
aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
    --query 'Items[?contains(RouteKey, `instance`)].{RouteKey:RouteKey,Target:Target}' \
    --output table

# ========================================
# Stage 7: Access Tests
# ========================================
print_header "Stage 7: Access Tests"

API_GATEWAY_URL="https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/instance/$USER_ID/"

echo "Test 7.1: curl access test"
echo "URL: $API_GATEWAY_URL"
echo ""

HTTP_STATUS=$(curl -s -o /tmp/response.txt -w "%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    "$API_GATEWAY_URL")

echo "HTTP Status: $HTTP_STATUS"

if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
    print_success "Access successful!"
    echo ""
    echo "Response (first 300 chars):"
    head -c 300 /tmp/response.txt
    echo ""
elif [ "$HTTP_STATUS" -eq 401 ]; then
    print_warning "401 Unauthorized - OpenClaw gateway_token required (expected)"
    echo "This is normal - OpenClaw requires additional gateway_token"
elif [ "$HTTP_STATUS" -eq 502 ]; then
    print_error "502 Bad Gateway - ALB health check may be failing"
    echo ""
    echo "Pod status:"
    kubectl get pods -n openclaw-$USER_ID
    echo ""
    echo "Pod logs:"
    kubectl logs -n openclaw-$USER_ID openclaw-$USER_ID-0 -c openclaw --tail=20
else
    print_error "Access failed: HTTP $HTTP_STATUS"
    echo ""
    echo "Response:"
    cat /tmp/response.txt
fi

echo ""
echo "Test 7.2: status API test"
echo "--------------------------------------"
STATUS_RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/status/$USER_ID")

echo "$STATUS_RESPONSE" | jq '{user_id, status, api_gateway_url, gateway_endpoint}'

API_GW_URL_IN_RESPONSE=$(echo "$STATUS_RESPONSE" | jq -r '.api_gateway_url')
if [ "$API_GW_URL_IN_RESPONSE" == "$API_GATEWAY_URL" ]; then
    print_success "status API returns correct api_gateway_url"
else
    print_warning "api_gateway_url mismatch"
    echo "Expected: $API_GATEWAY_URL"
    echo "Got: $API_GW_URL_IN_RESPONSE"
fi

# ========================================
# Test Summary
# ========================================
print_header "Test Summary"

echo "Instance Information:"
echo "  User ID: $USER_ID"
echo "  Namespace: openclaw-$USER_ID"
echo "  API Gateway URL: $API_GATEWAY_URL"
echo "  Internal ALB DNS: $ALB_DNS"
echo ""

echo "Resource Status:"
echo "  OpenClawInstance:"
INSTANCE_STATUS=$(kubectl get openclawinstance openclaw-$USER_ID -n openclaw-$USER_ID \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "N/A")
echo "    Phase: $INSTANCE_STATUS"

echo ""
echo "  Ingress:"
kubectl get ingress -n openclaw-$USER_ID 2>/dev/null | grep -v "^$" || echo "    N/A"

echo ""
echo "  Pods:"
kubectl get pods -n openclaw-$USER_ID 2>/dev/null | grep -v "^$" || echo "    N/A"

echo ""
echo "API Gateway Routes:"
aws apigatewayv2 get-routes --api-id $API_ID --region $REGION \
    --query 'Items[?contains(RouteKey, `instance`)].RouteKey' \
    --output text

echo ""
echo ""
print_success "Automated test completed!"
echo ""
echo "Next steps:"
echo "  1. Test in browser: https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/dashboard"
echo "  2. Login: testuser@example.com / TestPass123!"
echo "  3. Click 'Connect to Gateway' button"
echo "  4. Get gateway_token: kubectl get secret openclaw-$USER_ID-gateway-token -n openclaw-$USER_ID -o jsonpath='{.data.token}' | base64 -d"
echo ""
echo "Cleanup:"
echo "  kubectl delete openclawinstance openclaw-$USER_ID -n openclaw-$USER_ID"
