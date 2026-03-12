# 项目结构说明

## 目录树

```
eksctl-deployment/
├── README.md                   # 完整部署指南
├── QUICKSTART.md               # 5 分钟快速开始
├── COMPARISON.md               # CloudFormation 对比
├── PROJECT-STRUCTURE.md        # 本文件
├── GETTING-STARTED.md          # 入门指南
├── IMPLEMENTATION-COMPLETE.md  # 实施报告
│
├── configs/
│   └── openclaw-cluster.yaml  # EKS 集群配置
│
├── scripts/
│   ├── 01-cleanup-cloudformation.sh
│   ├── 02-deploy-eks-cluster.sh
│   ├── 03-deploy-controllers.sh
│   └── 04-verify-deployment.sh
│
└── examples/
    └── openclaw-test-instance.yaml
```

## 文件说明

### 配置文件

**configs/openclaw-cluster.yaml** (250 行)
- EKS 1.34 集群定义
- VPC (172.31.0.0/16, Single NAT)
- Managed Node Groups (m6g.xlarge)
- Kata Node Group (c6g.metal, Ubuntu 24.04)
- EKS Add-ons (自动版本)
- Kata 自动安装 (user data)

**examples/openclaw-test-instance.yaml** (120 行)
- OpenClaw 测试实例
- Runtime: kata-qemu (EFS 支持)
- Storage: efs-sc (RWX)
- Bedrock 模型配置

### 脚本

**01-cleanup-cloudformation.sh** (80 行)
- 清理失败的 CloudFormation 栈
- 交互式确认
- 等待删除完成

**02-deploy-eks-cluster.sh** (120 行)
- Phase 1: 部署 EKS 集群
- 前提条件检查
- 20-25 分钟

**03-deploy-controllers.sh** (300 行)
- Phase 2: 安装控制器
- EFS CSI Driver + FileSystem
- ALB Controller
- RuntimeClasses
- 10-15 分钟

**04-verify-deployment.sh** (500 行)
- 全面验证 (7 项检查)
- 彩色输出
- 错误统计

### 文档

**README.md** - 完整指南
- 架构说明
- 详细步骤
- 故障排查
- 成本估算

**QUICKSTART.md** - 快速开始
- 复制粘贴命令
- 5 分钟部署
- 前提条件

**COMPARISON.md** - 对比分析
- CloudFormation 5 次失败
- eksctl 优势
- 性能对比

**GETTING-STARTED.md** - 入门
- 一键部署
- 常见问题
- 验证步骤

## 使用流程

### 首次部署

```bash
cd scripts
./01-cleanup-cloudformation.sh  # 清理旧资源
./02-deploy-eks-cluster.sh      # 部署 EKS
./03-deploy-controllers.sh      # 安装控制器
./04-verify-deployment.sh       # 验证
```

### 日常操作

```bash
# 查看集群
kubectl get nodes

# 创建实例
kubectl apply -f examples/openclaw-test-instance.yaml

# 查看日志
kubectl logs -n openclaw test-instance-0 -c openclaw
```

### 维护

```bash
# 更新配置
vim configs/openclaw-cluster.yaml

# 升级集群
eksctl upgrade cluster -f configs/openclaw-cluster.yaml

# 扩容节点
eksctl scale nodegroup --cluster=openclaw-platform --name=standard-nodes --nodes=4
```

## 文档路线图

1. 🆕 新手: GETTING-STARTED.md
2. ⚡ 快速: QUICKSTART.md
3. 📖 完整: README.md
4. 🔍 对比: COMPARISON.md
5. 📁 结构: PROJECT-STRUCTURE.md (本文件)

---
**维护者**: Claude Code
