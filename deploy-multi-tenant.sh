#!/bin/bash
# OpenClaw Multi-Tenant 自动化部署脚本
# 功能：创建 ALB, Cognito User Pool, VPC Link, API Gateway

set -e

REGION="${AWS_REGION:-us-west-2}"
CLUSTER_NAME="${CLUSTER_NAME:-test-s4}"
NAMESPACE="openclaw-provisioning"
USER_POOL_NAME="openclaw-users"
API_NAME="openclaw-provisioning-api"
CONFIG_FILE="multi-tenant-config.txt"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

function log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

function check_prerequisites() {
    log_info "检查前置条件..."

    for cmd in kubectl aws jq; do
        if ! command -v $cmd &> /dev/null; then
            log_error "$cmd 未安装"
            exit 1
        fi
    done

    # 检查 kubectl 连接
    if ! kubectl cluster-info &> /dev/null; then
        log_error "无法连接到 Kubernetes 集群"
        exit 1
    fi

    log_info "前置条件检查通过 ✓"
}

function deploy_alb_ingress() {
    log_info "=========================================="
    log_info "Phase 1: 部署 ALB Ingress"
    log_info "=========================================="

    # 部署 Ingress
    log_info "应用 Ingress 配置..."
    kubectl apply -f eks-pod-service/kubernetes/ingress.yaml

    log_info "等待 ALB 创建完成 (需要 2-3 分钟)..."
    sleep 60

    # 获取 ALB DNS
    ALB_DNS=$(kubectl get ingress openclaw-provisioning-ingress -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

    if [ -z "$ALB_DNS" ]; then
        log_warn "ALB 尚未就绪，继续等待..."
        sleep 60
        ALB_DNS=$(kubectl get ingress openclaw-provisioning-ingress -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    fi

    log_info "✅ ALB DNS: $ALB_DNS"

    # 验证 ALB 类型
    ALB_ARN=$(aws elbv2 describe-load-balancers --region $REGION --query "LoadBalancers[?DNSName=='$ALB_DNS'].LoadBalancerArn" --output text)
    ALB_TYPE=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --region $REGION --query 'LoadBalancers[0].Type' --output text)
    ALB_SCHEME=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --region $REGION --query 'LoadBalancers[0].Scheme' --output text)

    log_info "  Type: $ALB_TYPE (应该是 application)"
    log_info "  Scheme: $ALB_SCHEME (应该是 internal)"

    if [ "$ALB_TYPE" != "application" ] || [ "$ALB_SCHEME" != "internal" ]; then
        log_error "ALB 配置不正确！"
        exit 1
    fi

    # 获取 Listener ARN
    LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --region $REGION --query 'Listeners[0].ListenerArn' --output text)

    log_info "✅ Listener ARN: $LISTENER_ARN"

    # 保存配置
    cat > $CONFIG_FILE << EOF
ALB_DNS=$ALB_DNS
ALB_ARN=$ALB_ARN
LISTENER_ARN=$LISTENER_ARN
REGION=$REGION
CLUSTER_NAME=$CLUSTER_NAME
EOF
}

function create_cognito() {
    log_info ""
    log_info "=========================================="
    log_info "Phase 2: 创建 Cognito User Pool"
    log_info "=========================================="

    # 创建 User Pool
    log_info "创建 User Pool..."
    USER_POOL_ID=$(aws cognito-idp create-user-pool \
      --pool-name "$USER_POOL_NAME" \
      --region $REGION \
      --policies '{
        "PasswordPolicy": {
          "MinimumLength": 12,
          "RequireUppercase": true,
          "RequireLowercase": true,
          "RequireNumbers": true,
          "RequireSymbols": true
        }
      }' \
      --auto-verified-attributes email \
      --username-attributes email \
      --schema '[{"Name":"email","Required":true,"Mutable":false,"AttributeDataType":"String"}]' \
      --mfa-configuration OFF \
      --query 'UserPool.Id' \
      --output text)

    log_info "✅ User Pool ID: $USER_POOL_ID"

    # 创建 App Client
    log_info "创建 App Client..."
    CLIENT_ID=$(aws cognito-idp create-user-pool-client \
      --user-pool-id $USER_POOL_ID \
      --client-name openclaw-client \
      --region $REGION \
      --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH ALLOW_USER_SRP_AUTH \
      --generate-secret \
      --supported-identity-providers COGNITO \
      --query 'UserPoolClient.ClientId' \
      --output text)

    log_info "✅ Client ID: $CLIENT_ID"

    # 获取 Client Secret
    CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client \
      --user-pool-id $USER_POOL_ID \
      --client-id $CLIENT_ID \
      --region $REGION \
      --query 'UserPoolClient.ClientSecret' \
      --output text)

    # 创建测试用户
    log_info "创建测试用户..."
    TEST_USER="testuser@example.com"
    TEST_PASSWORD="OpenClaw2026!Test"

    aws cognito-idp admin-create-user \
      --user-pool-id $USER_POOL_ID \
      --username $TEST_USER \
      --region $REGION \
      --user-attributes Name=email,Value=$TEST_USER Name=email_verified,Value=true \
      --temporary-password 'TempPassword123!' \
      --message-action SUPPRESS > /dev/null

    aws cognito-idp admin-set-user-password \
      --user-pool-id $USER_POOL_ID \
      --username $TEST_USER \
      --password $TEST_PASSWORD \
      --permanent \
      --region $REGION

    log_info "✅ 测试用户: $TEST_USER / $TEST_PASSWORD"

    # 保存配置
    cat >> $CONFIG_FILE << EOF
USER_POOL_ID=$USER_POOL_ID
CLIENT_ID=$CLIENT_ID
CLIENT_SECRET=$CLIENT_SECRET
TEST_USER=$TEST_USER
TEST_PASSWORD=$TEST_PASSWORD
EOF
}

function create_vpc_link() {
    log_info ""
    log_info "=========================================="
    log_info "Phase 3: 创建 VPC Link"
    log_info "=========================================="

    source $CONFIG_FILE

    # 获取 VPC 子网
    CLUSTER_VPC=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query 'cluster.resourcesVpcConfig.vpcId' --output text)
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$CLUSTER_VPC" --region $REGION --query 'Subnets[0:3].SubnetId' --output text | tr '\t' ' ')

    log_info "VPC: $CLUSTER_VPC"
    log_info "Subnets: $SUBNET_IDS"

    # 创建 VPC Link
    log_info "创建 VPC Link..."
    VPC_LINK_ID=$(aws apigatewayv2 create-vpc-link \
      --name openclaw-provisioning-vpclink \
      --subnet-ids $SUBNET_IDS \
      --region $REGION \
      --query 'VpcLinkId' \
      --output text)

    log_info "✅ VPC Link ID: $VPC_LINK_ID"

    # 等待 VPC Link 就绪
    log_info "等待 VPC Link 变为 AVAILABLE (需要 5-10 分钟)..."
    for i in {1..30}; do
        STATUS=$(aws apigatewayv2 get-vpc-link --vpc-link-id $VPC_LINK_ID --region $REGION --query 'VpcLinkStatus' --output text)
        if [ "$STATUS" == "AVAILABLE" ]; then
            log_info "✅ VPC Link 已就绪"
            break
        fi
        echo -n "."
        sleep 20
    done

    # 保存配置
    cat >> $CONFIG_FILE << EOF
VPC_LINK_ID=$VPC_LINK_ID
CLUSTER_VPC=$CLUSTER_VPC
EOF
}

function create_api_gateway() {
    log_info ""
    log_info "=========================================="
    log_info "Phase 4: 创建 API Gateway"
    log_info "=========================================="

    source $CONFIG_FILE

    # 1. 创建 HTTP API
    log_info "创建 HTTP API..."
    API_ID=$(aws apigatewayv2 create-api \
      --name $API_NAME \
      --protocol-type HTTP \
      --region $REGION \
      --query 'ApiId' \
      --output text)

    log_info "✅ API ID: $API_ID"

    # 2. 创建 Cognito Authorizer
    log_info "创建 Cognito JWT Authorizer..."
    AUTHORIZER_ID=$(aws apigatewayv2 create-authorizer \
      --api-id $API_ID \
      --authorizer-type JWT \
      --name CognitoAuthorizer \
      --identity-source '$request.header.Authorization' \
      --jwt-configuration Audience=$CLIENT_ID,Issuer=https://cognito-idp.$REGION.amazonaws.com/$USER_POOL_ID \
      --region $REGION \
      --query 'AuthorizerId' \
      --output text)

    log_info "✅ Authorizer ID: $AUTHORIZER_ID"

    # 3. 创建 VPC Link Integration
    log_info "创建 VPC Link Integration..."
    INTEGRATION_ID=$(aws apigatewayv2 create-integration \
      --api-id $API_ID \
      --integration-type HTTP_PROXY \
      --integration-method ANY \
      --integration-uri $LISTENER_ARN \
      --connection-type VPC_LINK \
      --connection-id $VPC_LINK_ID \
      --payload-format-version 1.0 \
      --region $REGION \
      --query 'IntegrationId' \
      --output text)

    log_info "✅ Integration ID: $INTEGRATION_ID"

    # 4. 创建路由
    log_info "创建路由..."

    # POST /provision
    aws apigatewayv2 create-route \
      --api-id $API_ID \
      --route-key 'POST /provision' \
      --authorization-type JWT \
      --authorizer-id $AUTHORIZER_ID \
      --target integrations/$INTEGRATION_ID \
      --region $REGION > /dev/null
    log_info "  ✅ POST /provision"

    # GET /status/{user_id}
    aws apigatewayv2 create-route \
      --api-id $API_ID \
      --route-key 'GET /status/{user_id}' \
      --authorization-type JWT \
      --authorizer-id $AUTHORIZER_ID \
      --target integrations/$INTEGRATION_ID \
      --region $REGION > /dev/null
    log_info "  ✅ GET /status/{user_id}"

    # DELETE /delete/{user_id}
    aws apigatewayv2 create-route \
      --api-id $API_ID \
      --route-key 'DELETE /delete/{user_id}' \
      --authorization-type JWT \
      --authorizer-id $AUTHORIZER_ID \
      --target integrations/$INTEGRATION_ID \
      --region $REGION > /dev/null
    log_info "  ✅ DELETE /delete/{user_id}"

    # GET /health (no auth)
    aws apigatewayv2 create-route \
      --api-id $API_ID \
      --route-key 'GET /health' \
      --authorization-type NONE \
      --target integrations/$INTEGRATION_ID \
      --region $REGION > /dev/null
    log_info "  ✅ GET /health"

    # Frontend routes (no auth)
    aws apigatewayv2 create-route \
      --api-id $API_ID \
      --route-key 'GET /' \
      --authorization-type NONE \
      --target integrations/$INTEGRATION_ID \
      --region $REGION > /dev/null
    log_info "  ✅ GET / (Frontend)"

    aws apigatewayv2 create-route \
      --api-id $API_ID \
      --route-key 'GET /dashboard' \
      --authorization-type NONE \
      --target integrations/$INTEGRATION_ID \
      --region $REGION > /dev/null
    log_info "  ✅ GET /dashboard"

    aws apigatewayv2 create-route \
      --api-id $API_ID \
      --route-key 'GET /static/{proxy+}' \
      --authorization-type NONE \
      --target integrations/$INTEGRATION_ID \
      --region $REGION > /dev/null
    log_info "  ✅ GET /static/* (Static files)"

    # 5. 创建 Stage
    log_info "创建 Stage..."
    aws apigatewayv2 create-stage \
      --api-id $API_ID \
      --stage-name prod \
      --auto-deploy \
      --region $REGION > /dev/null

    log_info "✅ Stage 'prod' created"

    # 保存最终配置
    API_ENDPOINT="https://$API_ID.execute-api.$REGION.amazonaws.com/prod"
    cat >> $CONFIG_FILE << EOF
API_ID=$API_ID
AUTHORIZER_ID=$AUTHORIZER_ID
INTEGRATION_ID=$INTEGRATION_ID
API_ENDPOINT=$API_ENDPOINT
EOF
}

function test_api() {
    log_info ""
    log_info "=========================================="
    log_info "Phase 5: 测试 API"
    log_info "=========================================="

    source $CONFIG_FILE

    # 获取 JWT Token
    log_info "登录 Cognito 获取 JWT Token..."
    TOKEN_RESPONSE=$(aws cognito-idp initiate-auth \
      --auth-flow USER_PASSWORD_AUTH \
      --client-id $CLIENT_ID \
      --region $REGION \
      --auth-parameters USERNAME=$TEST_USER,PASSWORD=$TEST_PASSWORD \
      --query 'AuthenticationResult' \
      --output json)

    ID_TOKEN=$(echo $TOKEN_RESPONSE | jq -r '.IdToken')
    log_info "✅ Token 获取成功"

    # 测试健康检查
    log_info ""
    log_info "测试 GET /health (无需认证)..."
    HEALTH_RESPONSE=$(curl -s "${API_ENDPOINT}/health")
    echo "  Response: $HEALTH_RESPONSE"

    # 测试创建实例
    log_info ""
    log_info "测试 POST /provision (需要认证)..."
    PROVISION_RESPONSE=$(curl -s -X POST "${API_ENDPOINT}/provision" \
      -H "Authorization: Bearer $ID_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{}')

    echo "  Response:"
    echo "$PROVISION_RESPONSE" | jq . 2>/dev/null || echo "$PROVISION_RESPONSE"
}

function print_summary() {
    log_info ""
    log_info "=========================================="
    log_info "✅ 部署完成！"
    log_info "=========================================="
    log_info ""

    source $CONFIG_FILE

    echo "配置信息:"
    echo "  API Endpoint:  $API_ENDPOINT"
    echo "  User Pool ID:  $USER_POOL_ID"
    echo "  Client ID:     $CLIENT_ID"
    echo "  Test User:     $TEST_USER"
    echo "  Test Password: $TEST_PASSWORD"
    echo ""
    echo "配置文件: $CONFIG_FILE"
    echo ""

    log_info "测试命令:"
    echo ""
    echo "# 1. 获取 JWT Token"
    echo "TOKEN=\$(aws cognito-idp initiate-auth \\"
    echo "  --auth-flow USER_PASSWORD_AUTH \\"
    echo "  --client-id $CLIENT_ID \\"
    echo "  --region $REGION \\"
    echo "  --auth-parameters USERNAME=$TEST_USER,PASSWORD=$TEST_PASSWORD \\"
    echo "  --query 'AuthenticationResult.IdToken' \\"
    echo "  --output text)"
    echo ""
    echo "# 2. 测试创建实例"
    echo "curl -X POST \"$API_ENDPOINT/provision\" \\"
    echo "  -H \"Authorization: Bearer \$TOKEN\" \\"
    echo "  -H \"Content-Type: application/json\" \\"
    echo "  -d '{}' | jq ."
    echo ""
}

# 主函数
function main() {
    log_info "=========================================="
    log_info "OpenClaw Multi-Tenant 自动化部署"
    log_info "=========================================="
    log_info ""

    check_prerequisites
    deploy_alb_ingress
    create_cognito
    create_vpc_link
    create_api_gateway
    test_api
    print_summary
}

# 运行
main
