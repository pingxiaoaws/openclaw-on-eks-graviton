#!/bin/bash
# OpenClaw Multi-Tenant 清理脚本
# 功能：删除 API Gateway, VPC Link, Cognito User Pool, ALB Ingress

set -e

CONFIG_FILE="multi-tenant-config.txt"
REGION="${AWS_REGION:-us-west-2}"
NAMESPACE="openclaw-provisioning"

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

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "找不到配置文件 $CONFIG_FILE"
    echo "将尝试查找并删除资源..."
fi

echo "=========================================="
echo "OpenClaw Multi-Tenant 清理"
echo "=========================================="
echo ""
log_warn "这将删除以下资源:"
echo "  - API Gateway (openclaw-provisioning-api)"
echo "  - VPC Link (openclaw-provisioning-vpclink)"
echo "  - Cognito User Pool (openclaw-users)"
echo "  - ALB Ingress (openclaw-provisioning-ingress)"
echo ""
read -p "确认删除? (yes/NO) " -r
echo
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "已取消"
    exit 0
fi

# 加载配置（如果存在）
if [ -f "$CONFIG_FILE" ]; then
    source $CONFIG_FILE
fi

# 1. 删除 API Gateway
log_info "=========================================="
log_info "Phase 1: 删除 API Gateway"
log_info "=========================================="

if [ -n "$API_ID" ]; then
    log_info "删除 API Gateway: $API_ID"
    aws apigatewayv2 delete-api --api-id $API_ID --region $REGION 2>/dev/null || log_warn "API Gateway 不存在或已删除"
    log_info "✅ API Gateway 已删除"
else
    # 尝试查找并删除
    API_IDS=$(aws apigatewayv2 get-apis --region $REGION --query "Items[?Name=='openclaw-provisioning-api'].ApiId" --output text)
    if [ -n "$API_IDS" ]; then
        for id in $API_IDS; do
            log_info "删除 API Gateway: $id"
            aws apigatewayv2 delete-api --api-id $id --region $REGION
        done
        log_info "✅ API Gateway 已删除"
    else
        log_warn "未找到 API Gateway"
    fi
fi

# 2. 删除 VPC Link
log_info ""
log_info "=========================================="
log_info "Phase 2: 删除 VPC Link"
log_info "=========================================="

if [ -n "$VPC_LINK_ID" ]; then
    log_info "删除 VPC Link: $VPC_LINK_ID"
    aws apigatewayv2 delete-vpc-link --vpc-link-id $VPC_LINK_ID --region $REGION 2>/dev/null || log_warn "VPC Link 不存在或已删除"
    log_info "✅ VPC Link 已删除 (异步删除，需要几分钟)"
else
    # 尝试查找并删除
    VPC_LINK_IDS=$(aws apigatewayv2 get-vpc-links --region $REGION --query "Items[?Name=='openclaw-provisioning-vpclink'].VpcLinkId" --output text)
    if [ -n "$VPC_LINK_IDS" ]; then
        for id in $VPC_LINK_IDS; do
            log_info "删除 VPC Link: $id"
            aws apigatewayv2 delete-vpc-link --vpc-link-id $id --region $REGION
        done
        log_info "✅ VPC Link 已删除 (异步删除，需要几分钟)"
    else
        log_warn "未找到 VPC Link"
    fi
fi

# 3. 删除 Cognito User Pool
log_info ""
log_info "=========================================="
log_info "Phase 3: 删除 Cognito User Pool"
log_info "=========================================="

if [ -n "$USER_POOL_ID" ]; then
    log_info "删除 User Pool: $USER_POOL_ID"
    aws cognito-idp delete-user-pool --user-pool-id $USER_POOL_ID --region $REGION 2>/dev/null || log_warn "User Pool 不存在或已删除"
    log_info "✅ Cognito User Pool 已删除"
else
    # 尝试查找并删除
    USER_POOL_IDS=$(aws cognito-idp list-user-pools --max-results 50 --region $REGION --query "UserPools[?Name=='openclaw-users'].Id" --output text)
    if [ -n "$USER_POOL_IDS" ]; then
        for id in $USER_POOL_IDS; do
            log_info "删除 User Pool: $id"
            aws cognito-idp delete-user-pool --user-pool-id $id --region $REGION
        done
        log_info "✅ Cognito User Pool 已删除"
    else
        log_warn "未找到 User Pool"
    fi
fi

# 4. 删除 ALB Ingress
log_info ""
log_info "=========================================="
log_info "Phase 4: 删除 ALB Ingress"
log_info "=========================================="

if kubectl get ingress openclaw-provisioning-ingress -n $NAMESPACE &> /dev/null; then
    log_info "删除 Ingress: openclaw-provisioning-ingress"
    kubectl delete ingress openclaw-provisioning-ingress -n $NAMESPACE
    log_info "⏳ 等待 ALB 删除 (需要 2-3 分钟)..."
    sleep 60
    log_info "✅ Ingress 已删除"
else
    log_warn "未找到 Ingress"
fi

# 5. 删除配置文件
if [ -f "$CONFIG_FILE" ]; then
    log_info ""
    log_info "删除配置文件: $CONFIG_FILE"
    rm -f $CONFIG_FILE
    log_info "✅ 配置文件已删除"
fi

log_info ""
log_info "=========================================="
log_info "✅ 清理完成！"
log_info "=========================================="
log_info ""
log_info "注意:"
echo "  - VPC Link 删除是异步的，可能需要几分钟"
echo "  - ALB 删除后，安全组可能需要手动清理"
echo ""
