#!/bin/bash
set -e

# OpenClaw Provisioning Service - 部署脚本（Local Auth）
# 用途：将 Cognito 认证迁移到本地用户名/密码认证

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 配置
ECR_REGISTRY="${ECR_REGISTRY:-111122223333.dkr.ecr.us-west-2.amazonaws.com}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
AWS_REGION="${AWS_REGION:-us-west-2}"
NAMESPACE="openclaw-provisioning"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}OpenClaw Local Auth Deployment${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Step 1: 检查环境
echo -e "${YELLOW}Step 1: 检查环境...${NC}"
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}错误: kubectl 未安装${NC}"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    echo -e "${RED}错误: docker 未安装${NC}"
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo -e "${RED}错误: aws cli 未安装${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 环境检查通过${NC}"
echo ""

# Step 2: 检查 EFS StorageClass
echo -e "${YELLOW}Step 2: 检查 EFS StorageClass...${NC}"
if ! kubectl get storageclass efs-sc &> /dev/null; then
    echo -e "${RED}警告: efs-sc StorageClass 不存在${NC}"
    echo -e "${YELLOW}Session 共享需要 EFS，请先创建 EFS StorageClass：${NC}"
    echo "kubectl apply -f ../storage/efs-storageclass.yaml"
    read -p "是否继续？(y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo -e "${GREEN}✓ EFS StorageClass 存在${NC}"
fi
echo ""

# Step 3: 创建 Namespace（如果不存在）
echo -e "${YELLOW}Step 3: 确保 Namespace 存在...${NC}"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ Namespace: $NAMESPACE${NC}"
echo ""

# Step 4: 生成 SECRET_KEY（如果不存在）
echo -e "${YELLOW}Step 4: 确保 SECRET_KEY 存在...${NC}"
if ! kubectl get secret openclaw-provisioning-secret -n $NAMESPACE &> /dev/null; then
    echo -e "${YELLOW}生成新的 SECRET_KEY...${NC}"
    SECRET_KEY=$(openssl rand -base64 32)
    kubectl create secret generic openclaw-provisioning-secret \
        --from-literal=secret-key="$SECRET_KEY" \
        -n $NAMESPACE
    echo -e "${GREEN}✓ SECRET_KEY 已创建${NC}"
else
    echo -e "${GREEN}✓ SECRET_KEY 已存在${NC}"
fi
echo ""

# Step 5: 构建 Docker 镜像
echo -e "${YELLOW}Step 5: 构建 Docker 镜像...${NC}"
echo "镜像: ${ECR_REGISTRY}/openclaw-provisioning:${IMAGE_TAG}"
read -p "是否构建并推送新镜像？(Y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
    # 登录 ECR
    echo -e "${YELLOW}登录 ECR...${NC}"
    aws ecr get-login-password --region $AWS_REGION | \
        docker login --username AWS --password-stdin $ECR_REGISTRY

    # 构建镜像
    echo -e "${YELLOW}构建镜像...${NC}"
    docker build -t ${ECR_REGISTRY}/openclaw-provisioning:${IMAGE_TAG} .

    # 推送镜像
    echo -e "${YELLOW}推送镜像...${NC}"
    docker push ${ECR_REGISTRY}/openclaw-provisioning:${IMAGE_TAG}

    echo -e "${GREEN}✓ 镜像构建并推送成功${NC}"
else
    echo -e "${YELLOW}跳过镜像构建${NC}"
fi
echo ""

# Step 6: 应用 PVC
echo -e "${YELLOW}Step 6: 创建 PersistentVolumeClaims...${NC}"
kubectl apply -f kubernetes/pvc.yaml
echo -e "${GREEN}✓ PVC 已创建/更新${NC}"

# 等待 PVC Bound
echo -e "${YELLOW}等待 PVC 绑定...${NC}"
kubectl wait --for=condition=Ready pvc/openclaw-provisioning-data -n $NAMESPACE --timeout=60s || true
kubectl wait --for=condition=Ready pvc/openclaw-provisioning-sessions -n $NAMESPACE --timeout=60s || true

# 显示 PVC 状态
kubectl get pvc -n $NAMESPACE
echo ""

# Step 7: 应用 ConfigMap（如果存在）
echo -e "${YELLOW}Step 7: 应用 ConfigMap...${NC}"
if [ -f kubernetes/configmap.yaml ]; then
    # 移除 Cognito 配置（如果存在）
    sed -i.bak '/COGNITO_/d' kubernetes/configmap.yaml || true
    kubectl apply -f kubernetes/configmap.yaml
    echo -e "${GREEN}✓ ConfigMap 已应用${NC}"
else
    echo -e "${YELLOW}⚠ ConfigMap 不存在，跳过${NC}"
fi
echo ""

# Step 8: 应用 RBAC（如果存在）
echo -e "${YELLOW}Step 8: 应用 RBAC...${NC}"
if [ -f kubernetes/rbac.yaml ]; then
    kubectl apply -f kubernetes/rbac.yaml
    echo -e "${GREEN}✓ RBAC 已应用${NC}"
else
    echo -e "${YELLOW}⚠ RBAC 配置不存在，跳过${NC}"
fi
echo ""

# Step 9: 应用 Deployment
echo -e "${YELLOW}Step 9: 部署应用...${NC}"
# 替换镜像地址
sed "s|\${ECR_REGISTRY}|${ECR_REGISTRY}|g" kubernetes/deployment-with-volumes.yaml | kubectl apply -f -
echo -e "${GREEN}✓ Deployment 已创建/更新${NC}"
echo ""

# Step 10: 等待部署完成
echo -e "${YELLOW}Step 10: 等待部署完成...${NC}"
kubectl rollout status deployment/openclaw-provisioning -n $NAMESPACE --timeout=5m

echo -e "${GREEN}✓ 部署完成${NC}"
echo ""

# Step 11: 显示状态
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}部署状态${NC}"
echo -e "${YELLOW}========================================${NC}"

echo ""
echo "Pods:"
kubectl get pods -n $NAMESPACE -l app=openclaw-provisioning

echo ""
echo "PVCs:"
kubectl get pvc -n $NAMESPACE

echo ""
echo "Service:"
kubectl get svc -n $NAMESPACE openclaw-provisioning

echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "${GREEN}部署成功！${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

# Step 12: 验证
echo -e "${YELLOW}验证部署...${NC}"
echo ""
echo "1. 查看日志："
echo "   kubectl logs -n $NAMESPACE -l app=openclaw-provisioning --tail=50"
echo ""
echo "2. Port-forward 到本地测试："
echo "   kubectl port-forward -n $NAMESPACE svc/openclaw-provisioning 8080:80"
echo "   然后访问: http://localhost:8080/login"
echo ""
echo "3. 测试注册 API："
echo "   curl -X POST http://localhost:8080/register \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"username\":\"testuser\",\"email\":\"test@example.com\",\"password\":\"test1234\"}'"
echo ""
echo "4. 测试登录 API："
echo "   curl -X POST http://localhost:8080/login \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -c cookies.txt \\"
echo "     -d '{\"email\":\"test@example.com\",\"password\":\"test1234\"}'"
echo ""

# 可选：自动 port-forward
read -p "是否启动 port-forward 进行测试？(y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}启动 port-forward on http://localhost:8080${NC}"
    kubectl port-forward -n $NAMESPACE svc/openclaw-provisioning 8080:80
fi
