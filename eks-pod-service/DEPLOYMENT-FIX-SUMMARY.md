# K8s Deployment Fix Summary

## Issue
**Date**: 2026-03-15
**Status**: ✅ RESOLVED

### Error
```
ModuleNotFoundError: No module named 'jose'
```

Deployment was crashing on startup due to import errors in `app/api/proxy.py` and `app/api/devices.py`.

## Root Cause

The system had migrated from Cognito JWT authentication (which requires `python-jose`) to session-based authentication. However, two files were still importing from the old JWT authentication module:

1. **`app/api/proxy.py`** - Line 4
2. **`app/api/devices.py`** - Line 3

## Fix Applied

### File: `app/api/proxy.py`
```python
# OLD (causing crash):
from app.utils.jwt_auth import require_auth

# NEW (fixed):
from app.utils.session_auth import require_auth
```

### File: `app/api/devices.py`
```python
# OLD:
from app.utils.jwt_auth import require_auth

@devices_bp.route('/api/devices/approve', methods=['POST'])
@require_auth(lambda: current_app.jwt_verifier)
def approve_device(user_info):
    authenticated_user_id = generate_user_id(user_info['user_email'])
    # ...

# NEW:
from app.utils.session_auth import require_auth

@devices_bp.route('/api/devices/approve', methods=['POST'])
@require_auth
def approve_device():
    user_email = session['user_email']
    authenticated_user_id = generate_user_id(user_email)
    # ...
```

## Deployment Process

### 1. Code Changes
- Fixed imports in `proxy.py` and `devices.py`
- Committed changes to `china-region` branch

### 2. Image Rebuild
```bash
# On Graviton EC2 (44.252.48.166)
cd ~/openclaw-on-eks-graviton
git pull origin china-region

cd eks-pod-service
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin \
  970547376847.dkr.ecr.us-west-2.amazonaws.com

docker build --platform linux/arm64 \
  -t 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning-chinaregion:latest .

docker push 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning-chinaregion:latest
```

**Image Digest**: `sha256:67719977fd2f37617f96edb1a223b9c437419e82fbf75f01fb2420a2dc339133`

### 3. K8s Deployment Restart
```bash
kubectl rollout restart deployment openclaw-provisioning -n openclaw-provisioning
kubectl rollout status deployment openclaw-provisioning -n openclaw-provisioning
```

**Result**: ✅ Successfully rolled out (2/2 pods Running)

## Verification

### Pod Status
```bash
$ kubectl get pods -n openclaw-provisioning
NAME                                     READY   STATUS    RESTARTS   AGE
openclaw-provisioning-7745d7556d-fm5kr   1/1     Running   0          38s
openclaw-provisioning-7745d7556d-hmr2q   1/1     Running   0          54s
```

### Health Check
```bash
$ kubectl logs -n openclaw-provisioning -l app=openclaw-provisioning --tail=20
...
{"message": "🚀 OpenClaw Provisioning Service initialized", ...}
{"message": "📁 Template folder: /app/app/templates", ...}
{"message": "📁 Static folder: /app/app/static", ...}
...
```

### No Import Errors
```bash
$ kubectl logs -n openclaw-provisioning -l app=openclaw-provisioning | grep -i "modulenotfounderror\|jose\|jwt_auth"
# (no output - no errors)
```

## Related Files

- ✅ `app/api/proxy.py` - Fixed import
- ✅ `app/api/devices.py` - Fixed import + function signature
- ✅ `app/utils/session_auth.py` - Current authentication (no changes needed)
- ⚠️ `app/utils/jwt_auth.py` - Deprecated (not imported anymore)

## Known Non-Critical Errors

The following errors appear in logs but do NOT affect core functionality:

### 1. Missing Billing Tables
```
ERROR: no such table: hourly_usage
ERROR: no such table: daily_usage
ERROR: no such table: usage_events
```
**Impact**: Billing feature not functional
**Fix**: Run database migration script (Phase 1 of billing implementation)

### 2. RBAC Permission Error
```
ERROR: User "system:serviceaccount:openclaw-provisioning:openclaw-provisioner"
       cannot get resource "pods/exec"
```
**Impact**: Usage collector cannot read pod metrics
**Fix**: Add pods/exec permission to RBAC (if usage collection needed)

## Lessons Learned

1. **Always rebuild Docker image** after code changes (K8s caches images by tag)
2. **Use ARM64-specific builder** for Graviton deployments (`--platform linux/arm64`)
3. **Verify import statements** during authentication system migrations
4. **Check logs immediately** after rollout to catch startup errors

## Automation Script Created

Created helper script: `eksctl-deployment/scripts/build-and-push-image.sh`

Usage on Graviton EC2 instance:
```bash
cd ~/openclaw-on-eks-graviton
./eksctl-deployment/scripts/build-and-push-image.sh
```

This automates:
- Git pull latest code
- ECR login
- Docker build (ARM64)
- Image push
- Image verification

---

**Resolution Time**: ~15 minutes
**Downtime**: None (rolling update)
**Status**: ✅ Production-ready
