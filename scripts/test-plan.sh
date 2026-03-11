#!/bin/bash
# OpenClaw API Gateway + Internal ALB 测试计划执行脚本

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

function print_header() {
    echo ""
    echo "=================================="
    echo "$1"
    echo "=================================="
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

function check_command() {
    if command -v $1 &> /dev/null; then
        print_success "$1 已安装"
        return 0
    else
        print_error "$1 未安装"
        return 1
    fi
}

function pause() {
    echo ""
    read -p "按 Enter 继续..."
    echo ""
}

# ========================================
# 阶段 0: 前置条件检查
# ========================================
print_header "阶段 0: 前置条件检查"

echo "检查必需工具..."
check_command kubectl || exit 1
check_command aws || exit 1
check_command docker || exit 1
check_command jq || exit 1

echo ""
echo "检查 Kubernetes 集群连接..."
if kubectl cluster-info &> /dev/null; then
    CLUSTER=$(kubectl config current-context)
    print_success "已连接到集群: $CLUSTER"
else
    print_error "无法连接到 Kubernetes 集群"
    exit 1
fi

echo ""
echo "检查 AWS 凭证..."
if aws sts get-caller-identity &> /dev/null; then
    ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    print_success "AWS Account: $ACCOUNT"
else
    print_error "AWS 凭证无效"
    exit 1
fi

echo ""
echo "检查 AWS Load Balancer Controller..."
if kubectl get deployment -n kube-system aws-load-balancer-controller &> /dev/null; then
    print_success "AWS Load Balancer Controller 已安装"
else
    print_error "AWS Load Balancer Controller 未安装"
    exit 1
fi

echo ""
echo "检查 API Gateway..."
API_ID="xxxxxxxxxx"
if aws apigatewayv2 get-api --api-id $API_ID --region us-west-2 &> /dev/null; then
    print_success "API Gateway 已存在: $API_ID"
else
    print_error "API Gateway 不存在"
    exit 1
fi

echo ""
echo "检查 VPC Link..."
VPC_LINK_ID="kn1heg"
VPC_LINK_STATUS=$(aws apigatewayv2 get-vpc-link --vpc-link-id $VPC_LINK_ID --region us-west-2 --query 'VpcLinkStatus' --output text)
if [ "$VPC_LINK_STATUS" == "AVAILABLE" ]; then
    print_success "VPC Link 可用: $VPC_LINK_ID"
else
    print_error "VPC Link 状态异常: $VPC_LINK_STATUS"
    exit 1
fi

print_success "所有前置条件检查通过！"

# ========================================
# 阶段 1: 清理现有资源（可选）
# ========================================
print_header "阶段 1: 清理现有资源（可选）"

echo "当前存在的 OpenClaw instances:"
kubectl get openclawinstance -A 2>/dev/null || echo "  无"

echo ""
read -p "是否删除现有 instances 并从头测试？(y/N): " CLEAN
if [[ $CLEAN =~ ^[Yy]$ ]]; then
    echo "删除现有 instances..."
    kubectl get openclawinstance -A -o json | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | while read ns name; do
        echo "  删除 $name (namespace: $ns)"
        kubectl delete openclawinstance $name -n $ns --wait=false
    done

    echo "等待资源清理... (30秒)"
    sleep 30

    # 清理可能残留的 Ingress
    kubectl get ingress -A -l alb.ingress.kubernetes.io/group.name=openclaw-instances -o json | \
        jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | while read ns name; do
        echo "  删除 Ingress $name (namespace: $ns)"
        kubectl delete ingress $name -n $ns --wait=false
    done

    print_success "清理完成"
else
    print_warning "跳过清理，使用现有资源"
fi

pause

# ========================================
# 阶段 2: 重新部署 Operator
# ========================================
print_header "阶段 2: 重新部署 OpenClaw Operator"

echo "当前 operator 版本:"
kubectl get deployment openclaw-operator -n openclaw-operator-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "  Operator 未部署"

echo ""
read -p "是否重新部署 operator？(y/N): " DEPLOY_OPERATOR
if [[ $DEPLOY_OPERATOR =~ ^[Yy]$ ]]; then
    cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata/openclaw-operator

    echo "更新 CRD..."
    make install

    echo "部署 operator..."
    kubectl delete deployment openclaw-operator -n openclaw-operator-system --ignore-not-found
    make deploy

    echo "等待 operator 就绪..."
    kubectl wait --for=condition=available deployment/openclaw-operator \
        -n openclaw-operator-system --timeout=120s

    print_success "Operator 部署完成"
else
    print_warning "跳过 operator 部署"
fi

pause

# ========================================
# 阶段 3: 重新部署 Provisioning Service
# ========================================
print_header "阶段 3: 重新部署 Provisioning Service"

echo "当前 provisioning service 版本:"
kubectl get deployment openclaw-provisioning -n openclaw-provisioning \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "  未部署"

echo ""
echo "准备构建新镜像..."
echo "  镜像: 111122223333.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest"
echo ""
read -p "请在远程机器上构建并推送镜像，完成后按 Enter 继续..." DUMMY

echo ""
echo "重启 deployment..."
kubectl rollout restart deployment/openclaw-provisioning -n openclaw-provisioning
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning --timeout=120s

print_success "Provisioning Service 部署完成"

echo ""
echo "验证 pods 状态:"
kubectl get pods -n openclaw-provisioning

pause

# ========================================
# 阶段 4: 创建测试 Instance
# ========================================
print_header "阶段 4: 创建 OpenClaw Instance"

echo "获取测试用 JWT token..."
TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id 62csdgbfh62kqtekbhjpqhmlta \
  --auth-parameters USERNAME=testuser@example.com,PASSWORD=TestPass123! \
  --region us-west-2 \
  --query 'AuthenticationResult.IdToken' \
  --output text 2>/dev/null)

if [ -z "$TOKEN" ]; then
    print_error "无法获取 JWT token"
    exit 1
fi
print_success "JWT token 获取成功"

echo ""
echo "创建 OpenClaw instance..."
RESPONSE=$(curl -s -X POST \
  "https://xxxxxxxxxx.execute-api.us-west-2.amazonaws.com/prod/provision" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}')

echo "$RESPONSE" | jq .

USER_ID=$(echo "$RESPONSE" | jq -r '.user_id')
if [ -z "$USER_ID" ] || [ "$USER_ID" == "null" ]; then
    print_error "Instance 创建失败"
    exit 1
fi

print_success "Instance 创建成功: $USER_ID"

pause

# ========================================
# 阶段 5: 等待 Internal ALB 创建
# ========================================
print_header "阶段 5: 等待 Internal ALB 创建"

echo "监控 Ingress 创建（需要 2-3 分钟）..."
echo "  Namespace: openclaw-$USER_ID"
echo "  Instance: openclaw-$USER_ID"

for i in {1..60}; do
    echo -n "."
    sleep 3

    ALB_DNS=$(kubectl get ingress openclaw-$USER_ID -n openclaw-$USER_ID \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

    if [ -n "$ALB_DNS" ]; then
        echo ""
        print_success "Internal ALB 创建完成!"
        echo "  ALB DNS: $ALB_DNS"
        break
    fi

    if [ $i -eq 60 ]; then
        echo ""
        print_error "超时：ALB 未创建"
        echo ""
        echo "检查 Ingress 状态:"
        kubectl describe ingress openclaw-$USER_ID -n openclaw-$USER_ID | tail -20
        exit 1
    fi
done

echo ""
echo "验证 Ingress 配置:"
kubectl get ingress openclaw-$USER_ID -n openclaw-$USER_ID -o yaml | grep -A 10 "annotations:"

pause

# ========================================
# 阶段 6: 配置 API Gateway 路由
# ========================================
print_header "阶段 6: 配置 API Gateway 路由"

echo "检查是否已存在 OpenClaw 路由..."
EXISTING_ROUTE=$(aws apigatewayv2 get-routes --api-id xxxxxxxxxx --region us-west-2 \
    --query 'Items[?contains(RouteKey, `instance`)].RouteId' --output text)

if [ -n "$EXISTING_ROUTE" ]; then
    print_warning "OpenClaw 路由已存在: $EXISTING_ROUTE"
    read -p "是否重新创建？(y/N): " RECREATE
    if [[ $RECREATE =~ ^[Yy]$ ]]; then
        echo "删除现有路由..."
        aws apigatewayv2 delete-route --api-id xxxxxxxxxx --region us-west-2 --route-id $EXISTING_ROUTE
        print_success "路由已删除"
    else
        print_warning "跳过 API Gateway 配置"
        pause
        # 跳到测试阶段
        SKIP_GATEWAY_SETUP=true
    fi
fi

if [ "$SKIP_GATEWAY_SETUP" != "true" ]; then
    echo ""
    echo "运行 API Gateway 配置脚本..."
    cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata
    ./scripts/setup-api-gateway-routes.sh

    pause
fi

# ========================================
# 阶段 7: 测试访问
# ========================================
print_header "阶段 7: 测试访问"

echo "测试 1: 验证 API Gateway 路由配置"
echo "-------------------------------------"
aws apigatewayv2 get-routes --api-id xxxxxxxxxx --region us-west-2 \
    --query 'Items[?contains(RouteKey, `instance`)].{RouteKey:RouteKey,Target:Target}' \
    --output table

echo ""
echo "测试 2: 通过 API Gateway 访问 OpenClaw"
echo "-------------------------------------"
API_GATEWAY_URL="https://xxxxxxxxxx.execute-api.us-west-2.amazonaws.com/prod/instance/$USER_ID/"
echo "URL: $API_GATEWAY_URL"
echo ""

echo "尝试访问（带 JWT token）..."
HTTP_STATUS=$(curl -s -o /tmp/response.txt -w "%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    "$API_GATEWAY_URL")

echo "HTTP Status: $HTTP_STATUS"

if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
    print_success "访问成功！"
    echo ""
    echo "响应内容（前 500 字符）:"
    head -c 500 /tmp/response.txt
    echo ""
elif [ "$HTTP_STATUS" -eq 401 ]; then
    print_warning "401 Unauthorized - OpenClaw gateway_token 认证（预期行为）"
    echo "这是正常的，OpenClaw 需要额外的 gateway_token"
elif [ "$HTTP_STATUS" -eq 502 ]; then
    print_error "502 Bad Gateway - ALB 健康检查可能失败"
    echo ""
    echo "检查 Pod 状态:"
    kubectl get pods -n openclaw-$USER_ID
    kubectl logs -n openclaw-$USER_ID openclaw-$USER_ID-0 -c openclaw --tail=20
else
    print_error "访问失败: HTTP $HTTP_STATUS"
    echo ""
    echo "响应内容:"
    cat /tmp/response.txt
fi

echo ""
echo "测试 3: 通过 Dashboard 测试"
echo "-------------------------------------"
echo "1. 访问: https://xxxxxxxxxx.execute-api.us-west-2.amazonaws.com/prod/dashboard"
echo "2. 登录: testuser@example.com / TestPass123!"
echo "3. 点击 'Connect to Gateway' 按钮"
echo "4. 观察是否能打开新标签访问 OpenClaw"
echo ""
read -p "完成 Dashboard 测试后按 Enter 继续..." DUMMY

echo ""
echo "测试 4: 验证 status API 返回"
echo "-------------------------------------"
curl -s -H "Authorization: Bearer $TOKEN" \
    "https://xxxxxxxxxx.execute-api.us-west-2.amazonaws.com/prod/status/$USER_ID" | \
    jq '{user_id, status, api_gateway_url, gateway_endpoint}'

# ========================================
# 测试总结
# ========================================
print_header "测试总结"

echo "Instance 信息:"
echo "  User ID: $USER_ID"
echo "  Namespace: openclaw-$USER_ID"
echo "  API Gateway URL: $API_GATEWAY_URL"
echo ""

echo "资源状态:"
echo "  OpenClawInstance:"
kubectl get openclawinstance -n openclaw-$USER_ID openclaw-$USER_ID -o jsonpath='{.status.phase}' 2>/dev/null || echo "    N/A"

echo ""
echo "  Ingress:"
kubectl get ingress -n openclaw-$USER_ID 2>/dev/null || echo "    N/A"

echo ""
echo "  Pods:"
kubectl get pods -n openclaw-$USER_ID 2>/dev/null || echo "    N/A"

echo ""
echo "API Gateway 路由:"
aws apigatewayv2 get-routes --api-id xxxxxxxxxx --region us-west-2 \
    --query 'Items[?contains(RouteKey, `instance`)].RouteKey' \
    --output text

echo ""
print_success "测试计划执行完成！"
echo ""
echo "下一步:"
echo "  1. 如果所有测试通过，可以开始创建更多 instances"
echo "  2. 监控 ALB 健康状态: kubectl describe ingress -n openclaw-$USER_ID"
echo "  3. 查看 API Gateway 日志: aws logs tail /aws/apigateway/xxxxxxxxxx --follow"
echo "  4. 清理测试资源: kubectl delete openclawinstance openclaw-$USER_ID -n openclaw-$USER_ID"
