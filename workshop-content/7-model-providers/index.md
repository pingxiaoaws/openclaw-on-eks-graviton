---
title: "模型提供商配置"
weight: 80
---

# 配置多模型提供商

## 支持的模型提供商

本平台支持多种 AI 模型提供商，用户可根据需求灵活选择：

| 提供商 | 支持模型 | 认证方式 | 数据驻留 |
|--------|----------|----------|----------|
| **Amazon Bedrock** | Claude Sonnet 4, Claude Opus 4, Claude Haiku | EKS Pod Identity | AWS 网络内 |
| **SiliconFlow** | DeepSeek, Qwen 等 | API Key | 第三方 |
| **OpenAI** | GPT-4o, GPT-4 | API Key | 第三方 |

## 配置 Amazon Bedrock

### 启用 Bedrock 模型访问

```bash
# 在 Bedrock Console 中启用模型访问（或通过 CLI）
# us-west-2 区域，启用 Claude 模型
aws bedrock list-foundation-models \
  --region us-west-2 \
  --query 'modelSummaries[?contains(modelId, `claude`)].{ID:modelId, Name:modelName}' \
  --output table
```

### Pod Identity 工作原理

```
OpenClaw Pod (namespace: openclaw-{user_id})
  ↓ ServiceAccount: openclaw-{user_id}
  ↓
EKS Pod Identity Agent (DaemonSet)
  ↓ 查找 Pod Identity Association
  ↓
AWS STS → AssumeRole
  ↓ IAM Role: openclaw-bedrock-shared
  ↓
Amazon Bedrock API
  ↓ bedrock:InvokeModel
  ↓
Claude Sonnet / Opus / Haiku
```

{{% notice tip %}}
**零凭证管理**：使用 Pod Identity 后，OpenClaw Pod 无需硬编码任何 AWS Access Key。凭证由 EKS 自动注入，自动轮转。
{{% /notice %}}

### 创建 Bedrock 配置 Secret

```bash
# 为 Bedrock 用户创建 OpenClaw 配置
kubectl create secret generic openclaw-bedrock-config \
  --namespace openclaw-system \
  --from-literal=OPENCLAW_AI_PROVIDER=amazon-bedrock \
  --from-literal=OPENCLAW_AI_MODEL=us.anthropic.claude-sonnet-4-20250514-v1:0 \
  --from-literal=AWS_REGION=us-west-2
```

## 配置 SiliconFlow

### 创建 API Key Secret

```bash
# 替换为您的 SiliconFlow API Key
kubectl create secret generic openclaw-siliconflow-config \
  --namespace openclaw-system \
  --from-literal=OPENCLAW_AI_PROVIDER=siliconflow \
  --from-literal=OPENCLAW_AI_MODEL=deepseek-ai/DeepSeek-V3 \
  --from-literal=SILICONFLOW_API_KEY=sk-your-api-key-here
```

{{% notice warning %}}
API Key 是敏感信息，请勿提交到版本控制。生产环境建议使用 AWS Secrets Manager + External Secrets Operator。
{{% /notice %}}

## 在 Provisioning Service 中选择模型

当用户通过 Dashboard 创建实例时，Provisioning Service 根据用户选择的模型提供商，创建不同的 Secret 和 Pod Identity 配置：

```python
# 简化的 Provisioning 逻辑
if provider == "bedrock":
    # 1. 创建 ServiceAccount
    # 2. 创建 Pod Identity Association → 共享 Bedrock Role
    # 3. 创建 OpenClawInstance (envFrom: bedrock-config secret)
elif provider == "siliconflow":
    # 1. 创建包含 API Key 的 Secret
    # 2. 创建 OpenClawInstance (envFrom: siliconflow-config secret)
```

## 验证模型访问

```bash
# 测试 Bedrock 访问（从 Provisioning Service Pod 内）
kubectl exec -n openclaw-provisioning deployment/openclaw-provisioning -- \
  python3 -c "
import boto3
client = boto3.client('bedrock-runtime', region_name='us-west-2')
response = client.invoke_model(
    modelId='us.anthropic.claude-sonnet-4-20250514-v1:0',
    body='{\"anthropic_version\":\"bedrock-2023-05-31\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'
)
print('✅ Bedrock access OK')
"
```

## 下一步

模型配置完成，接下来配置弹性扩展和存储。
