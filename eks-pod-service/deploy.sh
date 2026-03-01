#!/bin/bash
set -e

# OpenClaw Provisioning Service 部署脚本

# 配置
AWS_REGION="us-west-2"
AWS_ACCOUNT_ID="970547376847"
ECR_REPO="openclaw-provisioning"
IMAGE_TAG="latest"
CLUSTER_NAME="test-s4"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查前置条件
function check_prerequisites() {
    log_info "检查前置条件..."

    # 检查 AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI 未安装"
        exit 1
    fi

    # 检查 Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker 未安装"
        exit 1
    fi

    # 检查 kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl 未安装"
        exit 1
    fi

    # 检查集群连接
    if ! kubectl cluster-info &> /dev/null; then
        log_error "无法连接到 Kubernetes 集群"
        exit 1
    fi

    log_info "前置条件检查通过 ✓"
}

# 构建并推送镜像
function build_and_push() {
    log_info "构建并推送 Docker 镜像..."

    # 登录 ECR
    log_info "登录 ECR..."
    aws ecr get-login-password --region $AWS_REGION | \
        docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

    # 创建 ECR 仓库（如果不存在）
    log_info "确保 ECR 仓库存在..."
    aws ecr describe-repositories --repository-names $ECR_REPO --region $AWS_REGION &> /dev/null || \
        aws ecr create-repository --repository-name $ECR_REPO --region $AWS_REGION

    # 构建镜像
    log_info "构建 Docker 镜像..."
    docker build -t $ECR_REPO:$IMAGE_TAG .

    # 标记镜像
    log_info "标记镜像..."
    docker tag $ECR_REPO:$IMAGE_TAG \
        ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/$ECR_REPO:$IMAGE_TAG

    # 推送镜像
    log_info "推送镜像到 ECR..."
    docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/$ECR_REPO:$IMAGE_TAG

    log_info "镜像构建和推送完成 ✓"
}

# 更新 Kubernetes 部署文件
function update_k8s_manifests() {
    log_info "更新 Kubernetes 部署文件..."

    # 备份原文件
    if [ -f kubernetes/deployment.yaml.bak ]; then
        rm kubernetes/deployment.yaml.bak
    fi
    cp kubernetes/deployment.yaml kubernetes/deployment.yaml.bak

    # 替换镜像地址
    sed -i.tmp "s|image: .*|image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/$ECR_REPO:$IMAGE_TAG|g" \
        kubernetes/deployment.yaml
    rm kubernetes/deployment.yaml.tmp

    log_info "部署文件更新完成 ✓"
}

# 部署到 EKS
function deploy_to_eks() {
    log_info "部署到 EKS 集群..."

    # 应用 RBAC
    log_info "应用 RBAC 配置..."
    kubectl apply -f kubernetes/rbac.yaml

    # 部署应用
    log_info "部署应用..."
    kubectl apply -f kubernetes/deployment.yaml
    kubectl apply -f kubernetes/service.yaml
    kubectl apply -f kubernetes/hpa.yaml
    kubectl apply -f kubernetes/pdb.yaml

    # 等待部署完成
    log_info "等待部署完成..."
    kubectl wait --for=condition=available --timeout=300s \
        deployment/openclaw-provisioning -n openclaw-provisioning

    log_info "部署完成 ✓"
}

# 验证部署
function verify_deployment() {
    log_info "验证部署..."

    # 检查 Pod 状态
    log_info "Pod 状态:"
    kubectl get pods -n openclaw-provisioning

    # 检查 Service
    log_info "Service 状态:"
    kubectl get svc -n openclaw-provisioning

    # 健康检查
    log_info "执行健康检查..."
    kubectl run -it --rm test-health --image=curlimages/curl:latest --restart=Never -- \
        curl -f http://openclaw-provisioning.openclaw-provisioning.svc/health || {
        log_warn "健康检查失败，请检查日志"
        kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=50
    }

    log_info "验证完成 ✓"
}

# 主函数
function main() {
    log_info "开始部署 OpenClaw Provisioning Service..."
    log_info "目标集群: $CLUSTER_NAME"
    log_info "目标区域: $AWS_REGION"

    check_prerequisites
    build_and_push
    update_k8s_manifests
    deploy_to_eks
    verify_deployment

    log_info ""
    log_info "==========================================="
    log_info "部署成功！"
    log_info "==========================================="
    log_info ""
    log_info "后续步骤:"
    log_info "1. 查看日志: kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning -f"
    log_info "2. 测试 API: kubectl port-forward -n openclaw-provisioning svc/openclaw-provisioning 8080:80"
    log_info "3. 健康检查: curl http://localhost:8080/health"
    log_info ""
}

# 运行
main
