#!/bin/bash
export AWS_PAGER=""
# ============================================================================
# DEPRECATED: This script has been replaced by 04-deploy-application-stack.sh
# ============================================================================
#
# This file is kept for reference only and should NOT be used for new deployments.
#
# REASON: This script deploys CloudFront and Cognito separately from the
# Provisioning Service, which causes environment variable configuration issues.
# The unified script (04-deploy-application-stack.sh) ensures Cognito is created
# BEFORE the Provisioning Service starts, and CloudFront config is added via
# kubectl set env after deployment.
#
# USE INSTEAD:
#   ./04-deploy-application-stack.sh
#
# If you need to update CloudFront or Cognito after initial setup, use AWS CLI:
#
#   # Update Cognito User Pool
#   aws cognito-idp update-user-pool --user-pool-id <pool-id> ...
#
#   # Update CloudFront Distribution
#   aws cloudfront update-distribution --id <dist-id> ...
#
# ============================================================================

echo "❌ ERROR: This script is deprecated and should not be used."
echo ""
echo "Please use the unified deployment script instead:"
echo "  ./04-deploy-application-stack.sh"
echo ""
echo "See .deprecated-notice.txt for more information."
echo ""
exit 1
