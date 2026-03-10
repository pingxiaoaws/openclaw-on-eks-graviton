---
title: "概述"
weight: 10
---

# 基于 Amazon EKS 和 Graviton 构建多租户 AI Agent 平台

## Workshop 简介

在本 Workshop 中，您将学习如何基于 **Amazon EKS** 和 **AWS Graviton** 处理器，构建一个支持多租户的 **OpenClaw AI Agent** 平台。

**OpenClaw** 是一个开源的云原生 AI Agent 运行时平台，能够作为用户的个人 AI 助手，跨 Telegram、Discord、WhatsApp、Signal 等多个渠道提供服务。它不仅是聊天机器人，更是具备记忆、技能系统、浏览器自动化和代码执行能力的智能 Agent。

## 您将学到什么

通过本 Workshop，您将掌握：

- 🏗️ **Kubernetes Operator 模式**：使用自定义 CRD 声明式管理 AI Agent 生命周期
- 🔐 **多租户安全隔离**：Namespace-per-User + NetworkPolicy + ResourceQuota + Kata Containers
- 🚀 **Graviton 性价比优化**：利用 ARM64 实例降低 20-40% 计算成本
- 🌐 **前端自助服务**：CloudFront + Cognito + 共享 ALB 实现用户自助 Provisioning
- 🤖 **多模型集成**：通过 EKS Pod Identity 安全访问 Amazon Bedrock，同时支持 SiliconFlow 等第三方模型
- 📦 **弹性扩展**：Karpenter 自动伸缩 + EFS/EBS 持久化存储

## 架构总览

[请在此处插入架构图]

整体架构分为四个层次：

| 层次 | 组件 | 说明 |
|------|------|------|
| **前端接入层** | CloudFront + Cognito + ALB | CDN 加速、用户认证、路由分发 |
| **Provisioning 服务层** | Flask 应用 + EKS Pod Identity | 用户自助创建/管理 Agent 实例 |
| **Operator 控制层** | OpenClaw Kubernetes Operator | 监听 CRD 变化，自动 Reconcile 资源 |
| **Agent 运行层** | StatefulSet + PVC + NetworkPolicy | 每用户独立的 Agent Pod 和存储 |

## 目标受众

- 解决方案架构师 (Solutions Architects)
- DevOps 工程师
- 平台工程师 (Platform Engineers)
- 对 AI Agent 和 Kubernetes 感兴趣的开发者

## 预计时长

**3 小时**

| 模块 | 时长 | 说明 |
|------|------|------|
| 环境准备 | 20 分钟 | 创建 EKS 集群和 Graviton 节点 |
| 部署 Operator | 15 分钟 | 安装 CRD 和 Operator |
| Provisioning Service | 25 分钟 | 部署多租户 Provisioning 服务 |
| 前端集成 | 25 分钟 | CloudFront + Cognito + ALB |
| 运行时隔离 | 20 分钟 | 标准容器 vs Kata Containers |
| 模型配置 | 15 分钟 | Bedrock + SiliconFlow |
| 弹性扩展 | 15 分钟 | Karpenter + 存储 |
| Demo & 测试 | 15 分钟 | 端到端演示 |
| 清理资源 | 10 分钟 | 删除所有资源 |

## 费用预估

本 Workshop 使用的 AWS 资源预计费用约 **$5-10/小时**，主要包括：

- EKS 控制平面：$0.10/小时
- Graviton EC2 实例 (t4g/c6g)：$0.03-0.17/小时
- ALB：$0.02/小时
- CloudFront：按流量计费（Workshop 期间可忽略）
- EFS/EBS 存储：按使用量计费

{{% notice warning %}}
请务必在 Workshop 结束后执行 **清理资源** 步骤，避免产生不必要的费用。
{{% /notice %}}
