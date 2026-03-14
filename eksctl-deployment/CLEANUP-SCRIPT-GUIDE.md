# Complete Resource Cleanup Script Guide

**Script**: `scripts/06-cleanup-all-resources.sh`
**Date**: 2026-03-13
**Status**: Production Ready ✅

## Overview

The cleanup script is a comprehensive, interactive tool that **safely and completely removes all OpenClaw platform resources** from your AWS account. It's designed to prevent accidental deletions while ensuring thorough cleanup to avoid ongoing charges.

## Key Features

### 🔍 Intelligent Resource Detection

- **Auto-detects cluster name and region** from kubectl context
- **Scans all related resources** across AWS services
- **Displays complete resource list** before deletion
- **Counts total resources** to be removed

### 🛡️ Safety Mechanisms

**Multi-level confirmation**:
1. User must confirm cluster name by typing it exactly
2. User must type "DELETE" in uppercase to proceed
3. EFS deletion requires separate confirmation (data protection)

**Resource scanning before deletion**:
- Shows exactly what will be deleted
- Displays resource details (IDs, sizes, counts)
- Allows user to verify before proceeding

### 📋 Complete Resource Coverage

**Deletes 12 resource types**:

1. **Kubernetes Resources**
   - `openclaw-provisioning` namespace
   - `openclaw-operator-system` namespace
   - All user namespaces (`openclaw-*`)
   - All deployments, services, ingresses

2. **CloudFront Distribution**
   - Automatically disables first (required by AWS)
   - Waits for deployment completion
   - Deletes distribution with proper ETag handling

3. **Cognito User Pool**
   - Deletes all clients first
   - Deletes user pool domain (if exists)
   - Deletes the user pool itself

4. **EKS Cluster**
   - Deletes all node groups
   - Deletes all managed addons
   - Deletes VPC resources (if created by eksctl)
   - Uses `eksctl delete cluster --wait`

5. **Pod Identity Associations**
   - Lists all associations for the cluster
   - Deletes each association individually

6. **IAM Resources**
   - `OpenClawBedrockRole` (with policy detachment)
   - `OpenClawBedrockAccess` policy
   - Optional: eksctl-created roles

7. **Application Load Balancer**
   - Automatically deleted when Ingress is removed
   - No manual deletion needed

8. **EFS FileSystem** (Optional)
   - **Default: PRESERVED** (to protect data)
   - Deletes all mount targets first
   - Waits for mount targets to be deleted
   - Then deletes the filesystem

9. **Security Groups**
   - `openclaw-alb-cloudfront-only` (CloudFront SG)
   - `openclaw-efs-sg` (EFS SG, if EFS deleted)

10. **CloudFormation Stack** (if exists)
    - Legacy cleanup for old deployments
    - Optional deletion with user confirmation

11. **NAT Gateway**
    - Deleted as part of VPC resources by eksctl

12. **Local Configuration**
    - kubectl context removal
    - Clean local state

### ⏱️ Deletion Order (Critical for Success)

The script deletes resources in the **correct dependency order**:

```
1. Kubernetes resources (deployments, services, ingresses)
   ↓ (triggers ALB deletion)

2. CloudFront Distribution
   ↓

3. Cognito User Pool
   ↓

4. Pod Identity Associations
   ↓ (must be deleted before cluster)

5. EKS Cluster (includes node groups, VPC, NAT Gateway)
   ↓

6. IAM Roles & Policies
   ↓

7. EFS FileSystem (optional)
   ↓

8. Security Groups
   ↓

9. CloudFormation Stack (if exists)
   ↓

10. Local kubectl context
```

**Why order matters**:
- Ingress must be deleted before ALB can be removed
- Pod Identity must be deleted before EKS cluster
- IAM roles should be deleted after cluster (to avoid access issues during cluster deletion)
- Security groups can only be deleted after all dependent resources are gone
- EFS can only be deleted after mount targets are removed

## Usage

### Basic Usage

```bash
cd scripts
./06-cleanup-all-resources.sh
```

The script will:
1. Detect configuration from kubectl context
2. Scan all resources
3. Show deletion plan
4. Request confirmation
5. Execute cleanup in correct order
6. Display final summary

### Interactive Prompts

#### 1. Configuration Detection

```
[Step 1/12] Gathering configuration...
✓ Detected from kubectl context:
  Cluster: openclaw-prod
  Region: us-east-1

Use these values? (yes/no):
```

- If "yes": Uses detected values
- If "no": Prompts for manual input

#### 2. Resource Scan

```
[Step 2/12] Scanning resources...

Resources to be deleted:

📦 Kubernetes Resources:
  ✓ openclaw-provisioning namespace
  ✓ openclaw-operator-system namespace
  ✓ 3 user namespace(s)

🌐 CloudFront:
  ✓ Distribution: E1234567890ABC

👤 Cognito:
  ✓ User Pool: us-east-1_ExAmPlE

🏗️  EKS Cluster:
  ✓ Cluster: openclaw-prod
  ✓ 2 node group(s)

🗄️  Storage:
  ✓ EFS FileSystem: fs-077bd850b7bb23b4f (15GB)

🔐 IAM Resources:
  ✓ IAM Role: OpenClawBedrockRole
  ✓ IAM Policy: OpenClawBedrockAccess

Total resources found: 12
```

#### 3. Confirmation

```
╔════════════════════════════════════════════════════════════════╗
║                    ⚠️  FINAL WARNING ⚠️                        ║
║                                                                ║
║  This will PERMANENTLY DELETE all resources listed above.     ║
║  Data stored in EFS will be LOST unless you choose to skip it.║
║  This action CANNOT be undone.                                ║
╚════════════════════════════════════════════════════════════════╝

Type the cluster name 'openclaw-prod' to confirm deletion: openclaw-prod
Are you ABSOLUTELY sure? Type 'DELETE' in uppercase: DELETE
```

#### 4. EFS Confirmation (Separate)

```
⚠️  EFS FileSystem contains persistent data
Delete EFS FileSystem? (yes/no, default: no): no
```

**Best practice**: Default is "no" to preserve data

#### 5. Optional IAM Roles

```
⚠️  Found eksctl-created roles:
  - eksctl-openclaw-prod-nodegroup-standard-nodes-NodeInstanceRole-ABC123
  - eksctl-openclaw-prod-addon-iamserviceaccount-kube-system-aws-load-balancer-controller-Role-DEF456

Delete these roles? (yes/no):
```

## Execution Time

| Phase | Duration | Notes |
|-------|----------|-------|
| Configuration | < 1 min | Interactive |
| Resource Scan | 1-2 min | API calls |
| Kubernetes Cleanup | 1-2 min | Namespace deletion |
| CloudFront Deletion | 10-15 min | **Longest step** (disable + deploy wait) |
| Cognito Deletion | < 1 min | Fast |
| EKS Cluster Deletion | 10-15 min | Node groups + VPC cleanup |
| IAM Cleanup | < 1 min | Fast |
| EFS Deletion | 2-5 min | If selected |
| Security Groups | < 1 min | Fast |
| **Total** | **15-30 min** | Mostly automated |

**Tip**: CloudFront deletion is the slowest. You can let it run in the background while you work on other tasks.

## Output Examples

### Successful Execution

```
[Step 4/12] Deleting CloudFront distribution...
Disabling distribution...
Waiting for distribution to be disabled (this may take 5-10 minutes)...
Deleting distribution...
✅ CloudFront distribution deleted

[Step 7/12] Deleting EKS cluster...
⏱️  This process typically takes 10-15 minutes...
✅ EKS cluster deleted

╔════════════════════════════════════════════════════════════════╗
║                  ✅ CLEANUP COMPLETE ✅                        ║
╚════════════════════════════════════════════════════════════════╝

✨ Cleanup complete! All resources have been removed.
```

### Resource Not Found (Safe)

```
[Step 4/12] Deleting CloudFront distribution...
No CloudFront distribution found, skipping

[Step 5/12] Deleting Cognito user pool...
No Cognito user pool found, skipping
```

**Note**: Script handles missing resources gracefully (idempotent).

### EFS Preserved

```
[Step 9/12] Deleting EFS FileSystem...
⚠️  EFS FileSystem preserved: fs-077bd850b7bb23b4f (15GB)

   To delete manually later:
   aws efs delete-file-system --file-system-id fs-077bd850b7bb23b4f --region us-east-1
```

## Cost Savings

After running the cleanup script:

### Kata Deployment (~$4,000/month savings)

| Resource | Monthly Cost |
|----------|--------------|
| EKS Control Plane | $73 |
| c6g.metal (1 Kata node) | $3,528 |
| m6g.xlarge (2 standard nodes) | $222 |
| NAT Gateway | $32 |
| ALB | $22 |
| CloudFront | ~$85 |
| EFS (100GB) | $30 |
| **Total** | **~$3,992/month** |

### Standard Deployment (~$380/month savings)

| Resource | Monthly Cost |
|----------|--------------|
| EKS Control Plane | $73 |
| m6g.xlarge (2 nodes) | $222 |
| NAT Gateway | $32 |
| ALB | $22 |
| EFS (50GB) | $15 |
| **Total** | **~$364/month** |

**Important**: Even after EKS cluster deletion, other resources (CloudFront, Cognito, EFS) may continue to incur charges if not deleted.

## Verification

After cleanup, verify all resources are gone:

### AWS Console Checks

1. **EKS**: https://console.aws.amazon.com/eks/home?region=us-east-1#/clusters
   - Should show: "No clusters"

2. **CloudFront**: https://console.aws.amazon.com/cloudfront/home
   - Filter by Comment: "OpenClaw-*"
   - Should show: "No distributions"

3. **Cognito**: https://console.aws.amazon.com/cognito/home?region=us-east-1
   - Search for "openclaw-users-*"
   - Should show: "No user pools"

4. **IAM Roles**: https://console.aws.amazon.com/iam/home#/roles
   - Search for "OpenClawBedrock"
   - Should show: "No roles"

5. **EFS**: https://console.aws.amazon.com/efs/home?region=us-east-1
   - Filter by Name: "openclaw-shared-storage"
   - Should show: "No file systems" (if deleted)

### CLI Verification

```bash
# Check EKS
aws eks describe-cluster --name openclaw-prod --region us-east-1
# Expected: ResourceNotFoundException

# Check CloudFront
aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='OpenClaw-openclaw-prod']"
# Expected: null or []

# Check Cognito
aws cognito-idp list-user-pools --max-results 60 --region us-east-1 \
  --query "UserPools[?Name=='openclaw-users-openclaw-prod']"
# Expected: null or []

# Check IAM
aws iam get-role --role-name OpenClawBedrockRole
# Expected: NoSuchEntity error

# Check EFS (if deleted)
aws efs describe-file-systems --region us-east-1 \
  --query "FileSystems[?Tags[?Key=='Name' && Value=='openclaw-shared-storage']]"
# Expected: null or []
```

## Troubleshooting

### Issue: CloudFront Deletion Fails

**Error**: `DistributionNotDisabled`

**Solution**:
```bash
# Manually disable and wait
DIST_ID=<your-distribution-id>
aws cloudfront get-distribution-config --id $DIST_ID > /tmp/config.json
jq '.DistributionConfig.Enabled = false | .DistributionConfig' /tmp/config.json > /tmp/config-disabled.json
ETAG=$(jq -r '.ETag' /tmp/config.json)
aws cloudfront update-distribution --id $DIST_ID --if-match $ETAG --distribution-config file:///tmp/config-disabled.json

# Wait for deployment
aws cloudfront wait distribution-deployed --id $DIST_ID

# Then delete
aws cloudfront get-distribution-config --id $DIST_ID > /tmp/config-new.json
ETAG=$(jq -r '.ETag' /tmp/config-new.json)
aws cloudfront delete-distribution --id $DIST_ID --if-match $ETAG
```

### Issue: EFS Deletion Fails

**Error**: `FileSystemInUse`

**Cause**: Mount targets still exist or being used

**Solution**:
```bash
# List and delete all mount targets
EFS_ID=<your-efs-id>
aws efs describe-mount-targets --file-system-id $EFS_ID --region us-east-1 \
  --query 'MountTargets[].MountTargetId' --output text | \
  xargs -n1 -I{} aws efs delete-mount-target --mount-target-id {} --region us-east-1

# Wait for deletion (check every 10 seconds)
while aws efs describe-mount-targets --file-system-id $EFS_ID --region us-east-1 2>/dev/null | grep -q MountTargetId; do
  echo "Waiting for mount targets to be deleted..."
  sleep 10
done

# Now delete EFS
aws efs delete-file-system --file-system-id $EFS_ID --region us-east-1
```

### Issue: Security Group Deletion Fails

**Error**: `DependencyViolation`

**Cause**: ENIs or other resources still using the security group

**Solution**:
```bash
# Find dependent resources
SG_ID=<your-sg-id>
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --region us-east-1 \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status,Description:Description}'

# Wait for resources to be deleted (often happens automatically)
# Or manually delete ENIs if safe
```

### Issue: IAM Role Deletion Fails

**Error**: `DeleteConflict`

**Cause**: Role still has attached policies or is being used

**Solution**:
```bash
# List and detach all policies
ROLE_NAME=OpenClawBedrockRole
aws iam list-attached-role-policies --role-name $ROLE_NAME \
  --query 'AttachedPolicies[].PolicyArn' --output text | \
  xargs -n1 -I{} aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn {}

# Delete inline policies
aws iam list-role-policies --role-name $ROLE_NAME \
  --query 'PolicyNames[]' --output text | \
  xargs -n1 -I{} aws iam delete-role-policy --role-name $ROLE_NAME --policy-name {}

# Now delete role
aws iam delete-role --role-name $ROLE_NAME
```

### Issue: No Resources Found

**Symptom**:
```
Total resources found: 0
✅ No resources found to delete
```

**Possible causes**:
1. Already cleaned up
2. Wrong cluster name or region
3. Resources in different region

**Solution**: Verify configuration and check AWS Console manually

## Safety Features

### 1. Dry-Run Mode (Not Available)

The script does NOT have a dry-run mode. Instead, it uses:
- **Resource scanning** before deletion
- **Interactive confirmation** before each destructive action
- **Detailed output** showing what will be deleted

### 2. Idempotency

Safe to run multiple times:
- ✅ Handles missing resources gracefully
- ✅ Skips already-deleted resources
- ✅ No errors if resources don't exist

### 3. Data Protection

**EFS default behavior**: PRESERVE
- User must explicitly choose to delete
- Confirmation is separate from other resources
- Clear warning about data loss

### 4. Rollback (Not Available)

**Warning**: Deletion is permanent and irreversible.
- No undo functionality
- No rollback capability
- Backup important data BEFORE running cleanup

## Comparison with Manual Cleanup

| Aspect | Manual Cleanup | Script Cleanup |
|--------|---------------|----------------|
| Time | 30-60 min | 15-30 min |
| Error Rate | High (easy to miss resources) | Low (comprehensive) |
| Complexity | High (20+ steps) | Low (1 command) |
| Dependency Order | Manual (error-prone) | Automatic (correct) |
| Confirmation | None | Multi-level |
| Cost Leaks | Common (missed resources) | Rare (thorough scan) |
| Documentation | Need to reference docs | Self-documented |

**Recommendation**: Use the script for thorough, safe, automated cleanup.

## Alternatives

### 1. Quick EKS-Only Cleanup

If you only want to delete the EKS cluster:

```bash
eksctl delete cluster --name openclaw-prod --region us-east-1
```

**Warning**: Leaves orphaned resources (CloudFront, Cognito, IAM, EFS) that continue to cost money.

### 2. AWS CloudFormation Stack Deletion

If deployed via CloudFormation (old method):

```bash
aws cloudformation delete-stack --stack-name openclaw-platform --region us-east-1
```

### 3. Manual Deletion via AWS Console

Navigate to each service and delete manually:
- Time-consuming
- Error-prone
- Easy to miss resources

## Best Practices

### Before Cleanup

1. **Backup important data** from EFS
2. **Export user data** from Cognito (if needed)
3. **Document instance configurations** for future reference
4. **Verify cluster name** is correct
5. **Take screenshots** of AWS Console for audit trail

### During Cleanup

1. **Run during off-hours** (if production)
2. **Monitor progress** (script provides detailed output)
3. **Don't interrupt** CloudFront or EKS deletion (can leave orphaned resources)
4. **Save output** to log file:
   ```bash
   ./06-cleanup-all-resources.sh 2>&1 | tee cleanup-$(date +%Y%m%d-%H%M%S).log
   ```

### After Cleanup

1. **Verify all resources deleted** (see Verification section)
2. **Check AWS billing** after 24-48 hours
3. **Remove local files** (optional):
   ```bash
   rm -rf ~/.kube/config  # If no other clusters
   ```
4. **Update documentation** if this was production

## FAQ

### Q: Can I undo the deletion?

**A**: No. Deletion is permanent. Backup data before running cleanup.

### Q: What if I want to keep some resources?

**A**: The script asks for confirmation at each major step. You can:
- Skip EFS deletion when prompted
- Skip CloudFormation deletion when prompted
- Manually delete specific resources instead of using the script

### Q: How long does cleanup take?

**A**: Typically 15-30 minutes. CloudFront (10-15 min) and EKS (10-15 min) are the slowest.

### Q: Can I run this in CI/CD?

**A**: Not recommended due to interactive prompts. For automation, use AWS CLI commands directly with proper safeguards.

### Q: What if the script fails midway?

**A**: Safe to re-run. The script is idempotent and skips already-deleted resources.

### Q: Does it delete my kubectl config?

**A**: Only the context for this cluster. Other clusters' contexts are preserved.

### Q: Will I still be charged after cleanup?

**A**: No, if ALL resources are deleted. Verify thoroughly (see Verification section).

### Q: Can I preserve CloudFront but delete everything else?

**A**: Not with the current script. You'd need to manually skip CloudFront deletion or modify the script.

---

**Maintained by**: Claude Code
**Last Updated**: 2026-03-13
**Version**: 1.0
**Status**: Production Ready ✅
