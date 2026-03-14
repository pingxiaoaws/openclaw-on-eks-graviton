# End-to-End Deployment Testing Plan

**Version**: 1.0
**Date**: 2026-03-13
**Status**: Ready for execution

## Overview

This document provides a comprehensive testing plan for validating the complete OpenClaw on EKS deployment flow, from cluster creation to fully functional multi-tenant application with CloudFront public access.

## Test Objectives

1. Validate eksctl-based deployment scripts work end-to-end
2. Verify unified application stack deployment (correct environment variable order)
3. Test both Standard and Kata cluster deployment modes
4. Validate JWT authentication flow with Cognito
5. Verify CloudFront public access
6. Test OpenClaw instance creation and operation
7. Validate cleanup procedures

## Prerequisites

### Required Tools

```bash
# Verify all required tools are installed
eksctl version          # >= 0.191.0
kubectl version --client # >= 1.30
aws --version           # >= 2.x
docker --version        # >= 20.x
jq --version            # >= 1.6
```

### AWS Permissions

Required IAM permissions:
- EKS cluster creation (`eks:*`)
- VPC/networking (`ec2:*`)
- IAM role creation (`iam:*`)
- EFS management (`elasticfilesystem:*`)
- Cognito User Pool management (`cognito-idp:*`)
- CloudFront distribution management (`cloudfront:*`)
- ECR repository access (`ecr:*`)

### Cost Awareness

**Standard Cluster** (recommended for first test):
- 2x m6g.xlarge nodes: ~$380/month
- EFS storage: ~$0.30/GB-month
- ALB: ~$20/month
- CloudFront: ~$1/month (minimal traffic)
- **Test duration cost**: ~$5-10 for 2-hour test

**Kata Cluster** (extended test):
- 2x m6g.xlarge + 1x c6g.metal: ~$4,048/month
- **Test duration cost**: ~$30 for 2.5-hour test

## Quick Start

```bash
# Navigate to test directory
cd open-claw-operator-on-EKS-kata/eksctl-deployment/testing

# Run test suite (Standard cluster)
./run-e2e-test.sh standard

# Or run test suite (Kata cluster)
./run-e2e-test.sh kata

# Test report will be generated at: ./reports/test-report-<timestamp>.md
```

## Test Scenarios

### Scenario 1: Standard Cluster (Primary Test)

**Purpose**: Test most common deployment path

**Configuration**: 2x m6g.xlarge, runc runtime, ~1.5-2 hours

**What's Tested**:
- EKS cluster creation
- EFS + ALB + Pod Identity
- OpenClaw Operator
- Cognito + CloudFront
- Provisioning Service
- Instance creation (runc)
- Complete cleanup

### Scenario 2: Kata Cluster (Extended Test)

**Purpose**: Test VM-level isolation

**Configuration**: 2x m6g.xlarge + 1x c6g.metal, ~2-2.5 hours

**Prerequisites**: SSH key `openclaw-kata-key` must exist

**Additional Tests**:
- Kata Containers installation
- VM kernel isolation
- OpenClaw in Kata Container
- EFS persistence in VM

## Success Criteria

✅ **Test PASSES if**:
- All scripts complete without errors
- Provisioning Service has correct env vars
- CloudFront accessible via HTTPS
- User can login to dashboard
- OpenClaw instance runs successfully
- Cleanup removes all resources

❌ **Test FAILS if**:
- Any script error
- Missing environment variables
- CloudFront 502/503 errors
- Authentication failures
- Instance creation failures
- Orphaned resources after cleanup

## Timeline

**Standard Cluster**: ~1.5-2 hours total
**Kata Cluster**: ~2-2.5 hours total

See detailed phase-by-phase breakdown in full plan.

---

For complete testing procedures, validation steps, and troubleshooting, see the full E2E test plan documentation in this directory.
