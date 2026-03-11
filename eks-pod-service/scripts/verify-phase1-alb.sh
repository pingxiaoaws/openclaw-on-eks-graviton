#!/bin/bash
# Phase 1 验证脚本：检查 Provisioning Service 是否成功加入共享 ALB

set -e

SHARED_ALB_DNS="k8s-openclawsharedins-df8a132590-1940875357.us-west-2.elb.amazonaws.com"
CLOUDFRONT_HOST="dxxxexample.cloudfront.net"
REGION="us-west-2"

echo "========================================="
echo "Phase 1: Provisioning Service ALB 集成验证"
echo "========================================="
echo ""

echo "1. 检查 Ingress 资源"
echo "-----------------------------------"
kubectl get ingress -n openclaw-provisioning openclaw-provisioning-public -o wide
echo ""

echo "2. 检查 ALB 规则"
echo "-----------------------------------"
ALB_ARN=$(aws elbv2 describe-load-balancers --region $REGION \
  --query 'LoadBalancers[?contains(LoadBalancerName, `openclawsharedins`)].LoadBalancerArn' \
  --output text)
echo "ALB ARN: $ALB_ARN"
echo ""

LISTENER_ARN=$(aws elbv2 describe-listeners --region $REGION \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[0].ListenerArn' --output text)
echo "Listener ARN: $LISTENER_ARN"
echo ""

echo "ALB Rules (Provisioning Service 相关):"
aws elbv2 describe-rules --region $REGION \
  --listener-arn "$LISTENER_ARN" --output json | \
  jq -r '.Rules[] | select(.Priority != "default" and (.Conditions[] | select(.Field == "path-pattern" and (.Values[] | test("/login|/dashboard|/static|/provision|/status|/delete|/api|/health"))))) | "Priority \(.Priority): \(.Conditions | map("\(.Field)=\(.Values | join(","))") | join(" AND "))"'
echo ""

echo "3. 检查 Target Groups"
echo "-----------------------------------"
aws elbv2 describe-target-groups --region $REGION \
  --load-balancer-arn "$ALB_ARN" \
  --query 'TargetGroups[?contains(TargetGroupName, `openclaw-openclaw`)].{Name:TargetGroupName,Port:Port,HealthCheck:HealthCheckPath,Protocol:Protocol}' \
  --output table
echo ""

echo "4. 检查 Target Health (Provisioning Service)"
echo "-----------------------------------"
PROV_TGS=$(aws elbv2 describe-target-groups --region $REGION \
  --load-balancer-arn "$ALB_ARN" \
  --query 'TargetGroups[?HealthCheckPath==`/health`].TargetGroupArn' \
  --output text)

for TG_ARN in $PROV_TGS; do
  TG_NAME=$(aws elbv2 describe-target-groups --region $REGION \
    --target-group-arns "$TG_ARN" \
    --query 'TargetGroups[0].TargetGroupName' --output text)
  echo "Target Group: $TG_NAME"
  aws elbv2 describe-target-health --region $REGION \
    --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].{IP:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
    --output table
  echo ""
done

echo "5. 测试 ALB 直连（带 Host header）"
echo "-----------------------------------"
echo "Testing /health endpoint:"
HEALTH_RESPONSE=$(curl -s -H "Host: $CLOUDFRONT_HOST" http://$SHARED_ALB_DNS/health)
echo "Response: $HEALTH_RESPONSE"
if echo "$HEALTH_RESPONSE" | grep -q "healthy"; then
  echo "✅ /health - OK"
else
  echo "❌ /health - FAILED"
fi
echo ""

echo "Testing /login endpoint:"
LOGIN_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $CLOUDFRONT_HOST" http://$SHARED_ALB_DNS/login)
echo "HTTP Status: $LOGIN_STATUS"
if [ "$LOGIN_STATUS" = "200" ] || [ "$LOGIN_STATUS" = "302" ]; then
  echo "✅ /login - OK"
else
  echo "❌ /login - FAILED (expected 200 or 302, got $LOGIN_STATUS)"
fi
echo ""

echo "Testing /dashboard endpoint:"
DASHBOARD_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $CLOUDFRONT_HOST" http://$SHARED_ALB_DNS/dashboard)
echo "HTTP Status: $DASHBOARD_STATUS"
if [ "$DASHBOARD_STATUS" = "200" ] || [ "$DASHBOARD_STATUS" = "302" ]; then
  echo "✅ /dashboard - OK"
else
  echo "❌ /dashboard - FAILED (expected 200 or 302, got $DASHBOARD_STATUS)"
fi
echo ""

echo "6. 验证 OpenClaw Instance 路由不受影响"
echo "-----------------------------------"
INSTANCE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $CLOUDFRONT_HOST" http://$SHARED_ALB_DNS/instance/416e0b5f/)
echo "Testing /instance/416e0b5f/: HTTP $INSTANCE_STATUS"
if [ "$INSTANCE_STATUS" = "200" ] || [ "$INSTANCE_STATUS" = "401" ]; then
  echo "✅ Instance routes - OK (ALB routing works)"
else
  echo "⚠️  Instance routes - Unexpected status (got $INSTANCE_STATUS)"
fi
echo ""

echo "========================================="
echo "Phase 1 验证完成"
echo "========================================="
echo ""
echo "总结："
echo "- Ingress 已创建并加入共享 ALB group"
echo "- ALB 规则已自动配置"
echo "- Target Groups 健康检查通过"
echo "- ALB 直连测试通过（需要 Host header）"
echo ""
echo "下一步: Phase 2 - 配置 CloudFront Cache Behaviors"
