#!/bin/bash
# Phase 4: Deploy OpenClaw Provisioning Service
# - Create Bedrock IAM Role and Pod Identity Association
# - Build and deploy Provisioning Service

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Phase 4: Provisioning Service Deployment ===${NC}"
echo ""

# Get cluster info
CLUSTER_NAME=$(kubectl config current-context | cut -d'@' -f2 | cut -d'.' -f1)
AWS_REGION=$(kubectl config current-context | grep -o 'us-[a-z]*-[0-9]' || echo "us-east-1")
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Account: $AWS_ACCOUNT"
echo ""

# ============================================================================
# Step 1: Create Bedrock IAM Policy and Role
# ============================================================================

echo -e "${BLUE}[1/3] Creating Bedrock IAM Role...${NC}"

# Create IAM policy for Bedrock
BEDROCK_POLICY_NAME="OpenClawBedrockAccess"
BEDROCK_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT}:policy/${BEDROCK_POLICY_NAME}"

# Check if policy exists
if aws iam get-policy --policy-arn "$BEDROCK_POLICY_ARN" &>/dev/null; then
  echo -e "${YELLOW}⚠️  Bedrock policy already exists${NC}"
else
  echo "Creating Bedrock IAM policy..."
  cat > /tmp/bedrock-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": "arn:aws:bedrock:*:*:model/*"
    }
  ]
}
EOF

  aws iam create-policy \
    --policy-name "$BEDROCK_POLICY_NAME" \
    --policy-document file:///tmp/bedrock-policy.json \
    --description "Allow OpenClaw instances to access AWS Bedrock"

  echo -e "${GREEN}✅ Bedrock IAM policy created${NC}"
fi

# Create IAM Role for Pod Identity
BEDROCK_ROLE_NAME="OpenClawBedrockRole"

# Check if role exists
if aws iam get-role --role-name "$BEDROCK_ROLE_NAME" &>/dev/null; then
  echo -e "${YELLOW}⚠️  Bedrock role already exists${NC}"
else
  echo "Creating Bedrock IAM role..."

  # Create trust policy for Pod Identity
  cat > /tmp/bedrock-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
EOF

  aws iam create-role \
    --role-name "$BEDROCK_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/bedrock-trust-policy.json \
    --description "IAM role for OpenClaw Bedrock access via Pod Identity"

  # Attach policy to role
  aws iam attach-role-policy \
    --role-name "$BEDROCK_ROLE_NAME" \
    --policy-arn "$BEDROCK_POLICY_ARN"

  echo -e "${GREEN}✅ Bedrock IAM role created${NC}"
fi

echo ""

# ============================================================================
# Step 2: Create Pod Identity Association
# ============================================================================

echo -e "${BLUE}[2/3] Creating Pod Identity Association...${NC}"

BEDROCK_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT}:role/${BEDROCK_ROLE_NAME}"

# Check if association exists
EXISTING_ASSOC=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace openclaw \
  --service-account openclaw-bedrock-access \
  --query 'associations[0].associationId' \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_ASSOC" ] && [ "$EXISTING_ASSOC" != "None" ]; then
  echo -e "${YELLOW}⚠️  Pod Identity association already exists: $EXISTING_ASSOC${NC}"
else
  # Create namespace if not exists
  kubectl create namespace openclaw --dry-run=client -o yaml | kubectl apply -f -

  # Create ServiceAccount
  kubectl create serviceaccount openclaw-bedrock-access -n openclaw --dry-run=client -o yaml | kubectl apply -f -

  # Create Pod Identity Association
  aws eks create-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" \
    --namespace openclaw \
    --service-account openclaw-bedrock-access \
    --role-arn "$BEDROCK_ROLE_ARN" \
    --region "$AWS_REGION"

  echo -e "${GREEN}✅ Pod Identity association created${NC}"
fi

echo ""

# ============================================================================
# Step 3: Build and Push Docker Image (Remote)
# ============================================================================

echo -e "${BLUE}[3/4] Building and pushing Docker image (remote)...${NC}"

# Remote build configuration
REMOTE_HOST="44.252.48.166"
REMOTE_USER="ec2-user"
SSH_KEY="/Users/pingxiao/.ssh/pingec2.key"
REMOTE_DIR="~/openclaw-on-eks-graviton"

# Check if SSH key exists
if [ ! -f "$SSH_KEY" ]; then
  echo -e "${RED}❌ SSH key not found: $SSH_KEY${NC}"
  exit 1
fi

# Push local changes to GitHub first (if in git repo)
PROVISIONING_DIR="$(dirname "$0")/../../open-claw-operator-on-EKS-kata/eks-pod-service"
cd "$PROVISIONING_DIR"

if [ -d ".git" ]; then
  echo "Pushing local changes to GitHub..."
  git add app/main.py app/templates/login-new.html app/templates/dashboard-new.html
  git commit -m "fix: inject Cognito config into frontend templates" || echo "No changes to commit"
  git push origin main || echo "Push failed or no changes"
fi

cd - > /dev/null

# Execute remote build
echo "Executing remote Docker build on $REMOTE_HOST..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" << EOF
set -e

echo "=== Remote Build Started ==="

# Pull latest code
cd ~/openclaw-on-eks-graviton
git pull origin main

# Navigate to eks-pod-service
cd eks-pod-service

# Login to ECR
echo "Logging in to ECR..."
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin ${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Build Docker image
echo "Building Docker image..."
docker build -t ${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/openclaw-provisioning:latest .

# Push to ECR
echo "Pushing image to ECR..."
docker push ${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/openclaw-provisioning:latest

echo "=== Remote Build Complete ==="
EOF

if [ $? -eq 0 ]; then
  echo -e "${GREEN}✅ Docker image built and pushed (remote)${NC}"
else
  echo -e "${RED}❌ Remote build failed${NC}"
  exit 1
fi

echo ""

# ============================================================================
# Step 4: Deploy Provisioning Service
# ============================================================================

echo -e "${BLUE}[4/4] Deploying Provisioning Service...${NC}"

# Create namespace
kubectl create namespace openclaw-provisioning --dry-run=client -o yaml | kubectl apply -f -

# Deploy RBAC
echo "Deploying RBAC..."
kubectl apply -f "$PROVISIONING_DIR/kubernetes/rbac.yaml"

# Create secret (if not exists)
echo "Creating secret..."
kubectl create secret generic openclaw-provisioning-secret \
  -n openclaw-provisioning \
  --from-literal=secret-key="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

# Create temporary deployment with correct image and settings
echo "Deploying provisioning service..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openclaw-provisioning
  namespace: openclaw-provisioning
  labels:
    app: openclaw-provisioning
spec:
  replicas: 2
  selector:
    matchLabels:
      app: openclaw-provisioning
  template:
    metadata:
      labels:
        app: openclaw-provisioning
    spec:
      serviceAccountName: openclaw-provisioner
      containers:
      - name: provisioning
        image: ${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/openclaw-provisioning:latest
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: LOG_LEVEL
          value: "INFO"
        - name: USE_POD_IDENTITY
          value: "true"
        - name: SHARED_BEDROCK_ROLE_ARN
          value: "arn:aws:iam::${AWS_ACCOUNT}:role/OpenClawBedrockRole"
        - name: EKS_CLUSTER_NAME
          value: "${CLUSTER_NAME}"
        - name: AWS_REGION
          value: "${AWS_REGION}"
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
          limits:
            cpu: 1000m
            memory: 1Gi
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
EOF

# Deploy Service
echo "Deploying service..."
kubectl apply -f "$PROVISIONING_DIR/kubernetes/service.yaml"

# Deploy Ingress (internal ALB)
echo "Deploying Ingress (internal ALB)..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: openclaw-provisioning-ingress
  namespace: openclaw-provisioning
  annotations:
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
    alb.ingress.kubernetes.io/success-codes: "200"
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
  labels:
    app: openclaw-provisioning
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      # Frontend pages
      - path: /login
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /dashboard
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      # Static resources
      - path: /static
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      # API endpoints
      - path: /provision
        pathType: Exact
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /status
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /delete
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      # Health check
      - path: /health
        pathType: Exact
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      # Root path
      - path: /
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
EOF

# Wait for ALB to be provisioned
echo "Waiting for ALB to be provisioned..."
sleep 30

# Deploy HPA
echo "Deploying HPA..."
kubectl apply -f "$PROVISIONING_DIR/kubernetes/hpa.yaml" 2>/dev/null || echo "HPA skipped (metrics-server may not be ready)"

# Wait for deployment
echo "Waiting for provisioning service to be ready..."
kubectl rollout status deployment/openclaw-provisioning -n openclaw-provisioning --timeout=300s

echo -e "${GREEN}✅ Provisioning service deployed${NC}"
echo ""

# ============================================================================
# Summary
# ============================================================================

# Get ALB DNS name
ALB_DNS=$(kubectl get ingress openclaw-provisioning-ingress -n openclaw-provisioning \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending...")

echo -e "${GREEN}=== Phase 4 Complete ===${NC}"
echo ""
echo "Installed Components:"
echo "  ✅ Bedrock IAM Policy: $BEDROCK_POLICY_ARN"
echo "  ✅ Bedrock IAM Role: $BEDROCK_ROLE_ARN"
echo "  ✅ Pod Identity Association: openclaw/openclaw-bedrock-access"
echo "  ✅ Provisioning Service: openclaw-provisioning (2 replicas)"
echo "  ✅ Internal ALB: $ALB_DNS"
echo ""
echo "Verification:"
echo "  kubectl get pods -n openclaw-provisioning"
echo "  kubectl get ingress -n openclaw-provisioning"
echo "  kubectl logs -n openclaw-provisioning deployment/openclaw-provisioning"
echo ""
echo "ALB Endpoints (internal only):"
echo "  Health: http://$ALB_DNS/health"
echo "  Login: http://$ALB_DNS/login"
echo "  Dashboard: http://$ALB_DNS/dashboard"
echo ""
echo "Next Steps:"
echo "  1. Run: ./06-deploy-cloudfront-cognito.sh (Deploy CloudFront + Cognito)"
echo "  2. Access public URL via CloudFront"
echo ""
