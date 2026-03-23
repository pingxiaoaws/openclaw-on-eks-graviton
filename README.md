# OpenClaw on EKS Graviton — Multi-Tenant AI Agent Platform

在 Amazon EKS (Graviton ARM64) 上部署 OpenClaw 多租户 AI Agent 平台，支持 Kata Containers 硬件级 VM 隔离。

## 架构概览

```
用户浏览器
    ↓ HTTPS
CloudFront (CDN + WAF)
    ↓
ALB (internet-facing, shared)
    ↓ path-based routing
┌──────────────────────────────┬─────────────────────────────────┐
│  Provisioning Service        │  OpenClaw Instance (per-user)   │
│  /login /register /dashboard │  /instance/<user_id>            │
│  /provision /status /billing │  WebSocket (gateway UI)         │
│  Flask + PostgreSQL          │  OpenClaw + gateway-proxy       │
│  (3 replicas, m6g.xlarge)    │  + billing-sidecar              │
└──────────────────────────────┴─────────────────────────────────┘
                                        ↓
                               Amazon Bedrock / SiliconFlow
```

### 两种运行时

| | Standard (runc) | Secure VM (Kata) |
|---|---|---|
| **隔离** | Linux namespace | Firecracker/QEMU microVM |
| **节点** | m6g.xlarge (标准) | c6g.metal (裸金属) |
| **存储** | EFS (共享) | EBS gp3 (独占) |
| **适用** | 普通用户 | 高安全要求 |

## 前置条件

- AWS 账号，已配置 CLI (`aws configure`)
- 工具：`eksctl` ≥ 0.176、`kubectl` ≥ 1.34、`helm` ≥ 3.12、`docker`
- 区域：`us-east-1`（需要 Bedrock model access）
- EC2 实例或 Cloud9（推荐 ARM64，用于构建镜像）

## 快速部署（4 步）

### 第 1 步：创建 EKS 集群 + 基础设施（~25 分钟）

```bash
cd eksctl-deployment/scripts

# 创建 EKS 集群 + VPC + 节点组
./01-deploy-eks-cluster.sh

# 安装控制器：Pod Identity Agent、EFS CSI、AWS LB Controller、Kata
./02-deploy-controllers.sh

# （可选）配置 Karpenter 自动扩缩
./03-deploy-karpenter-resources.sh

# 验证部署状态
./04-verify-deployment.sh
```

创建的资源：
- EKS 1.34 集群 (`openclaw-prod`)
- 2× m6g.xlarge 标准节点
- 1× c6g.metal 裸金属节点（Kata 用）
- EFS 文件系统 + StorageClass
- Kata Containers + RuntimeClass (`kata-qemu`, `kata-fc`)

### 第 2 步：部署应用栈（~10 分钟）

```bash
# 一键部署：Operator + IAM + DB + 应用 + ALB + CloudFront
./05-deploy-application-stack-db.sh
```

这个脚本自动完成 9 个步骤：

| 步骤 | 内容 |
|------|------|
| 1 | 安装 OpenClaw Operator (Helm) |
| 2 | 创建 Bedrock IAM Policy + Role |
| 2.5 | 创建 Provisioning Service IAM Role |
| 3 | 配置 Pod Identity Association |
| 4 | 构建 + 推送 Docker 镜像 |
| 5 | 部署 PostgreSQL 数据库 |
| 6 | 部署 Provisioning Service (Flask) |
| 7 | 创建 Shared ALB (Internet-facing) |
| 8 | 创建 CloudFront Distribution |
| 9 | 更新服务配置（CloudFront URL） |

### 第 3 步：获取访问 URL

脚本完成后会输出 CloudFront URL：

```bash
# 查看 CloudFront 域名
aws cloudfront list-distributions --query 'DistributionList.Items[0].DomainName' --output text
```

### 第 4 步：使用平台

1. 打开 `https://<cloudfront-domain>/register` 注册账号
2. 登录后进入 Dashboard
3. 点击 **Create Instance** → 选择 Provider / Model / Runtime
4. 等待实例启动（~30 秒）
5. 点击 **Connect** 打开 OpenClaw Gateway UI

## 功能特性

### 多模型支持

**Amazon Bedrock：**
- Claude Sonnet 4.5（默认）
- Claude Opus 4
- Claude Haiku 3.5
- Llama 3.3 70B
- Amazon Nova Pro

**SiliconFlow（中国区）：**
- DeepSeek V3 / R1
- Qwen 2.5 72B / Coder 32B

### Billing 用量追踪

每个实例自动注入 billing-sidecar，实时采集：
- Token 用量（input/output）
- API 调用次数
- 按模型分类统计

Dashboard 展示实时用量数据。

### 安全隔离

- **Namespace 隔离** — 每用户独立 namespace
- **NetworkPolicy** — 默认 deny-all
- **RBAC** — 最小权限
- **Pod Security** — non-root, drop ALL capabilities
- **Kata VM**（可选）— 硬件级虚拟化隔离

## 项目结构

```
.
├── eksctl-deployment/
│   ├── scripts/
│   │   ├── 01-deploy-eks-cluster.sh          # 创建 EKS 集群
│   │   ├── 02-deploy-controllers.sh          # 安装控制器
│   │   ├── 03-deploy-karpenter-resources.sh  # Karpenter（可选）
│   │   ├── 04-verify-deployment.sh           # 验证部署
│   │   ├── 05-deploy-application-stack-db.sh         # 部署应用栈 ⭐
│   │   ├── 07-cleanup-application-stack.sh   # 清理应用栈
│   │   ├── 07-cleanup-all-resources.sh       # 清理所有资源
│   │   └── build-and-push-image.sh           # 构建推送镜像
│   └── templates/                            # K8s / CloudFront 模板
├── eks-pod-service/                          # Provisioning Service
│   ├── app/
│   │   ├── api/                              # REST API (Flask)
│   │   │   ├── auth.py                       # 注册/登录
│   │   │   ├── provision.py                  # 创建实例
│   │   │   ├── status.py                     # 实例状态
│   │   │   ├── models.py                     # 模型列表
│   │   │   └── billing.py                    # 用量查询
│   │   ├── k8s/                              # K8s 操作
│   │   │   └── instance.py                   # OpenClawInstance CRD 构建
│   │   ├── static/                           # 前端资源
│   │   └── templates/                        # HTML 模板
│   ├── Dockerfile
│   └── requirements.txt
├── kata-deployment/                          # Kata 部署配置
├── openclaw-operator/                        # Operator 源码（已支持 runtimeClassName）
└── docs/                                     # 项目文档
```

## 日常操作

### 清理 + 重新部署（可重复执行）

```bash
# 清理应用栈（保留 EKS 集群和控制器）
./07-cleanup-application-stack.sh

# 重新部署
./05-deploy-application-stack-db.sh
```

### 查看实例

```bash
# 列出所有 OpenClaw 实例
kubectl get openclawinstance -A

# 查看某个实例的 Pod 状态
kubectl get pods -n openclaw-<user_id>

# 查看 OpenClaw 日志
kubectl logs -n openclaw-<user_id> openclaw-<user_id>-0 -c openclaw

# 查看 billing sidecar 日志
kubectl logs -n openclaw-<user_id> openclaw-<user_id>-0 -c billing-sidecar
```

### 构建 + 推送镜像

```bash
# 更新 Provisioning Service
cd eks-pod-service
docker build -t <ecr-repo>/openclaw-provisioning:latest .
docker push <ecr-repo>/openclaw-provisioning:latest
kubectl rollout restart deployment/openclaw-provisioning -n openclaw-provisioning
```

## 故障排查

| 问题 | 排查 |
|------|------|
| Pod 卡在 Pending | `kubectl describe pod` 看 Events，检查节点资源 |
| Bedrock 403 | 检查 IAM Role 和 Pod Identity Association |
| WebSocket 1006 | 检查 CloudFront → ALB → Pod 链路 |
| Dashboard 500 | `kubectl logs -n openclaw-provisioning -l app=openclaw-provisioning` |
| Kata Pod 启动慢 | 正常（VM 启动 ~15s），检查 `kubectl get runtimeclass` |
| CloudFront 404 | 需要 invalidation: `aws cloudfront create-invalidation` |

## 技术栈

- **计算**: Amazon EKS 1.34, Graviton (ARM64), Kata Containers 3.27
- **AI**: Amazon Bedrock (Claude/Llama/Nova), SiliconFlow (DeepSeek/Qwen)
- **网络**: ALB + CloudFront (HTTPS + WebSocket)
- **存储**: EFS (共享), EBS gp3 (Kata), PostgreSQL
- **安全**: Pod Identity, NetworkPolicy, RBAC, Kata VM 隔离
- **运维**: Helm, eksctl, Karpenter

## 许可证

Apache 2.0 — 详见 [LICENSE](openclaw-operator/LICENSE)
