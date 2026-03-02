# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**OpenClaw Multi-Tenant Platform on EKS with Kata Containers**

A production multi-tenant AI Agent platform running on Amazon EKS, featuring:
- **VM-level isolation**: OpenClaw instances run in Kata Containers (Firecracker microVMs)
- **Multi-tenant provisioning**: Automated instance lifecycle management per user
- **Secure authentication**: Cognito JWT verification + API Gateway integration
- **ARM64 optimized**: Runs on AWS Graviton (c6g.metal) for cost efficiency

**Current deployment**: EKS cluster `test-s4` (us-west-2, k8s 1.34)

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Cognito User Pool (us-west-2_gvOCTiLQE)                            │
│                                                                       │
│  Client: f5qd2udi8508dd132d72qn7uc                                  │
└───────────────────────┬───────────────────────────────────────────┘
                        │ JWT token (idToken)
                        ↓
┌─────────────────────────────────────────────────────────────────────┐
│  API Gateway HTTP API (0qu1ls4sf5)                                  │
│  https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod       │
│                                                                       │
│  Routes:                                                              │
│  - POST /provision         → JWT auth (CognitoAuthorizer)           │
│  - GET /status/{user_id}   → JWT auth                               │
│  - DELETE /delete/{user_id}→ JWT auth                               │
│  - GET /dashboard, /login  → No auth (static pages)                 │
└───────────────────────┬───────────────────────────────────────────┘
                        │ VPC Link
                        ↓
┌─────────────────────────────────────────────────────────────────────┐
│  EKS Cluster (test-s4)                                              │
│                                                                       │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │  Namespace: openclaw-provisioning                              │ │
│  │                                                                 │ │
│  │  Deployment: openclaw-provisioning (2 replicas)                │ │
│  │  Image: 970547376847.dkr.ecr.us-west-2.amazonaws.com/         │ │
│  │         openclaw-provisioning:latest                           │ │
│  │                                                                 │ │
│  │  - Flask app with JWT verification (python-jose)               │ │
│  │  - Verifies Cognito tokens via JWKS                            │ │
│  │  - Creates Kubernetes resources per user                       │ │
│  │  - Service: ClusterIP (internal-openclaw-provisioning-...)     │ │
│  │  - Ingress: ALB (connected via VPC Link)                       │ │
│  └─────────────────────────────┬───────────────────────────────────┘ │
│                                 │ K8s API (ServiceAccount RBAC)       │
│                                 ↓                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │  Namespace: openclaw-operator-system                           │ │
│  │                                                                 │ │
│  │  Deployment: openclaw-operator                                 │ │
│  │  - Watches OpenClawInstance CRD                                │ │
│  │  - Creates StatefulSet with runtimeClassName support           │ │
│  └─────────────────────────────┬───────────────────────────────────┘ │
│                                 │ Reconciles                          │
│                                 ↓                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │  User Namespaces: openclaw-<user_id>                           │ │
│  │                                                                 │ │
│  │  Resources per user:                                            │ │
│  │  - OpenClawInstance CRD (openclaw-<user_id>)                   │ │
│  │  - StatefulSet (with runtimeClassName: kata-fc)                │ │
│  │  - PVC (10Gi gp3)                                               │ │
│  │  - Service (ClusterIP :18789)                                   │ │
│  │  - Secret (aws-credentials for Bedrock)                        │ │
│  │  - ResourceQuota, NetworkPolicy                                │ │
│  │                                                                 │ │
│  │  ┌───────────────────────────────────────────────────────────┐│ │
│  │  │  Pod: openclaw-<user_id>-0                                 ││ │
│  │  │  RuntimeClass: kata-fc                                     ││ │
│  │  │  NodeSelector: workload-type=kata                          ││ │
│  │  │                                                             ││ │
│  │  │  ┌─────────────────────────────────────────────────────┐  ││ │
│  │  │  │  Firecracker microVM                                │  ││ │
│  │  │  │  Kernel: 6.18.12 (Guest)                            │  ││ │
│  │  │  │                                                      │  ││ │
│  │  │  │  Containers:                                         │  ││ │
│  │  │  │  - openclaw (main)                                  │  ││ │
│  │  │  │  - gateway-proxy (sidecar)                          │  ││ │
│  │  │  │                                                      │  ││ │
│  │  │  │  Bedrock Model:                                      │  ││ │
│  │  │  │  bedrock/us.anthropic.claude-sonnet-4-5-20250929... │  ││ │
│  │  │  └─────────────────────────────────────────────────────┘  ││ │
│  │  └───────────────────────────────────────────────────────────┘│ │
│  │                                                                 │ │
│  └─────────────────────────────────────────────────────────────────┘ │
│                                                                       │
│  Node Group: kata-graviton-metal (c6g.metal, ARM64)                 │
│  - Kata Containers 3.27.0 + Firecracker 1.7                         │
│  - RuntimeClass: kata-fc                                             │
└─────────────────────────────────────────────────────────────────────┘
```

## Repository Structure

```
open-claw-operator-on-EKS-kata/
├── eks-pod-service/                  # Multi-tenant provisioning service (Flask)
│   ├── app/
│   │   ├── main.py                   # Flask app entry + JWT verifier init
│   │   ├── config.py                 # Cognito config, OpenClaw defaults
│   │   ├── api/                      # API endpoints
│   │   │   ├── provision.py          # POST /provision (JWT protected)
│   │   │   ├── status.py             # GET /status/<user_id> (JWT + authz)
│   │   │   ├── delete.py             # DELETE /delete/<user_id> (JWT + authz)
│   │   │   └── health.py             # GET /health (no auth)
│   │   ├── utils/
│   │   │   └── jwt_auth.py           # Cognito JWT verification (NEW)
│   │   ├── k8s/                      # K8s resource creation
│   │   │   ├── namespace.py
│   │   │   ├── instance.py           # Create OpenClawInstance CRD
│   │   │   ├── quota.py
│   │   │   └── netpol.py
│   │   └── templates/                # Frontend HTML
│   │       ├── login-new.html        # Industrial Cloud aesthetic
│   │       └── dashboard-new.html    # Instance management UI
│   ├── kubernetes/                   # Deployment manifests
│   ├── Dockerfile                    # Multi-stage Python 3.12 image
│   └── requirements.txt              # Includes python-jose[cryptography]
│
├── openclaw-operator/                # Kubernetes Operator (Go)
│   ├── api/v1alpha1/
│   │   └── openclawinstance_types.go # CRD with runtimeClassName support
│   ├── internal/resources/
│   │   └── statefulset.go            # Sets spec.runtimeClassName
│   ├── config/crd/bases/             # Generated CRD YAML
│   ├── charts/openclaw-operator/     # Helm chart
│   └── Makefile                      # make manifests, install, deploy
│
├── kata-deployment/
│   ├── kata-firecracker-deploy.yaml      # DaemonSet for Kata installation
│   └── kata-firecracker-runtimeclass.yaml # RuntimeClass: kata-fc
│
├── openclaw-deployment/
│   └── openclaw-kata-bedrock.yaml    # OpenClaw instance with Kata runtime
│
├── eksctl/
│   └── cluster-with-kata.yaml        # EKS cluster + Kata nodegroup config
│
└── docs/
    ├── DEPLOYMENT-SUCCESS.md
    ├── KATA-GRAVITON-DEPLOYMENT-SUMMARY.md
    └── KATA-QUICK-REFERENCE.md
```

## Common Commands

### Provisioning Service (eks-pod-service)

**Development cycle** (after code changes):

```bash
cd eks-pod-service

# Login to ECR
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin \
  970547376847.dkr.ecr.us-west-2.amazonaws.com

# Build and push image
docker build -t 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest .
docker push 970547376847.dkr.ecr.us-west-2.amazonaws.com/openclaw-provisioning:latest

# Restart deployment to pick up new image
kubectl rollout restart deployment openclaw-provisioning -n openclaw-provisioning
kubectl rollout status deployment openclaw-provisioning -n openclaw-provisioning

# Check logs
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning -f
```

**Local testing** (requires kubectl context):

```bash
pip install -r requirements.txt
python -m app.main  # Runs on localhost:8080
```

**Port-forward for testing**:

```bash
# Access provisioning service
kubectl port-forward -n openclaw-provisioning svc/openclaw-provisioning 8080:80

# Access specific OpenClaw instance
kubectl port-forward -n openclaw-<user_id> svc/openclaw-<user_id> 18789:18789
```

### OpenClaw Operator (openclaw-operator)

**After modifying CRD** (`api/v1alpha1/openclawinstance_types.go`):

```bash
cd openclaw-operator

# Regenerate deepcopy methods
make generate

# Regenerate CRD YAML + RBAC
make manifests

# Apply updated CRD to cluster
make install

# Verify CRD update
kubectl get crd openclawinstances.openclaw.rocks -o yaml | grep storedVersions
```

**Deploy operator** (choose one):

```bash
# Option A: Kustomize
make deploy

# Option B: Helm
helm upgrade --install openclaw-operator charts/openclaw-operator \
  --namespace openclaw-operator-system \
  --create-namespace

# Option C: Local development (runs operator on your machine)
make run
```

**Check operator**:

```bash
kubectl get deployment -n openclaw-operator-system
kubectl logs -n openclaw-operator-system deployment/openclaw-operator -f
```

### Kata Containers

**Verify Kata installation**:

```bash
# Check DaemonSet
kubectl get ds -n kata-system kata-firecracker-deploy

# Check RuntimeClass
kubectl get runtimeclass kata-fc

# Test Kata pod
kubectl run kata-test --image=busybox --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"kata-fc"}}' \
  -- sh -c "uname -r && sleep 3600"

# Verify running in Kata VM (kernel should be 6.18.x, not host kernel)
kubectl exec kata-test -- uname -r
```

### OpenClaw Instances

**Check instances**:

```bash
kubectl get openclawinstances -A
kubectl describe openclawinstance openclaw-<user_id> -n openclaw-<user_id>
```

**Verify Kata runtime**:

```bash
# Check runtimeClassName
kubectl get pod openclaw-<user_id>-0 -n openclaw-<user_id> \
  -o jsonpath='{.spec.runtimeClassName}'
# Expected: kata-fc

# Verify VM kernel
kubectl exec -n openclaw-<user_id> openclaw-<user_id>-0 -c openclaw -- uname -r
# Expected: 6.18.12 (Kata VM kernel)
```

### API Gateway Testing

**Get API endpoint**:

```bash
aws apigatewayv2 get-apis --region us-west-2 \
  --query 'Items[?Name==`openclaw-provisioning-api`].ApiEndpoint' \
  --output text
# Output: https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com
```

**Test health** (no auth required):

```bash
curl https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/health
```

**Test provision** (requires JWT token):

```bash
# Get JWT token from Cognito (example using AWS CLI)
TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id f5qd2udi8508dd132d72qn7uc \
  --auth-parameters USERNAME=<email>,PASSWORD=<password> \
  --region us-west-2 \
  --query 'AuthenticationResult.IdToken' \
  --output text)

# Create instance
curl -X POST https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com/prod/provision \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json"
```

## Key Configuration Files

### Provisioning Service Config

**`eks-pod-service/app/config.py`** - OpenClaw instance defaults:

```python
OPENCLAW_DEFAULTS = {
    'runtime_class': 'kata-fc',                          # Use Kata runtime
    'node_selector': {'workload-type': 'kata'},          # Schedule on Kata nodes
    'tolerations': [...],                                # Tolerate kata-dedicated taint
    'resources': {
        'requests': {'cpu': '600m', 'memory': '1.2Gi'},  # +overhead for VM
        'limits': {'cpu': '2', 'memory': '4Gi'}
    },
    'storage_size': '10Gi',
    'storage_class': 'gp3',
    'model': 'bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0'
}

# Cognito JWT verification
COGNITO_REGION = 'us-west-2'
COGNITO_USER_POOL_ID = 'us-west-2_gvOCTiLQE'
COGNITO_CLIENT_ID = 'f5qd2udi8508dd132d72qn7uc'
```

**Environment variables** (set in `kubernetes/deployment.yaml`):

- `OPENCLAW_RUNTIME_CLASS` - Override runtime class
- `OPENCLAW_NODE_SELECTOR` - JSON string for node selector
- `OPENCLAW_CPU_REQUEST`, `OPENCLAW_MEMORY_REQUEST` - Resource requests
- `COGNITO_REGION`, `COGNITO_USER_POOL_ID`, `COGNITO_CLIENT_ID` - Cognito config

### OpenClaw Instance Template

**`openclaw-deployment/openclaw-kata-bedrock.yaml`** - Example instance with Kata:

```yaml
apiVersion: openclaw.rocks/v1alpha1
kind: OpenClawInstance
metadata:
  name: openclaw-kata-bedrock
  namespace: openclaw
spec:
  config:
    raw:
      agents:
        defaults:
          model:
            primary: "bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0"

  envFrom:
    - secretRef:
        name: aws-credentials  # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY

  availability:
    runtimeClassName: kata-fc      # KEY: Use Kata Firecracker
    nodeSelector:
      workload-type: kata
    tolerations:
      - key: kata-dedicated
        operator: Exists
        effect: NoSchedule

  resources:
    requests:
      cpu: "600m"
      memory: "1.2Gi"

  storage:
    persistence:
      enabled: true
      size: 10Gi
      storageClass: gp3
```

## Security Architecture

### JWT Authentication Flow (NEW - 2026-03-02)

**Before (INSECURE)**:
```
Frontend → Sends X-User-Email, X-Cognito-Sub headers (can be forged)
Backend → Trusts headers without verification ❌
```

**After (SECURE)**:
```
Frontend → Only sends Authorization: Bearer <token>
Backend → Verifies JWT signature with Cognito JWKS ✅
        → Extracts user info from verified claims ✅
        → Enforces authorization (users can only access their own resources) ✅
```

**Implementation**:

1. **Frontend** (`app/static/js/auth.js`):
   - Authenticates with Cognito via `InitiateAuth` API
   - Stores `idToken` in localStorage
   - Sends only `Authorization: Bearer <idToken>` header

2. **Backend** (`app/utils/jwt_auth.py`):
   - `CognitoJWTVerifier` class:
     - Fetches JWKS from Cognito
     - Verifies JWT signature (RS256)
     - Validates claims (exp, aud, iss)
   - `@require_auth` decorator:
     - Applied to all protected endpoints
     - Extracts user info from verified token
     - Returns 401 if token invalid

3. **Authorization** (status.py, delete.py):
   - Users can only access/delete their own instances
   - Compares `user_id` from path with authenticated user's email hash
   - Returns 403 Forbidden if mismatch

**Dependencies**:
- `python-jose[cryptography]` - JWT verification
- `requests` - JWKS fetching

### RBAC Permissions

**Provisioning Service** (`kubernetes/rbac.yaml`):
- Create: Namespace, ResourceQuota, NetworkPolicy, OpenClawInstance CRD
- Get/List: Pod (read-only for status checks)
- Cannot: Modify other namespaces, delete cluster-scoped resources

**OpenClaw Operator**:
- Full control within user namespaces
- Read-only cluster-scoped: RuntimeClass, StorageClass

## Troubleshooting

### JWT Authentication Failures

**Symptom**: 401 Unauthorized when calling /provision

**Checks**:

```bash
# 1. Verify Cognito config matches
kubectl get deployment openclaw-provisioning -n openclaw-provisioning \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq .

# 2. Test JWKS endpoint accessibility from pod
kubectl exec -n openclaw-provisioning deployment/openclaw-provisioning -- \
  curl -s https://cognito-idp.us-west-2.amazonaws.com/us-west-2_gvOCTiLQE/.well-known/jwks.json

# 3. Check logs for JWT verification errors
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning \
  | grep -E "(JWT|Token|verif)"
```

**Common causes**:
- Token expired (check `exp` claim)
- Wrong `audience` (client ID mismatch)
- Network issue fetching JWKS
- Cognito User Pool ID typo

### Kata Pod Stuck in ContainerCreating

**Checks**:

```bash
# 1. Pod events
kubectl describe pod openclaw-<user_id>-0 -n openclaw-<user_id>

# 2. Kata DaemonSet
kubectl get ds -n kata-system
kubectl logs -n kata-system -l app=kata-firecracker-deploy

# 3. containerd logs on node
NODE=$(kubectl get pod openclaw-<user_id>-0 -n openclaw-<user_id> -o jsonpath='{.spec.nodeName}')
kubectl debug node/$NODE -it --image=ubuntu -- \
  chroot /host journalctl -u containerd -n 50
```

**Common causes**:
- Kata binaries not installed on node
- Firecracker download failed
- Insufficient disk space for VM images

### Instance Creation Failed

**Checks**:

```bash
# 1. Provisioning service logs
kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning --tail=100

# 2. Operator logs
kubectl logs -n openclaw-operator-system deployment/openclaw-operator --tail=100

# 3. Check if CRD exists
kubectl get crd openclawinstances.openclaw.rocks

# 4. Check RBAC
kubectl auth can-i create openclawinstances.openclaw.rocks \
  --as=system:serviceaccount:openclaw-provisioning:openclaw-provisioner \
  --namespace=openclaw-<user_id>
```

### Bedrock API Connection Failed

**Checks**:

```bash
# 1. Verify secret exists
kubectl get secret aws-credentials -n openclaw-<user_id> -o yaml

# 2. Test Bedrock from pod
kubectl exec -n openclaw-<user_id> openclaw-<user_id>-0 -c openclaw -- \
  env | grep AWS_

# 3. Check NetworkPolicy
kubectl get networkpolicy -n openclaw-<user_id>
kubectl describe networkpolicy openclaw-<user_id> -n openclaw-<user_id>

# 4. Test network egress
kubectl run test --rm -it --image=curlimages/curl \
  -n openclaw-<user_id> -- \
  curl -I https://bedrock-runtime.us-west-2.amazonaws.com
```

## Development Guidelines

### Adding New API Endpoints

When adding endpoints to `eks-pod-service/app/api/`:

1. **Protected endpoints** - require user authentication:
   ```python
   from flask import current_app
   from app.utils.jwt_auth import require_auth

   @blueprint.route('/my-endpoint', methods=['POST'])
   @require_auth(lambda: current_app.jwt_verifier)
   def my_endpoint(user_info):
       user_email = user_info['user_email']
       cognito_sub = user_info['cognito_sub']
       # ... implementation
   ```

2. **Public endpoints** - no auth required:
   ```python
   @blueprint.route('/public', methods=['GET'])
   def public_endpoint():
       # No @require_auth decorator
   ```

3. **Authorization** - restrict access to user's own resources:
   ```python
   from app.utils.user_id import generate_user_id

   authenticated_user_id = generate_user_id(user_info['user_email'])
   if requested_user_id != authenticated_user_id:
       return jsonify({"error": "Forbidden"}), 403
   ```

### Modifying OpenClaw Defaults

To change instance defaults (e.g., different model, resources):

1. Edit `eks-pod-service/app/config.py` → `OPENCLAW_DEFAULTS`
2. Rebuild and push image
3. Restart deployment
4. New instances will use updated defaults (existing instances unaffected)

**Or** use environment variables for runtime overrides (no code change):

```yaml
# kubernetes/deployment.yaml
env:
- name: OPENCLAW_MODEL
  value: "bedrock/us.anthropic.claude-opus-4-6-20250929-v1:0"
- name: OPENCLAW_CPU_REQUEST
  value: "1000m"
```

### Adding Operator CRD Fields

See detailed instructions in `openclaw-operator/CLAUDE.md` - summary:

1. Edit `api/v1alpha1/openclawinstance_types.go`
2. `make generate` (regenerate deepcopy)
3. `make manifests` (regenerate CRD YAML)
4. `make install` (apply CRD)
5. Update `internal/resources/*.go` builders to use new fields
6. Update documentation (`README.md`, `docs/api-reference.md`)

## Production Considerations

### Resource Quotas

Each user namespace has a ResourceQuota limiting:
- CPU requests: 2 cores
- Memory requests: 4Gi
- CPU limits: 4 cores
- Memory limits: 8Gi
- PVCs: 2

Adjust in `eks-pod-service/app/config.py` → `RESOURCE_QUOTA`.

### Scaling

**Provisioning Service**:
- HPA configured (min: 2, max: 10)
- Scales on CPU utilization
- Stateless, safe to scale horizontally

**OpenClaw Instances**:
- StatefulSet (single replica by default)
- Scaling requires multi-replica support in OpenClaw (not currently configured)

**Kata Nodes**:
- Scale nodegroup: `eksctl scale nodegroup --cluster=test-s4 --name=kata-graviton-metal --nodes=3`
- Each c6g.metal can run 20-30 OpenClaw instances (depends on resources)

### Monitoring

**Provisioning Service**:
- Logs: `kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning -f`
- Metrics: `kubectl top pod -n openclaw-provisioning`

**OpenClaw Instances**:
- Logs: `kubectl logs -n openclaw-<user_id> openclaw-<user_id>-0 -c openclaw -f`
- Metrics exposed on port 9090: `kubectl port-forward -n openclaw-<user_id> openclaw-<user_id>-0 9090:9090`

### Backup and Disaster Recovery

**User data** (PVCs):
- Use EBS snapshots: `kubectl get pvc -A` → identify PVs → create EBS snapshot
- Or use Velero for automated backup

**Configuration**:
- All Kubernetes manifests in git
- Operator CRD in `config/crd/bases/` (committed)
- Recreate cluster: `eksctl create cluster -f eksctl/cluster-with-kata.yaml`

## Related Documentation

- `openclaw-operator/CLAUDE.md` - Operator-specific development guidelines
- `KATA-QUICK-REFERENCE.md` - Kata Containers quick reference
- `DEPLOYMENT-SUCCESS.md` - Full deployment walkthrough
- `README.md` - Project overview and quickstart

---

**Last updated**: 2026-03-02
**Status**: Production (JWT auth secured)
