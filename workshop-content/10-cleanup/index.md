---
title: "清理资源"
weight: 110
---

# 清理资源

{{% notice warning %}}
请务必执行以下清理步骤，避免产生不必要的 AWS 费用！
{{% /notice %}}

## 步骤 1：删除所有 OpenClaw 实例

```bash
# 删除所有 OpenClawInstance
for ns in $(kubectl get namespaces -o name | grep openclaw- | grep -v system | grep -v provisioning); do
  echo "Cleaning up $ns..."
  kubectl delete openclawinstance --all -n ${ns##*/}
  kubectl delete namespace ${ns##*/}
done
```

## 步骤 2：删除 Provisioning Service

```bash
kubectl delete namespace openclaw-provisioning
```

## 步骤 3：删除 OpenClaw Operator

```bash
# Helm 方式
helm uninstall openclaw-operator -n openclaw-system

# 删除 CRDs
kubectl delete crds openclawinstances.openclaw.rocks
kubectl delete crds openclawselfconfigs.openclaw.rocks

kubectl delete namespace openclaw-system
```

## 步骤 4：删除 CloudFront Distribution

```bash
# 先禁用
aws cloudfront update-distribution \
  --id ${DISTRIBUTION_ID} \
  --if-match $(aws cloudfront get-distribution --id ${DISTRIBUTION_ID} --query 'ETag' --output text) \
  --distribution-config "$(aws cloudfront get-distribution-config --id ${DISTRIBUTION_ID} --query 'DistributionConfig' --output json | jq '.Enabled = false')"

# 等待禁用完成
aws cloudfront wait distribution-deployed --id ${DISTRIBUTION_ID}

# 删除
aws cloudfront delete-distribution \
  --id ${DISTRIBUTION_ID} \
  --if-match $(aws cloudfront get-distribution --id ${DISTRIBUTION_ID} --query 'ETag' --output text)
```

## 步骤 5：删除 Cognito User Pool

```bash
aws cognito-idp delete-user-pool --user-pool-id ${USER_POOL_ID}
```

## 步骤 6：删除 EFS（如果创建了）

```bash
# 删除 Mount Targets
for MT_ID in $(aws efs describe-mount-targets --file-system-id ${EFS_ID} --query 'MountTargets[].MountTargetId' --output text); do
  aws efs delete-mount-target --mount-target-id $MT_ID
done

# 等待 Mount Targets 删除完成
sleep 60

# 删除文件系统
aws efs delete-file-system --file-system-id ${EFS_ID}
```

## 步骤 7：删除 IAM Roles

```bash
# 删除 Pod Identity Associations
for ASSOC_ID in $(aws eks list-pod-identity-associations --cluster-name ${CLUSTER_NAME} --query 'associations[].associationId' --output text); do
  aws eks delete-pod-identity-association \
    --cluster-name ${CLUSTER_NAME} \
    --association-id $ASSOC_ID
done

# 删除 Role Policies
aws iam delete-role-policy --role-name openclaw-provisioning-service --policy-name OpenClawProvisioningPolicy
aws iam delete-role-policy --role-name openclaw-bedrock-shared --policy-name OpenClawBedrockAccess

# 删除 Roles
aws iam delete-role --role-name openclaw-provisioning-service
aws iam delete-role --role-name openclaw-bedrock-shared
```

## 步骤 8：删除 EKS 集群

```bash
# 先删除 Karpenter
helm uninstall karpenter -n karpenter
kubectl delete namespace karpenter

# 删除集群（包括节点组、VPC 等）
eksctl delete cluster --name ${CLUSTER_NAME} --region ${AWS_REGION}
```

{{% notice info %}}
集群删除大约需要 **10-15 分钟**。
{{% /notice %}}

## 验证清理完成

```bash
# 确认集群已删除
aws eks describe-cluster --name ${CLUSTER_NAME} 2>&1 | grep -q "No cluster found" && echo "✅ Cluster deleted"

# 确认 CloudFront 已删除
aws cloudfront list-distributions --query 'DistributionList.Items[?Comment==`OpenClaw Workshop`]' --output text
# 期望: 无输出

echo "🎉 所有资源已清理完毕！感谢参加本 Workshop！"
```

---

## 🎉 恭喜完成！

您已成功完成本 Workshop，学习了：

- ✅ 使用 EKS + Graviton 构建高性价比的 Kubernetes 集群
- ✅ 部署 Kubernetes Operator 管理 AI Agent 生命周期
- ✅ 实现多租户安全隔离（Namespace / NetworkPolicy / Kata Containers）
- ✅ 通过 EKS Pod Identity 安全访问 Amazon Bedrock
- ✅ 使用 CloudFront + Cognito 构建自助 Provisioning 前端
- ✅ 配置 Karpenter 实现自动弹性伸缩

## 进一步学习

- [OpenClaw 文档](https://docs.openclaw.ai)
- [OpenClaw Kubernetes Operator](https://github.com/openclaw-rocks/k8s-operator)
- [Amazon EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [Karpenter 文档](https://karpenter.sh/)
- [Kata Containers on AWS](https://aws.amazon.com/blogs/containers/enhancing-kubernetes-workload-isolation-and-security-using-kata-containers/)
