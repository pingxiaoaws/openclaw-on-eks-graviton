#!/bin/bash
# Phase 2: 更新 CloudFront Distribution，添加 Provisioning Service Cache Behaviors

set -e

DIST_ID="EXXXXXXXXXXXXX"
REGION="us-west-2"
CONFIG_FILE="/tmp/cloudfront-config-$(date +%s).json"
BACKUP_FILE="/tmp/cloudfront-config-backup-$(date +%s).json"

echo "========================================="
echo "Phase 2: CloudFront Distribution 更新"
echo "========================================="
echo ""

echo "1. 获取当前 CloudFront 配置"
echo "-----------------------------------"
aws cloudfront get-distribution-config --id "$DIST_ID" > "$BACKUP_FILE"
ETAG=$(jq -r '.ETag' "$BACKUP_FILE")
echo "Distribution ID: $DIST_ID"
echo "Current ETag: $ETAG"
echo "Backup saved to: $BACKUP_FILE"
echo ""

echo "2. 检查当前配置"
echo "-----------------------------------"
echo "Origins:"
jq -r '.DistributionConfig.Origins.Items[] | "  - \(.Id): \(.DomainName)"' "$BACKUP_FILE"
echo ""

echo "Current Cache Behaviors:"
CACHE_BEHAVIOR_COUNT=$(jq '.DistributionConfig.CacheBehaviors.Items | length' "$BACKUP_FILE")
if [ "$CACHE_BEHAVIOR_COUNT" = "0" ] || [ "$CACHE_BEHAVIOR_COUNT" = "null" ]; then
  echo "  - 无额外 Cache Behaviors（只有 DefaultCacheBehavior）"
else
  jq -r '.DistributionConfig.CacheBehaviors.Items[] | "  - \(.PathPattern) -> \(.TargetOriginId)"' "$BACKUP_FILE"
fi
echo ""

echo "3. 生成新配置（添加 Provisioning Service Cache Behaviors）"
echo "-----------------------------------"

# 提取 DistributionConfig
jq '.DistributionConfig' "$BACKUP_FILE" > "$CONFIG_FILE"

# 检查是否已有 origin（应该有 openclaw-shared-alb）
ORIGIN_ID=$(jq -r '.Origins.Items[0].Id' "$CONFIG_FILE")
echo "使用 Origin: $ORIGIN_ID"
echo ""

# 创建新的 Cache Behaviors
# 注意：PathPattern 从最具体到最不具体，优先级递增

cat > /tmp/new-cache-behaviors.json <<'EOF'
{
  "Items": [
    {
      "PathPattern": "/static/*",
      "TargetOriginId": "ORIGIN_ID_PLACEHOLDER",
      "ViewerProtocolPolicy": "redirect-to-https",
      "AllowedMethods": {
        "Quantity": 2,
        "Items": ["GET", "HEAD"],
        "CachedMethods": {
          "Quantity": 2,
          "Items": ["GET", "HEAD"]
        }
      },
      "Compress": true,
      "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
      "OriginRequestPolicyId": "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf"
    },
    {
      "PathPattern": "/login*",
      "TargetOriginId": "ORIGIN_ID_PLACEHOLDER",
      "ViewerProtocolPolicy": "redirect-to-https",
      "AllowedMethods": {
        "Quantity": 7,
        "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
        "CachedMethods": {
          "Quantity": 2,
          "Items": ["GET", "HEAD"]
        }
      },
      "Compress": true,
      "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
      "OriginRequestPolicyId": "216adef6-5c7f-47e4-b989-5492eafa07d3"
    },
    {
      "PathPattern": "/dashboard*",
      "TargetOriginId": "ORIGIN_ID_PLACEHOLDER",
      "ViewerProtocolPolicy": "redirect-to-https",
      "AllowedMethods": {
        "Quantity": 7,
        "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
        "CachedMethods": {
          "Quantity": 2,
          "Items": ["GET", "HEAD"]
        }
      },
      "Compress": true,
      "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
      "OriginRequestPolicyId": "216adef6-5c7f-47e4-b989-5492eafa07d3"
    },
    {
      "PathPattern": "/provision*",
      "TargetOriginId": "ORIGIN_ID_PLACEHOLDER",
      "ViewerProtocolPolicy": "redirect-to-https",
      "AllowedMethods": {
        "Quantity": 7,
        "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
        "CachedMethods": {
          "Quantity": 2,
          "Items": ["GET", "HEAD"]
        }
      },
      "Compress": true,
      "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
      "OriginRequestPolicyId": "b689b0a8-53d0-40ab-baf2-68738e2966ac"
    },
    {
      "PathPattern": "/status/*",
      "TargetOriginId": "ORIGIN_ID_PLACEHOLDER",
      "ViewerProtocolPolicy": "redirect-to-https",
      "AllowedMethods": {
        "Quantity": 7,
        "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
        "CachedMethods": {
          "Quantity": 2,
          "Items": ["GET", "HEAD"]
        }
      },
      "Compress": true,
      "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
      "OriginRequestPolicyId": "b689b0a8-53d0-40ab-baf2-68738e2966ac"
    },
    {
      "PathPattern": "/delete/*",
      "TargetOriginId": "ORIGIN_ID_PLACEHOLDER",
      "ViewerProtocolPolicy": "redirect-to-https",
      "AllowedMethods": {
        "Quantity": 7,
        "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
        "CachedMethods": {
          "Quantity": 2,
          "Items": ["GET", "HEAD"]
        }
      },
      "Compress": true,
      "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
      "OriginRequestPolicyId": "b689b0a8-53d0-40ab-baf2-68738e2966ac"
    },
    {
      "PathPattern": "/api/*",
      "TargetOriginId": "ORIGIN_ID_PLACEHOLDER",
      "ViewerProtocolPolicy": "redirect-to-https",
      "AllowedMethods": {
        "Quantity": 7,
        "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
        "CachedMethods": {
          "Quantity": 2,
          "Items": ["GET", "HEAD"]
        }
      },
      "Compress": true,
      "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
      "OriginRequestPolicyId": "b689b0a8-53d0-40ab-baf2-68738e2966ac"
    }
  ]
}
EOF

# 替换 Origin ID
sed -i.bak "s/ORIGIN_ID_PLACEHOLDER/$ORIGIN_ID/g" /tmp/new-cache-behaviors.json

# 获取现有的 Cache Behaviors 并合并
EXISTING_BEHAVIORS=$(jq '.CacheBehaviors.Items // []' "$CONFIG_FILE")
NEW_BEHAVIORS=$(jq '.Items' /tmp/new-cache-behaviors.json)

# 合并 behaviors（新的排在前面，优先级更高）
MERGED_BEHAVIORS=$(jq -n --argjson new "$NEW_BEHAVIORS" --argjson existing "$EXISTING_BEHAVIORS" '$new + $existing')

# 更新配置
jq --argjson behaviors "$MERGED_BEHAVIORS" \
  '.CacheBehaviors.Items = $behaviors | .CacheBehaviors.Quantity = ($behaviors | length)' \
  "$CONFIG_FILE" > "${CONFIG_FILE}.new"

mv "${CONFIG_FILE}.new" "$CONFIG_FILE"

echo "新配置已生成: $CONFIG_FILE"
echo "添加的 Cache Behaviors:"
jq -r '.Items[] | "  - \(.PathPattern)"' /tmp/new-cache-behaviors.json
echo ""

echo "4. 预览配置变更"
echo "-----------------------------------"
echo "Before Cache Behaviors:"
jq -r '.CacheBehaviors.Items[] | "  - \(.PathPattern) -> \(.TargetOriginId)"' "$BACKUP_FILE" | head -5 || echo "  (none)"
echo ""
echo "After Cache Behaviors:"
jq -r '.CacheBehaviors.Items[] | "  - \(.PathPattern) -> \(.TargetOriginId)"' "$CONFIG_FILE" | head -15
echo ""

read -p "确认更新 CloudFront Distribution? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "取消更新"
  exit 0
fi

echo ""
echo "5. 应用配置更新"
echo "-----------------------------------"
aws cloudfront update-distribution \
  --id "$DIST_ID" \
  --distribution-config "file://$CONFIG_FILE" \
  --if-match "$ETAG" \
  --output json > /tmp/update-result.json

NEW_ETAG=$(jq -r '.ETag' /tmp/update-result.json)
echo "✅ Distribution 更新成功"
echo "New ETag: $NEW_ETAG"
echo ""

echo "6. 等待部署完成"
echo "-----------------------------------"
echo "CloudFront 部署通常需要 5-10 分钟..."
echo "检查部署状态: aws cloudfront get-distribution --id $DIST_ID --query 'Distribution.Status'"
echo ""

STATUS=$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.Status' --output text)
echo "当前状态: $STATUS"

if [ "$STATUS" = "InProgress" ]; then
  echo ""
  echo "⏳ 部署进行中，可以在后台监控："
  echo "   watch -n 10 'aws cloudfront get-distribution --id $DIST_ID --query Distribution.Status --output text'"
  echo ""
  echo "   或者等待完成："
  echo "   aws cloudfront wait distribution-deployed --id $DIST_ID"
fi

echo ""
echo "========================================="
echo "Phase 2 完成"
echo "========================================="
echo ""
echo "配置文件："
echo "  - 备份: $BACKUP_FILE"
echo "  - 新配置: $CONFIG_FILE"
echo ""
echo "下一步: Phase 3 - 测试 CloudFront 集成"
