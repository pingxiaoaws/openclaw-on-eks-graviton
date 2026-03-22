#!/bin/bash
# Build and push billing sidecar image to ECR
set -euo pipefail

REGION=${AWS_REGION:-us-east-1}
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REPO="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/billing-sidecar"

aws ecr create-repository --repository-name billing-sidecar --region "$REGION" 2>/dev/null || true
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
docker build -t "${REPO}:latest" "$SCRIPT_DIR"
docker push "${REPO}:latest"
echo "Pushed: ${REPO}:latest"
