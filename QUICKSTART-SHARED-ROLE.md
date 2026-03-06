# Quick Start: Shared IAM Role Deployment

**Goal**: Deploy shared IAM role architecture for OpenClaw provisioning

**Time**: ~15 minutes

---

## Prerequisites

- AWS CLI configured with admin access
- kubectl configured for EKS cluster `test-s4`
- SSH access to build server (44.252.48.166)

---

## Step-by-Step Guide

### 1. Setup AWS Resources (5 minutes)

```bash
cd /Users/pingxiao/aws-workspace/kata-open-claw/open-claw-operator-on-EKS-kata

# Create shared IAM roles and Pod Identity associations
./setup-shared-bedrock-role.sh
```

**Expected Output**:
```
✅ Shared Bedrock Role: arn:aws:iam::970547376847:role/openclaw-bedrock-shared
✅ Provisioning Service Role: arn:aws:iam::970547376847:role/openclaw-provisioning-service
✅ Pod Identity Association: a-xxxxx
```

### 2. Deploy Updated Code (10 minutes)

```bash
# Deploy provisioning service with shared role support
./deploy-shared-role-provisioning.sh

# When prompted for commit message, press Enter to use default
```

**Expected Output**:
```
✅ Build complete!
✅ Deployment rolled out
✅ Pods ready: 2/2
```

### 3. Verify Setup (2 minutes)

```bash
# Run verification checks
./verify-shared-role.sh
```

**Expected Output**: All checks pass with ✅

### 4. Test New User Creation (3 minutes)

**Via Dashboard**:
1. Open https://d3ik6njnl847zd.cloudfront.net/dashboard
2. Login with Cognito credentials
3. Click "Create Instance"
4. Select "AWS Bedrock" provider
5. Wait for instance to be created

**Monitor Logs**:
```bash
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning -f
```

**Expected Logs**:
```
INFO - 🔐 Using shared Bedrock IAM Role: arn:aws:iam::970547376847:role/openclaw-bedrock-shared
INFO - 🔗 Creating Pod Identity Association: openclaw-xxx/openclaw-xxx → arn:aws:...
INFO - ✅ Pod Identity Association created: a-xxxxx
```

### 5. Verify No IAM Roles Created

```bash
# Should return empty or only old roles (no new ones)
aws iam list-roles --query 'Roles[?starts_with(RoleName, `openclaw-user-`)].RoleName' --output table
```

---

## Quick Verification Commands

```bash
# Check provisioning service status
kubectl get deployment -n openclaw-provisioning

# Check environment variables
kubectl exec -n openclaw-provisioning deployment/openclaw-provisioning -- \
  env | grep -E "(SHARED_BEDROCK_ROLE|CREATE_IAM_ROLE)"

# List Pod Identity Associations
aws eks list-pod-identity-associations \
  --cluster-name test-s4 \
  --region us-west-2 \
  --output table
```

---

## Troubleshooting

### If deployment fails:

```bash
# Check logs
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=50

# Restart deployment
kubectl rollout restart deployment/openclaw-provisioning -n openclaw-provisioning
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning
```

### If setup script fails:

```bash
# Verify AWS credentials
aws sts get-caller-identity

# Check if roles already exist (OK to re-run script)
aws iam get-role --role-name openclaw-bedrock-shared
aws iam get-role --role-name openclaw-provisioning-service
```

---

## Optional: Migrate Existing Users

**Warning**: This will restart all existing OpenClaw pods.

```bash
# Migrate existing users to shared role
./migrate-existing-users.sh

# Type 'yes' when prompted
```

---

## Rollback (if needed)

```bash
# Quick rollback: switch to per-user mode
kubectl set env deployment/openclaw-provisioning \
  -n openclaw-provisioning \
  CREATE_IAM_ROLE_PER_USER=true

kubectl rollout restart deployment/openclaw-provisioning -n openclaw-provisioning
```

---

## Success Criteria

- ✅ No errors in provisioning service logs
- ✅ New users create Pod Identity Association only (no IAM role)
- ✅ Pods can access Bedrock API
- ✅ `SHARED_BEDROCK_ROLE_ARN` environment variable set correctly
- ✅ `CREATE_IAM_ROLE_PER_USER=false` in pod

---

## Files Modified

**Code**:
- `eks-pod-service/app/config.py` - Added shared role config
- `eks-pod-service/app/api/provision.py` - Use shared role instead of creating per-user role
- `eks-pod-service/app/api/delete.py` - Skip IAM role deletion

**Configuration**:
- `eks-pod-service/kubernetes/deployment.yaml` - Added environment variables

**New Scripts**:
- `setup-shared-bedrock-role.sh` - AWS resource setup
- `deploy-shared-role-provisioning.sh` - Build and deploy
- `verify-shared-role.sh` - Verification checks
- `migrate-existing-users.sh` - Migrate existing users
- `SHARED-ROLE-IMPLEMENTATION.md` - Full documentation

---

For detailed information, see: [SHARED-ROLE-IMPLEMENTATION.md](./SHARED-ROLE-IMPLEMENTATION.md)
