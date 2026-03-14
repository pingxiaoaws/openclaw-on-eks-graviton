# OpenClaw on EKS - E2E Testing Suite

This directory contains the end-to-end testing framework for validating the complete OpenClaw on EKS deployment.

## Overview

The testing suite orchestrates a complete deployment test from cluster creation to cleanup, automatically validating each phase and generating a comprehensive test report.

## Quick Start

### Automated Test (Recommended)

Run the complete test suite with a single command:

```bash
# Standard cluster test (recommended first)
./run-e2e-test.sh standard

# Kata cluster test (extended)
./run-e2e-test.sh kata
```

The test runner will:
1. Execute all deployment scripts in sequence
2. Run validation checks after each phase
3. Generate a detailed test report
4. Optionally clean up all resources

### Manual Test

If you prefer to run phases individually:

```bash
# Phase 1: EKS Cluster
cd ../scripts
./01-deploy-eks-cluster.sh
cd ../testing
./validate-phase1.sh

# Phase 2: Infrastructure Controllers
cd ../scripts
./02-deploy-controllers.sh
cd ../testing
./validate-phase2.sh

# Phase 3: Verification
cd ../scripts
./03-verify-deployment.sh

# Phase 4: Application Stack
cd ../scripts
./04-deploy-application-stack.sh
cd ../testing
./validate-phase4.sh

# Phase 5: End-User Access
./test-user-access.sh

# Phase 6: OpenClaw Instance
./create-test-instance.sh [standard|kata]

# Phase 7: Cleanup
cd ../scripts
./06-cleanup-all-resources.sh
```

## Files

### Main Test Scripts

- **`run-e2e-test.sh`** - Main test orchestration script
  - Runs all phases in sequence
  - Executes validation after each phase
  - Generates test report
  - Handles test failures gracefully

### Validation Scripts

- **`validate-phase1.sh`** - Validates EKS cluster creation
  - Checks cluster accessibility
  - Verifies all nodes are Ready
  - Validates system DaemonSets
  - Checks Kata node labels (if applicable)

- **`validate-phase2.sh`** - Validates infrastructure controllers
  - EFS CSI Driver and FileSystem
  - ALB Controller
  - Pod Identity agent
  - Kata installation (if applicable)

- **`validate-phase4.sh`** - Validates application stack
  - OpenClaw Operator
  - Bedrock IAM resources
  - Cognito User Pool
  - Provisioning Service with correct env vars
  - CloudFront distribution

### Helper Scripts

- **`test-user-access.sh`** - Creates test user and validates dashboard access
  - Creates Cognito test user
  - Provides manual testing instructions
  - Validates CloudFront endpoints

- **`create-test-instance.sh`** - Creates and validates OpenClaw instance
  - Creates test namespace and instance
  - Validates StatefulSet, Pod, PVC
  - Checks EFS mount
  - Verifies runtime configuration (Kata vs runc)

### Documentation

- **`E2E-TEST-PLAN.md`** - Complete test plan documentation
  - Detailed validation steps for each phase
  - Troubleshooting guide
  - Success criteria
  - Timeline estimates

- **`test-report-template.md`** - Template for manual test reports
  - Use this if running tests manually
  - Comprehensive checklist for all phases
  - Sections for notes and observations

- **`README.md`** - This file

## Test Reports

Automated test reports are saved in `./reports/`:

```bash
./reports/test-report-standard-20260313-143022.md
./reports/test-report-kata-20260313-153045.md
```

## Prerequisites

### Required Tools

```bash
eksctl version          # >= 0.191.0
kubectl version         # >= 1.30
aws --version           # >= 2.x
docker --version        # >= 20.x
jq --version            # >= 1.6
```

### AWS Permissions

Required IAM permissions:
- EKS cluster management (`eks:*`)
- VPC and networking (`ec2:*`)
- IAM role creation (`iam:*`)
- EFS management (`elasticfilesystem:*`)
- Cognito management (`cognito-idp:*`)
- CloudFront management (`cloudfront:*`)
- ECR access (`ecr:*`)

### Cost Awareness

**Standard Cluster Test**:
- Duration: ~1.5-2 hours
- Cost: ~$5-10

**Kata Cluster Test**:
- Duration: ~2-2.5 hours
- Cost: ~$30

## Test Scenarios

### Scenario 1: Standard Cluster

**Purpose**: Test most common deployment path

**Configuration**:
- 2x m6g.xlarge nodes (ARM64)
- containerd runtime (runc)
- Amazon Linux 2023

**What's Tested**:
- EKS cluster creation
- EFS + ALB + Pod Identity
- OpenClaw Operator
- Cognito + CloudFront
- Provisioning Service
- Instance creation
- Complete cleanup

### Scenario 2: Kata Cluster

**Purpose**: Test VM-level isolation

**Configuration**:
- 2x m6g.xlarge (standard workloads)
- 1x c6g.metal (Kata workloads)
- Ubuntu 24.04 on Kata nodes

**Prerequisites**:
- SSH key `openclaw-kata-key` must exist in target region

**Additional Tests**:
- Kata Containers installation
- VM kernel isolation
- OpenClaw in Kata Container
- EFS persistence in VM

## Validation Checklist

Each phase has specific validation criteria:

### Phase 1: EKS Cluster
- ✅ Cluster accessible
- ✅ All nodes Ready
- ✅ System DaemonSets running
- ✅ EBS CSI Controller ready
- ✅ (Kata) Kata nodes labeled

### Phase 2: Infrastructure
- ✅ EFS CSI Driver deployed
- ✅ EFS FileSystem available
- ✅ StorageClass created
- ✅ ALB Controller ready
- ✅ Pod Identity agent running
- ✅ (Kata) Kata runtime working

### Phase 4: Application Stack
- ✅ Operator deployed
- ✅ Bedrock IAM configured
- ✅ Cognito created
- ✅ Provisioning Service has ALL env vars
- ✅ ALB is internet-facing
- ✅ CloudFront deployed

### Phase 5: User Access
- ✅ Test user created
- ✅ Login page accessible
- ✅ Authentication works
- ✅ Dashboard loads
- ✅ No console errors

### Phase 6: Instance Creation
- ✅ Namespace created
- ✅ Instance Running and Ready
- ✅ Pod Running
- ✅ PVC Bound to EFS
- ✅ EFS mounted
- ✅ (Kata) VM kernel verified

### Phase 7: Cleanup
- ✅ Cluster deleted
- ✅ CloudFront deleted
- ✅ Cognito deleted
- ✅ IAM resources deleted
- ✅ No orphaned resources

## Test Success Criteria

**Test PASSES if**:
- ✅ All phases complete without errors
- ✅ All validation scripts pass
- ✅ Provisioning Service has correct environment variables
- ✅ CloudFront accessible via HTTPS
- ✅ User can login to dashboard
- ✅ OpenClaw instance runs successfully
- ✅ Cleanup removes all resources

**Test FAILS if**:
- ❌ Any script exits with error
- ❌ Missing environment variables
- ❌ CloudFront returns 502/503
- ❌ Authentication fails
- ❌ Instance creation fails
- ❌ Orphaned resources after cleanup

## Troubleshooting

### Test Fails at Phase 1

**Likely causes**:
- AWS permissions insufficient
- eksctl version too old
- Region capacity constraints

**Debug**:
```bash
aws sts get-caller-identity
eksctl version
aws eks describe-cluster --name <cluster> --region <region>
```

### Test Fails at Phase 4

**Likely causes**:
- Missing environment variables
- Cognito creation failed
- CloudFront creation timeout

**Debug**:
```bash
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning
kubectl get deployment openclaw-provisioning -n openclaw-provisioning -o yaml
aws cognito-idp list-user-pools --max-results 60 --region <region>
```

### Test Fails at Phase 6

**Likely causes**:
- Operator not working
- PVC provisioning failed
- Kata runtime issue (if Kata test)

**Debug**:
```bash
kubectl logs -n openclaw-operator-system deployment/openclaw-operator
kubectl describe openclawinstance -n openclaw-<user-id>
kubectl describe pod -n openclaw-<user-id>
```

### General Debugging

```bash
# Check all events
kubectl get events -A --sort-by='.lastTimestamp' | tail -20

# Check operator logs
kubectl logs -n openclaw-operator-system deployment/openclaw-operator --tail=100

# Check provisioning service logs
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=100

# Check specific phase validation
./validate-phase1.sh
./validate-phase2.sh
./validate-phase4.sh
```

## Manual Testing

If automated test fails, you can run phases manually:

1. Review `E2E-TEST-PLAN.md` for detailed steps
2. Use `test-report-template.md` to document results
3. Run validation scripts after each phase
4. Check logs if validation fails

## CI/CD Integration

To integrate tests into CI/CD:

```yaml
# Example GitHub Actions workflow
name: E2E Test
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Run E2E Test
        run: |
          cd open-claw-operator-on-EKS-kata/eksctl-deployment/testing
          ./run-e2e-test.sh standard
      - name: Upload Test Report
        uses: actions/upload-artifact@v2
        with:
          name: test-report
          path: open-claw-operator-on-EKS-kata/eksctl-deployment/testing/reports/
```

## Contributing

When adding new test scenarios:

1. Update `E2E-TEST-PLAN.md` with new test details
2. Add validation logic to appropriate `validate-phaseX.sh`
3. Update this README with new test scenario documentation
4. Test the new scenario end-to-end
5. Update `test-report-template.md` if needed

## Support

- **Issues**: Report issues with test scripts in project issue tracker
- **Documentation**: See `E2E-TEST-PLAN.md` for complete documentation
- **Deployment Guide**: See `../README.md` for deployment information
- **Architecture**: See project `CLAUDE.md` for architecture details

---

**Last Updated**: 2026-03-13
**Maintained By**: Claude Code
