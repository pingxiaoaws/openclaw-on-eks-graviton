#!/usr/bin/env bash
#
# OpenClaw Multi-Tenant Platform - Complete Deployment Script
#
# This script automates the complete deployment of:
# 1. Cognito User Pool + Client
# 2. API Gateway HTTP API + VPC Link
# 3. OpenClaw Operator (k8s-operator)
# 4. Provisioning Service (eks-pod-service)
# 5. Keeper Ingress + Shared ALB
# 6. WebSocket routing configuration
#
# Prerequisites:
# - AWS CLI v2 configured with appropriate credentials
# - kubectl configured for target EKS cluster
# - helm installed (for operator deployment)
# - jq installed
# - EKS cluster already created with VPC
#
# Usage:
#   ./scripts/deploy.sh [options]
#
# Options:
#   --region REGION           AWS region (default: us-west-2)
#   --cluster-name NAME       EKS cluster name (default: test-s4)
#   --skip-cognito            Skip Cognito setup (use existing)
#   --skip-api-gateway        Skip API Gateway setup (use existing)
#   --skip-operator           Skip Operator deployment
#   --skip-provisioning       Skip Provisioning Service deployment
#   --skip-websocket          Skip WebSocket routing configuration
#   --dry-run                 Show what would be deployed without executing
#   -h, --help                Show this help message
#

set -euo pipefail

#=============================================================================
# Configuration
#=============================================================================

# Default values
AWS_REGION="${AWS_REGION:-us-west-2}"
CLUSTER_NAME="${CLUSTER_NAME:-test-s4}"
SKIP_COGNITO=false
SKIP_API_GATEWAY=false
SKIP_OPERATOR=false
SKIP_PROVISIONING=false
SKIP_WEBSOCKET=false
DRY_RUN=false

# Namespaces
OPERATOR_NAMESPACE="openclaw-operator-system"
PROVISIONING_NAMESPACE="openclaw-provisioning"

# Image names
ECR_REGISTRY="111122223333.dkr.ecr.${AWS_REGION}.amazonaws.com"
PROVISIONING_IMAGE="${ECR_REGISTRY}/openclaw-provisioning:latest"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#=============================================================================
# Helper Functions
#=============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()

    command -v aws >/dev/null 2>&1 || missing+=("aws-cli")
    command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")
    command -v helm >/dev/null 2>&1 || missing+=("helm")
    command -v jq >/dev/null 2>&1 || missing+=("jq")

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Please install missing tools and try again"
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity --region "$AWS_REGION" >/dev/null 2>&1; then
        log_error "AWS credentials not configured or invalid"
        exit 1
    fi

    # Check kubectl context
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "kubectl not connected to cluster"
        exit 1
    fi

    # Check kubectl context matches cluster name
    local current_context=$(kubectl config current-context)
    if [[ ! "$current_context" =~ "$CLUSTER_NAME" ]]; then
        log_warning "Current kubectl context ($current_context) may not match cluster name ($CLUSTER_NAME)"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    log_success "All prerequisites satisfied"
}

show_help() {
    grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# //' | sed 's/^#//'
    exit 0
}

#=============================================================================
# Phase 1: Cognito User Pool Setup
#=============================================================================

deploy_cognito() {
    log_info "=========================================="
    log_info "Phase 1: Cognito User Pool Setup"
    log_info "=========================================="

    if [ "$SKIP_COGNITO" = true ]; then
        log_warning "Skipping Cognito setup (--skip-cognito)"
        return 0
    fi

    # Check if User Pool already exists
    local user_pool_name="openclaw-users"
    local existing_pool=$(aws cognito-idp list-user-pools \
        --max-results 60 \
        --region "$AWS_REGION" \
        --query "UserPools[?Name=='$user_pool_name'].Id" \
        --output text 2>/dev/null || echo "")

    if [ -n "$existing_pool" ]; then
        log_warning "Cognito User Pool '$user_pool_name' already exists: $existing_pool"
        COGNITO_USER_POOL_ID="$existing_pool"
    else
        log_info "Creating Cognito User Pool '$user_pool_name'..."

        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY-RUN] Would create Cognito User Pool"
        else
            COGNITO_USER_POOL_ID=$(aws cognito-idp create-user-pool \
                --pool-name "$user_pool_name" \
                --policies '{
                    "PasswordPolicy": {
                        "MinimumLength": 8,
                        "RequireUppercase": true,
                        "RequireLowercase": true,
                        "RequireNumbers": true,
                        "RequireSymbols": false
                    }
                }' \
                --auto-verified-attributes email \
                --username-attributes email \
                --mfa-configuration OFF \
                --account-recovery-setting '{
                    "RecoveryMechanisms": [
                        {"Name": "verified_email", "Priority": 1}
                    ]
                }' \
                --region "$AWS_REGION" \
                --query 'UserPool.Id' \
                --output text)

            log_success "Created User Pool: $COGNITO_USER_POOL_ID"
        fi
    fi

    # Create User Pool Client
    local client_name="openclaw-web-client"
    local existing_client=$(aws cognito-idp list-user-pool-clients \
        --user-pool-id "$COGNITO_USER_POOL_ID" \
        --region "$AWS_REGION" \
        --query "UserPoolClients[?ClientName=='$client_name'].ClientId" \
        --output text 2>/dev/null || echo "")

    if [ -n "$existing_client" ]; then
        log_warning "Cognito Client '$client_name' already exists: $existing_client"
        COGNITO_CLIENT_ID="$existing_client"
    else
        log_info "Creating Cognito User Pool Client '$client_name'..."

        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY-RUN] Would create Cognito Client"
        else
            COGNITO_CLIENT_ID=$(aws cognito-idp create-user-pool-client \
                --user-pool-id "$COGNITO_USER_POOL_ID" \
                --client-name "$client_name" \
                --generate-secret false \
                --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
                --prevent-user-existence-errors ENABLED \
                --region "$AWS_REGION" \
                --query 'UserPoolClient.ClientId' \
                --output text)

            log_success "Created Client: $COGNITO_CLIENT_ID"
        fi
    fi

    # Export for next phases
    export COGNITO_USER_POOL_ID
    export COGNITO_CLIENT_ID

    log_info "Cognito configuration:"
    log_info "  Region: $AWS_REGION"
    log_info "  User Pool ID: $COGNITO_USER_POOL_ID"
    log_info "  Client ID: $COGNITO_CLIENT_ID"
}

#=============================================================================
# Phase 2: API Gateway HTTP API Setup
#=============================================================================

deploy_api_gateway() {
    log_info "=========================================="
    log_info "Phase 2: API Gateway HTTP API Setup"
    log_info "=========================================="

    if [ "$SKIP_API_GATEWAY" = true ]; then
        log_warning "Skipping API Gateway setup (--skip-api-gateway)"
        return 0
    fi

    # Get VPC and Subnets from EKS cluster
    log_info "Getting EKS cluster VPC information..."
    local vpc_id=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --query 'cluster.resourcesVpcConfig.vpcId' \
        --output text)

    local subnet_ids=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --query 'cluster.resourcesVpcConfig.subnetIds' \
        --output json)

    log_info "  VPC ID: $vpc_id"
    log_info "  Subnets: $(echo "$subnet_ids" | jq -r '.[]' | tr '\n' ' ')"

    # Create VPC Link
    local vpc_link_name="openclaw-vpclink"
    local existing_vpclink=$(aws apigatewayv2 get-vpc-links \
        --region "$AWS_REGION" \
        --query "Items[?Name=='$vpc_link_name'].VpcLinkId" \
        --output text 2>/dev/null || echo "")

    if [ -n "$existing_vpclink" ]; then
        log_warning "VPC Link '$vpc_link_name' already exists: $existing_vpclink"
        VPC_LINK_ID="$existing_vpclink"
    else
        log_info "Creating VPC Link '$vpc_link_name'..."

        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY-RUN] Would create VPC Link"
        else
            VPC_LINK_ID=$(aws apigatewayv2 create-vpc-link \
                --name "$vpc_link_name" \
                --subnet-ids $(echo "$subnet_ids" | jq -r '.[]' | tr '\n' ' ') \
                --region "$AWS_REGION" \
                --query 'VpcLinkId' \
                --output text)

            log_info "Waiting for VPC Link to become available..."
            aws apigatewayv2 wait vpc-link-available \
                --vpc-link-id "$VPC_LINK_ID" \
                --region "$AWS_REGION"

            log_success "Created VPC Link: $VPC_LINK_ID"
        fi
    fi

    # Create HTTP API
    local api_name="openclaw-provisioning-api"
    local existing_api=$(aws apigatewayv2 get-apis \
        --region "$AWS_REGION" \
        --query "Items[?Name=='$api_name'].ApiId" \
        --output text 2>/dev/null || echo "")

    if [ -n "$existing_api" ]; then
        log_warning "HTTP API '$api_name' already exists: $existing_api"
        API_GATEWAY_ID="$existing_api"
    else
        log_info "Creating HTTP API '$api_name'..."

        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY-RUN] Would create HTTP API"
        else
            API_GATEWAY_ID=$(aws apigatewayv2 create-api \
                --name "$api_name" \
                --protocol-type HTTP \
                --region "$AWS_REGION" \
                --query 'ApiId' \
                --output text)

            log_success "Created HTTP API: $API_GATEWAY_ID"
        fi
    fi

    # Create JWT Authorizer for Cognito
    log_info "Creating JWT Authorizer..."
    local issuer="https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_USER_POOL_ID}"

    if [ "$DRY_RUN" = false ]; then
        AUTHORIZER_ID=$(aws apigatewayv2 create-authorizer \
            --api-id "$API_GATEWAY_ID" \
            --authorizer-type JWT \
            --name "CognitoAuthorizer" \
            --identity-source '$request.header.Authorization' \
            --jwt-configuration "Audience=[\"$COGNITO_CLIENT_ID\"],Issuer=\"$issuer\"" \
            --region "$AWS_REGION" \
            --query 'AuthorizerId' \
            --output text 2>/dev/null || echo "")

        if [ -z "$AUTHORIZER_ID" ]; then
            log_warning "Authorizer might already exist, fetching existing..."
            AUTHORIZER_ID=$(aws apigatewayv2 get-authorizers \
                --api-id "$API_GATEWAY_ID" \
                --region "$AWS_REGION" \
                --query "Items[?Name=='CognitoAuthorizer'].AuthorizerId" \
                --output text)
        fi

        log_success "JWT Authorizer ID: $AUTHORIZER_ID"
    fi

    # Create Stage
    local stage_name="prod"
    if [ "$DRY_RUN" = false ]; then
        aws apigatewayv2 create-stage \
            --api-id "$API_GATEWAY_ID" \
            --stage-name "$stage_name" \
            --auto-deploy \
            --region "$AWS_REGION" \
            >/dev/null 2>&1 || log_warning "Stage '$stage_name' might already exist"

        log_success "Created Stage: $stage_name"
    fi

    # Export for next phases
    export API_GATEWAY_ID
    export VPC_LINK_ID
    export AUTHORIZER_ID

    local api_endpoint=$(aws apigatewayv2 get-api \
        --api-id "$API_GATEWAY_ID" \
        --region "$AWS_REGION" \
        --query 'ApiEndpoint' \
        --output text 2>/dev/null || echo "")

    log_info "API Gateway configuration:"
    log_info "  API ID: $API_GATEWAY_ID"
    log_info "  VPC Link ID: $VPC_LINK_ID"
    log_info "  Authorizer ID: $AUTHORIZER_ID"
    log_info "  Endpoint: ${api_endpoint}/${stage_name}"
}

#=============================================================================
# Phase 3: OpenClaw Operator Deployment
#=============================================================================

deploy_operator() {
    log_info "=========================================="
    log_info "Phase 3: OpenClaw Operator Deployment"
    log_info "=========================================="

    if [ "$SKIP_OPERATOR" = true ]; then
        log_warning "Skipping Operator deployment (--skip-operator)"
        return 0
    fi

    # Check if operator directory exists
    local operator_dir="../k8s-operator"
    if [ ! -d "$operator_dir" ]; then
        log_error "Operator directory not found: $operator_dir"
        exit 1
    fi

    # Check if namespace exists
    if ! kubectl get namespace "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        log_info "Creating namespace '$OPERATOR_NAMESPACE'..."
        if [ "$DRY_RUN" = false ]; then
            kubectl create namespace "$OPERATOR_NAMESPACE"
        fi
    fi

    # Check if operator Helm chart exists
    local operator_chart="${operator_dir}/charts/openclaw-operator"
    if [ ! -d "$operator_chart" ]; then
        log_error "Operator Helm chart not found: $operator_chart"
        exit 1
    fi

    log_info "Deploying OpenClaw Operator via Helm..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would deploy operator via Helm"
    else
        helm upgrade --install openclaw-operator "$operator_chart" \
            --namespace "$OPERATOR_NAMESPACE" \
            --create-namespace \
            --wait \
            --timeout 5m

        log_success "OpenClaw Operator deployed"
    fi

    # Wait for operator to be ready
    if [ "$DRY_RUN" = false ]; then
        log_info "Waiting for operator pod to be ready..."
        kubectl wait --for=condition=ready pod \
            -l app.kubernetes.io/name=openclaw-operator \
            -n "$OPERATOR_NAMESPACE" \
            --timeout=60s

        log_success "Operator is ready"
    fi
}

#=============================================================================
# Phase 4: Provisioning Service Deployment
#=============================================================================

deploy_provisioning_service() {
    log_info "=========================================="
    log_info "Phase 4: Provisioning Service Deployment"
    log_info "=========================================="

    if [ "$SKIP_PROVISIONING" = true ]; then
        log_warning "Skipping Provisioning Service deployment (--skip-provisioning)"
        return 0
    fi

    # Check if namespace exists
    if ! kubectl get namespace "$PROVISIONING_NAMESPACE" >/dev/null 2>&1; then
        log_info "Creating namespace '$PROVISIONING_NAMESPACE'..."
        if [ "$DRY_RUN" = false ]; then
            kubectl create namespace "$PROVISIONING_NAMESPACE"
        fi
    fi

    # Build and push Docker image
    log_info "Building Provisioning Service Docker image..."

    if [ "$DRY_RUN" = false ]; then
        # Login to ECR
        aws ecr get-login-password --region "$AWS_REGION" | \
            docker login --username AWS --password-stdin "$ECR_REGISTRY"

        # Build image
        docker build -t "$PROVISIONING_IMAGE" .

        # Push image
        docker push "$PROVISIONING_IMAGE"

        log_success "Image pushed: $PROVISIONING_IMAGE"
    else
        log_info "[DRY-RUN] Would build and push image: $PROVISIONING_IMAGE"
    fi

    # Create ConfigMap with Cognito configuration
    log_info "Creating Cognito ConfigMap..."

    if [ "$DRY_RUN" = false ]; then
        kubectl create configmap cognito-config \
            --from-literal=COGNITO_REGION="$AWS_REGION" \
            --from-literal=COGNITO_USER_POOL_ID="$COGNITO_USER_POOL_ID" \
            --from-literal=COGNITO_CLIENT_ID="$COGNITO_CLIENT_ID" \
            --namespace="$PROVISIONING_NAMESPACE" \
            --dry-run=client -o yaml | kubectl apply -f -

        log_success "Cognito ConfigMap created"
    fi

    # Apply Kubernetes manifests
    log_info "Applying Kubernetes manifests..."

    local k8s_dir="./kubernetes"
    if [ ! -d "$k8s_dir" ]; then
        log_error "Kubernetes manifests directory not found: $k8s_dir"
        exit 1
    fi

    if [ "$DRY_RUN" = false ]; then
        # Apply in order: RBAC, Deployment, Service, Ingress
        kubectl apply -f "$k8s_dir/rbac.yaml"
        kubectl apply -f "$k8s_dir/deployment.yaml"
        kubectl apply -f "$k8s_dir/service.yaml"
        kubectl apply -f "$k8s_dir/ingress.yaml"

        log_success "Kubernetes manifests applied"
    else
        log_info "[DRY-RUN] Would apply Kubernetes manifests from $k8s_dir"
    fi

    # Wait for deployment to be ready
    if [ "$DRY_RUN" = false ]; then
        log_info "Waiting for deployment to be ready..."
        kubectl rollout status deployment/openclaw-provisioning \
            -n "$PROVISIONING_NAMESPACE" \
            --timeout=5m

        log_success "Provisioning Service is ready"
    fi
}

#=============================================================================
# Phase 5: API Gateway Routes Configuration
#=============================================================================

configure_api_gateway_routes() {
    log_info "=========================================="
    log_info "Phase 5: API Gateway Routes Configuration"
    log_info "=========================================="

    if [ "$SKIP_API_GATEWAY" = true ]; then
        log_warning "Skipping API Gateway routes (--skip-api-gateway)"
        return 0
    fi

    # Get Provisioning Service ALB Listener ARN
    log_info "Getting Provisioning Service ALB Listener ARN..."

    local provisioning_alb_dns=$(kubectl get ingress openclaw-provisioning \
        -n "$PROVISIONING_NAMESPACE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

    if [ -z "$provisioning_alb_dns" ]; then
        log_error "Provisioning Service Ingress not found or not ready"
        log_error "Please wait for ALB to be created and try again"
        return 1
    fi

    log_info "  Provisioning ALB DNS: $provisioning_alb_dns"

    local provisioning_alb_arn=$(aws elbv2 describe-load-balancers \
        --region "$AWS_REGION" \
        --query "LoadBalancers[?DNSName=='$provisioning_alb_dns'].LoadBalancerArn" \
        --output text)

    local provisioning_listener_arn=$(aws elbv2 describe-listeners \
        --load-balancer-arn "$provisioning_alb_arn" \
        --region "$AWS_REGION" \
        --query 'Listeners[?Port==`80`].ListenerArn' \
        --output text)

    log_info "  Provisioning Listener ARN: $provisioning_listener_arn"

    # Create Integration for Provisioning Service
    log_info "Creating Provisioning Service integration..."

    if [ "$DRY_RUN" = false ]; then
        local provisioning_integration_id=$(aws apigatewayv2 create-integration \
            --api-id "$API_GATEWAY_ID" \
            --integration-type HTTP_PROXY \
            --integration-uri "$provisioning_listener_arn" \
            --connection-type VPC_LINK \
            --connection-id "$VPC_LINK_ID" \
            --integration-method ANY \
            --payload-format-version "1.0" \
            --region "$AWS_REGION" \
            --query 'IntegrationId' \
            --output text 2>/dev/null || \
            aws apigatewayv2 get-integrations \
                --api-id "$API_GATEWAY_ID" \
                --region "$AWS_REGION" \
                --query "Items[?IntegrationUri=='$provisioning_listener_arn'].IntegrationId" \
                --output text | head -1)

        log_success "Integration ID: $provisioning_integration_id"

        # Create Routes
        local routes=(
            "GET /:$provisioning_integration_id:NONE"
            "GET /dashboard:$provisioning_integration_id:NONE"
            "GET /login:$provisioning_integration_id:NONE"
            "GET /health:$provisioning_integration_id:NONE"
            "GET /static/{proxy+}:$provisioning_integration_id:NONE"
            "POST /provision:$provisioning_integration_id:$AUTHORIZER_ID"
            "GET /status/{user_id}:$provisioning_integration_id:$AUTHORIZER_ID"
            "DELETE /delete/{user_id}:$provisioning_integration_id:$AUTHORIZER_ID"
        )

        for route_spec in "${routes[@]}"; do
            IFS=: read -r route_key integration_id auth_id <<< "$route_spec"

            log_info "Creating route: $route_key"

            local create_route_args=(
                --api-id "$API_GATEWAY_ID"
                --route-key "$route_key"
                --target "integrations/$integration_id"
                --region "$AWS_REGION"
            )

            if [ "$auth_id" != "NONE" ]; then
                create_route_args+=(--authorization-type JWT)
                create_route_args+=(--authorizer-id "$auth_id")
            fi

            aws apigatewayv2 create-route "${create_route_args[@]}" \
                >/dev/null 2>&1 || log_warning "Route '$route_key' might already exist"
        done

        log_success "Provisioning Service routes created"
    else
        log_info "[DRY-RUN] Would create API Gateway routes"
    fi
}

#=============================================================================
# Phase 6: WebSocket Routing Configuration
#=============================================================================

configure_websocket_routing() {
    log_info "=========================================="
    log_info "Phase 6: WebSocket Routing Configuration"
    log_info "=========================================="

    if [ "$SKIP_WEBSOCKET" = true ]; then
        log_warning "Skipping WebSocket routing (--skip-websocket)"
        return 0
    fi

    # Wait for Keeper Ingress to be created by Provisioning Service
    log_info "Waiting for Keeper Ingress to be created..."

    local max_wait=120
    local wait_time=0
    local keeper_alb_dns=""

    while [ $wait_time -lt $max_wait ]; do
        keeper_alb_dns=$(kubectl get ingress openclaw-instances-keeper \
            -n "$PROVISIONING_NAMESPACE" \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

        if [ -n "$keeper_alb_dns" ]; then
            break
        fi

        log_info "  Waiting for Keeper Ingress... ($wait_time/$max_wait)"
        sleep 10
        wait_time=$((wait_time + 10))
    done

    if [ -z "$keeper_alb_dns" ]; then
        log_error "Keeper Ingress not found after ${max_wait}s"
        log_error "Please check Provisioning Service logs and try again"
        return 1
    fi

    log_info "  Shared Instances ALB DNS: $keeper_alb_dns"

    # Get Shared Instances ALB Listener ARN
    local shared_alb_arn=$(aws elbv2 describe-load-balancers \
        --region "$AWS_REGION" \
        --query "LoadBalancers[?DNSName=='$keeper_alb_dns'].LoadBalancerArn" \
        --output text)

    local shared_listener_arn=$(aws elbv2 describe-listeners \
        --load-balancer-arn "$shared_alb_arn" \
        --region "$AWS_REGION" \
        --query 'Listeners[?Port==`80`].ListenerArn' \
        --output text)

    log_info "  Shared Listener ARN: $shared_listener_arn"

    # Create WebSocket Integration
    log_info "Creating WebSocket integration..."

    if [ "$DRY_RUN" = false ]; then
        local ws_integration_id=$(aws apigatewayv2 create-integration \
            --api-id "$API_GATEWAY_ID" \
            --integration-type HTTP_PROXY \
            --integration-uri "$shared_listener_arn" \
            --connection-type VPC_LINK \
            --connection-id "$VPC_LINK_ID" \
            --integration-method ANY \
            --payload-format-version "1.0" \
            --request-parameters '{"overwrite:path":"$request.path"}' \
            --region "$AWS_REGION" \
            --query 'IntegrationId' \
            --output text 2>/dev/null || \
            aws apigatewayv2 get-integrations \
                --api-id "$API_GATEWAY_ID" \
                --region "$AWS_REGION" \
                --query "Items[?IntegrationUri=='$shared_listener_arn'].IntegrationId" \
                --output text | head -1)

        log_success "WebSocket Integration ID: $ws_integration_id"

        # Create Instance Routes
        log_info "Creating instance routes..."

        aws apigatewayv2 create-route \
            --api-id "$API_GATEWAY_ID" \
            --route-key 'ANY /instance/{user_id}' \
            --target "integrations/$ws_integration_id" \
            --region "$AWS_REGION" \
            >/dev/null 2>&1 || log_warning "Route 'ANY /instance/{user_id}' might already exist"

        aws apigatewayv2 create-route \
            --api-id "$API_GATEWAY_ID" \
            --route-key 'ANY /instance/{user_id}/{proxy+}' \
            --target "integrations/$ws_integration_id" \
            --region "$AWS_REGION" \
            >/dev/null 2>&1 || log_warning "Route 'ANY /instance/{user_id}/{proxy+}' might already exist"

        log_success "WebSocket routing configured"
    else
        log_info "[DRY-RUN] Would configure WebSocket routing"
    fi
}

#=============================================================================
# Phase 7: Verification and Summary
#=============================================================================

verify_deployment() {
    log_info "=========================================="
    log_info "Phase 7: Deployment Verification"
    log_info "=========================================="

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Skipping verification"
        return 0
    fi

    local all_ok=true

    # Check Operator
    log_info "Checking OpenClaw Operator..."
    if kubectl get deployment openclaw-operator -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        log_success "  Operator deployment: OK"
    else
        log_error "  Operator deployment: FAILED"
        all_ok=false
    fi

    # Check Provisioning Service
    log_info "Checking Provisioning Service..."
    if kubectl get deployment openclaw-provisioning -n "$PROVISIONING_NAMESPACE" >/dev/null 2>&1; then
        log_success "  Provisioning deployment: OK"
    else
        log_error "  Provisioning deployment: FAILED"
        all_ok=false
    fi

    # Check API Gateway
    log_info "Checking API Gateway..."
    local api_endpoint=$(aws apigatewayv2 get-api \
        --api-id "$API_GATEWAY_ID" \
        --region "$AWS_REGION" \
        --query 'ApiEndpoint' \
        --output text 2>/dev/null || echo "")

    if [ -n "$api_endpoint" ]; then
        log_success "  API Gateway: OK"
        log_info "    Endpoint: ${api_endpoint}/prod"

        # Test health endpoint
        local health_status=$(curl -s -o /dev/null -w "%{http_code}" "${api_endpoint}/prod/health" 2>/dev/null || echo "000")
        if [ "$health_status" = "200" ]; then
            log_success "  Health check: OK (HTTP $health_status)"
        else
            log_warning "  Health check: HTTP $health_status (ALB might still be initializing)"
        fi
    else
        log_error "  API Gateway: FAILED"
        all_ok=false
    fi

    if [ "$all_ok" = true ]; then
        log_success "All components deployed successfully!"
    else
        log_error "Some components failed deployment. Please check logs."
        return 1
    fi
}

show_summary() {
    log_info "=========================================="
    log_info "Deployment Summary"
    log_info "=========================================="

    if [ "$DRY_RUN" = true ]; then
        log_info "DRY RUN - No resources were created"
        return 0
    fi

    local api_endpoint=$(aws apigatewayv2 get-api \
        --api-id "$API_GATEWAY_ID" \
        --region "$AWS_REGION" \
        --query 'ApiEndpoint' \
        --output text 2>/dev/null || echo "")

    cat <<EOF

${GREEN}✅ OpenClaw Multi-Tenant Platform Deployed!${NC}

${BLUE}🔐 Cognito Configuration:${NC}
   Region:        $AWS_REGION
   User Pool ID:  $COGNITO_USER_POOL_ID
   Client ID:     $COGNITO_CLIENT_ID

${BLUE}🌐 API Gateway:${NC}
   API ID:        $API_GATEWAY_ID
   VPC Link ID:   $VPC_LINK_ID
   Endpoint:      ${api_endpoint}/prod

${BLUE}📍 Key URLs:${NC}
   Dashboard:     ${api_endpoint}/prod/dashboard
   Login:         ${api_endpoint}/prod/login
   Health:        ${api_endpoint}/prod/health

${BLUE}🔧 Kubernetes Resources:${NC}
   Operator NS:   $OPERATOR_NAMESPACE
   Service NS:    $PROVISIONING_NAMESPACE

${YELLOW}📚 Next Steps:${NC}
   1. Create a test user:
      aws cognito-idp admin-create-user \\
        --user-pool-id $COGNITO_USER_POOL_ID \\
        --username test@example.com \\
        --temporary-password Test123! \\
        --region $AWS_REGION

   2. Access dashboard:
      ${api_endpoint}/prod/dashboard

   3. Check deployment:
      kubectl get pods -n $PROVISIONING_NAMESPACE
      kubectl get pods -n $OPERATOR_NAMESPACE

   4. View logs:
      kubectl logs -n $PROVISIONING_NAMESPACE deployment/openclaw-provisioning -f

${YELLOW}📖 Documentation:${NC}
   - Architecture: ../docs/DEPLOYMENT-SUCCESS.md
   - WebSocket Setup: ../docs/WEBSOCKET-SETUP.md
   - Troubleshooting: ../docs/DEPLOYMENT-PROGRESS.md

EOF
}

#=============================================================================
# Main Execution
#=============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --region)
                AWS_REGION="$2"
                shift 2
                ;;
            --cluster-name)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            --skip-cognito)
                SKIP_COGNITO=true
                shift
                ;;
            --skip-api-gateway)
                SKIP_API_GATEWAY=true
                shift
                ;;
            --skip-operator)
                SKIP_OPERATOR=true
                shift
                ;;
            --skip-provisioning)
                SKIP_PROVISIONING=true
                shift
                ;;
            --skip-websocket)
                SKIP_WEBSOCKET=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                ;;
        esac
    done

    log_info "=========================================="
    log_info "OpenClaw Multi-Tenant Platform Deployment"
    log_info "=========================================="
    log_info "Region:       $AWS_REGION"
    log_info "Cluster:      $CLUSTER_NAME"
    log_info "Dry Run:      $DRY_RUN"
    log_info "=========================================="

    check_prerequisites

    deploy_cognito
    deploy_api_gateway
    deploy_operator
    deploy_provisioning_service
    configure_api_gateway_routes
    configure_websocket_routing
    verify_deployment
    show_summary

    log_success "Deployment complete!"
}

# Run main function
main "$@"
