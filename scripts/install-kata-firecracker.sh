#!/bin/bash
set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Kata Containers + Firecracker 安装脚本 for EKS          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
print_step() {
    echo -e "${BLUE}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Check prerequisites
print_step "步骤 0: 检查前提条件"

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl 未安装"
    exit 1
fi
print_success "kubectl 已安装"

# Check cluster connectivity
if ! kubectl cluster-info &> /dev/null; then
    print_error "无法连接到 Kubernetes 集群"
    exit 1
fi
print_success "Kubernetes 集群连接正常"

# Check for metal instances
echo ""
print_step "检查节点类型..."
METAL_NODES=$(kubectl get nodes -o jsonpath='{.items[?(@.metadata.labels.node\.kubernetes\.io/instance-type=~".*metal")].metadata.name}')

if [ -z "$METAL_NODES" ]; then
    print_warning "未检测到 metal 实例类型"
    echo ""
    echo "Firecracker 需要硬件虚拟化支持（KVM）"
    echo "支持的实例类型:"
    echo "  • c5.metal, c5n.metal"
    echo "  • m5.metal, m5d.metal, m5dn.metal"
    echo "  • c6i.metal, m6i.metal"
    echo "  • c6id.metal, m6id.metal"
    echo "  • c7g.metal (ARM64)"
    echo ""
    read -p "是否继续安装? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    print_success "检测到 metal 节点: $METAL_NODES"
fi

# Step 1: Create metal node pool (optional)
echo ""
print_step "步骤 1: 创建 Metal 实例 NodePool (可选)"
if [ -f "kata-metal-nodepool.yaml" ]; then
    read -p "是否创建 Karpenter NodePool? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_step "更新 NodePool 配置..."
        print_warning "请确保已更新 kata-metal-nodepool.yaml 中的以下值:"
        echo "  • KarpenterNodeRole (IAM role name)"
        echo "  • karpenter.sh/discovery 标签 (集群名称)"
        echo ""
        read -p "配置已更新？继续? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl apply -f kata-metal-nodepool.yaml
            print_success "NodePool 已创建"
            print_step "等待节点启动..."
            sleep 30
            kubectl get nodes -l katacontainers.io/kata-runtime=true
        fi
    fi
else
    print_warning "kata-metal-nodepool.yaml 文件不存在，跳过"
fi

# Step 2: Deploy Kata Firecracker
echo ""
print_step "步骤 2: 部署 Kata Containers with Firecracker"
if [ ! -f "kata-firecracker-deploy.yaml" ]; then
    print_error "kata-firecracker-deploy.yaml 文件不存在"
    exit 1
fi

print_step "创建 kata-system namespace..."
kubectl apply -f kata-firecracker-deploy.yaml

print_success "Kata Firecracker DaemonSet 已创建"

# Wait for DaemonSet to be ready
print_step "等待 Kata Firecracker 安装完成..."
echo "这可能需要 2-5 分钟，正在下载 Firecracker..."

timeout=300
elapsed=0
while [ $elapsed -lt $timeout ]; do
    READY=$(kubectl get ds kata-firecracker-deploy -n kata-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    DESIRED=$(kubectl get ds kata-firecracker-deploy -n kata-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")

    if [ "$READY" -gt 0 ] && [ "$READY" -eq "$DESIRED" ]; then
        print_success "Kata Firecracker 安装完成 ($READY/$DESIRED pods ready)"
        break
    fi

    echo -ne "\r  等待中... ($READY/$DESIRED pods ready) [$elapsed/${timeout}s]"
    sleep 5
    elapsed=$((elapsed + 5))
done
echo ""

if [ $elapsed -ge $timeout ]; then
    print_error "安装超时"
    print_step "检查 DaemonSet 状态..."
    kubectl get ds -n kata-system
    kubectl get pods -n kata-system
    exit 1
fi

# Step 3: Verify installation
echo ""
print_step "步骤 3: 验证安装"

print_step "检查 RuntimeClass..."
if kubectl get runtimeclass kata-fc &> /dev/null; then
    print_success "RuntimeClass 'kata-fc' 已创建"
    kubectl get runtimeclass kata-fc
else
    print_error "RuntimeClass 'kata-fc' 未找到"
    exit 1
fi

echo ""
print_step "检查 Kata DaemonSet..."
kubectl get ds -n kata-system

echo ""
print_step "检查 Firecracker 版本..."
POD_NAME=$(kubectl get pods -n kata-system -l app=kata-firecracker-deploy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_NAME" ]; then
    kubectl exec -n kata-system "$POD_NAME" -- /opt/kata/bin/firecracker --version || print_warning "无法获取 Firecracker 版本"
fi

# Step 4: Run test pod
echo ""
print_step "步骤 4: 运行测试 Pod"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: firecracker-test
  namespace: default
spec:
  runtimeClassName: kata-fc
  containers:
  - name: test
    image: busybox:latest
    command: ["sh", "-c", "echo 'Firecracker VM is running!' && uname -a && sleep 3600"]
  nodeSelector:
    katacontainers.io/kata-runtime: "true"
  tolerations:
  - key: kata-dedicated
    operator: Exists
    effect: NoSchedule
EOF

print_step "等待测试 Pod 启动..."
kubectl wait --for=condition=ready pod/firecracker-test --timeout=120s || print_warning "测试 Pod 未就绪"

echo ""
print_step "测试 Pod 内核版本 (应该与主机不同):"
kubectl exec firecracker-test -- uname -r || print_warning "无法获取内核版本"

echo ""
print_step "测试 Pod 启动时间:"
START_TIME=$(kubectl get pod firecracker-test -o jsonpath='{.status.startTime}')
READY_TIME=$(kubectl get pod firecracker-test -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')
echo "  启动时间: $START_TIME"
echo "  就绪时间: $READY_TIME"

# Step 5: Summary
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  🎉 Kata Firecracker 安装完成!                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "✓ RuntimeClass 'kata-fc' 已创建"
echo "✓ Firecracker 已安装到 Metal 节点"
echo "✓ 测试 Pod 正在运行"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
print_step "下一步:"
echo ""
echo "1️⃣  验证测试 Pod:"
echo "   kubectl get pod firecracker-test"
echo "   kubectl logs firecracker-test"
echo ""
echo "2️⃣  部署 OpenClaw with Firecracker:"
echo "   kubectl apply -f openclaw-firecracker.yaml"
echo ""
echo "3️⃣  检查 OpenClaw 状态:"
echo "   kubectl get openclawinstance -n openclaw"
echo "   kubectl get pods -n openclaw"
echo ""
echo "4️⃣  性能对比 (可选):"
echo "   # 创建 runc baseline"
echo "   kubectl apply -f openclaw-runc.yaml"
echo "   # 对比启动时间和资源使用"
echo ""
echo "5️⃣  清理测试 Pod:"
echo "   kubectl delete pod firecracker-test"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
print_step "文档和监控:"
echo "  • 架构文档: cat FIRECRACKER-KATA-ARCHITECTURE.md"
echo "  • 性能对比: cat FIRECRACKER-PERFORMANCE.md"
echo "  • 监控指标: kubectl top pods -n openclaw"
echo ""
print_step "故障排查:"
echo "  • DaemonSet 日志: kubectl logs -n kata-system -l app=kata-firecracker-deploy -c kata-artifacts"
echo "  • Containerd 配置: kubectl debug node/<node-name> -- cat /host/etc/containerd/config.toml"
echo "  • Firecracker 日志: kubectl logs -n kata-system <pod-name> -c firecracker-install"
echo ""
print_success "安装脚本执行完成!"
